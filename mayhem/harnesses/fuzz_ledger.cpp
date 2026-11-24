// Fuzz Ledger cloud synchronization: system/src/ledger/ledger_manager.cpp driven through the real
// v2 CoAP channel (communication/src/v2), with the cloud side played by upstream's CoapFake
// (test/unit_tests/system/ledger/util). The input is a sequence of operations: the "cloud" responds
// to / fails / acks the device's pending requests with fuzzed protobuf payloads, sends its own
// ledger requests (e.g. NOTIFY_UPDATE), connects/disconnects, and the app writes/reads ledgers.
//
// State kept across inputs: LedgerManager and CoapFake are process singletons (as in upstream's
// tests). Each input ends like upstream's LedgerFixture destructor: drop ledgers, disconnect, run
// timers, removeAllData(), clearLog() — so every input starts disconnected with no ledger data.
// Exceptions caught below are thrown only by the test fakes (unknown request ID, a malformed CoAP
// message sent by the device, timers that never settle) — never by product code.
#include "ledger/ledger.h"
#include "ledger/ledger_manager.h"
#include "util/coap_api_fake.h"
#include "util/system_fakes.h"
#include "coap_api.h"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

using namespace particle;
using namespace particle::system;
using namespace particle::test;

namespace {

struct Input {
    const uint8_t* d;
    size_t n;
    size_t pos = 0;
    bool empty() const { return pos >= n; }
    uint8_t byte() { return pos < n ? d[pos++] : 0; }
    std::string bytes() {
        size_t len = byte();
        if (len > n - pos) {
            len = n - pos;
        }
        std::string s((const char*)d + pos, len);
        pos += len;
        return s;
    }
};

const char* const NAMES[] = { "a", "test", "ledger-1", "x" };
const int STATUSES[] = { COAP_STATUS_CONTENT, COAP_STATUS_CHANGED, COAP_STATUS_BAD_REQUEST,
        COAP_STATUS_NOT_FOUND, COAP_STATUS_INTERNAL_SERVER_ERROR, COAP_STATUS_SERVICE_UNAVAILABLE };

int pendingRequest(CoapFake& coap) {
    const auto& reqs = coap.requests();
    for (auto it = reqs.rbegin(); it != reqs.rend(); ++it) {
        if (!it->isResponse && !it->completed) {
            return it->reqId;
        }
    }
    return -1;
}

void syncCallback(ledger_instance*, void*) {
}

} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    CoapFake& coap = CoapFake::instance();
    LedgerManager* mgr = LedgerManager::instance();
    std::vector<RefCountPtr<Ledger>> ledgers;
    Input in{data, size};
    int ops = 0;
    while (!in.empty() && ops++ < 64) {
        uint8_t op = in.byte();
        try {
            switch (op % 10) {
            case 0: { // Application gets/creates a ledger
                RefCountPtr<Ledger> l;
                if (mgr->getLedger(l, NAMES[in.byte() % 4], true) == 0) {
                    l->setSyncCallback(syncCallback);
                    ledgers.push_back(l);
                }
                break;
            }
            case 1:
                if (!coap.isConnected()) {
                    coap.connect();
                }
                break;
            case 2:
                if (coap.isConnected()) {
                    coap.disconnect();
                }
                break;
            case 3: { // Cloud responds to the device's latest pending request
                int id = pendingRequest(coap);
                int status = STATUSES[in.byte() % 6];
                std::string payload = in.bytes();
                if (id >= 0 && coap.isConnected()) {
                    coap.respond(id, status, payload);
                }
                break;
            }
            case 4: { // Cloud sends a ledger request to the device
                std::string payload = in.bytes();
                if (coap.isConnected()) {
                    coap.sendRequest("L", COAP_METHOD_POST, payload);
                }
                break;
            }
            case 5: { // Application writes a ledger
                std::string payload = in.bytes();
                if (!ledgers.empty()) {
                    auto& l = ledgers[in.byte() % ledgers.size()];
                    LedgerWriter w;
                    if (l->initWriter(w, LedgerWriteSource::USER) == 0) {
                        w.write(payload.data(), payload.size());
                        w.close();
                    }
                }
                break;
            }
            case 6: { // Application reads a ledger
                if (!ledgers.empty()) {
                    auto& l = ledgers[in.byte() % ledgers.size()];
                    LedgerReader r;
                    if (l->initReader(r) == 0) {
                        char buf[64];
                        while (r.read(buf, sizeof(buf)) > 0) {
                        }
                        r.close();
                    }
                }
                break;
            }
            case 7:
                advanceTime((uint64_t)in.byte() * 1000);
                break;
            case 8: {
                int id = pendingRequest(coap);
                if (id >= 0 && coap.isConnected()) {
                    coap.failRequest(id, SYSTEM_ERROR_TIMEOUT);
                }
                break;
            }
            case 9: {
                int id = pendingRequest(coap);
                if (id >= 0 && coap.isConnected()) {
                    coap.acknowledge(id);
                }
                break;
            }
            }
            runTimers();
        } catch (const std::exception&) {
            // Thrown by the test fakes only; see the header comment.
        }
    }
    // Reset like upstream's LedgerFixture destructor.
    ledgers.clear();
    try {
        if (coap.isConnected()) {
            coap.disconnect();
        }
        runTimers();
    } catch (const std::exception&) {
    }
    mgr->removeAllData();
    coap.clearLog();
    return 0;
}
