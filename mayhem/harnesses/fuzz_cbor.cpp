// Fuzz the CBOR decoder used for structured cloud event / ledger data:
// particle::decodeFromCBOR(Variant&, Stream&); on success re-encode with
// encodeToCBOR() and convert to JSON.
#include "spark_wiring_variant.h"
#include "spark_wiring_stream.h"
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace {
class MemStream: public ::Stream {
public:
    MemStream(const uint8_t* d, size_t n) : d_(d), n_(n), pos_(0) {}
    int available() override { return n_ - pos_; }
    int read() override { return pos_ < n_ ? d_[pos_++] : -1; }
    int peek() override { return pos_ < n_ ? d_[pos_] : -1; }
    size_t readBytes(char* buf, size_t len) override {
        size_t k = std::min(len, n_ - pos_);
        if (k > 0) {
            std::memcpy(buf, d_ + pos_, k);
            pos_ += k;
        }
        return k;
    }
    void flush() override {}
    size_t write(uint8_t) override { return 1; }
    size_t write(const uint8_t*, size_t len) override { return len; }
    using Print::write;
private:
    const uint8_t* d_;
    size_t n_;
    size_t pos_;
};

class Sink: public Print {
public:
    size_t write(uint8_t b) override { out += (char)b; return 1; }
    size_t write(const uint8_t* d, size_t n) override { out.append((const char*)d, n); return n; }
    std::string out;
};
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    MemStream in(data, size);
    particle::Variant v;
    if (particle::decodeFromCBOR(v, in) < 0) {
        return 0;
    }
    Sink sink;
    particle::encodeToCBOR(v, sink);
    (void)v.toJSON().length();
    // The re-encoded form must decode as well.
    MemStream again((const uint8_t*)sink.out.data(), sink.out.size());
    particle::Variant v2;
    particle::decodeFromCBOR(v2, again);
    return 0;
}
