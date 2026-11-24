// Fuzz the streaming raw-deflate decoder used for compressed OTA updates
// (hal/shared/inflate.h: inflate_create/inflate_input/inflate_reset).
// Byte 0 picks the window size, byte 1 the input chunk size; the rest is the
// compressed stream, fed in chunks with INFLATE_HAS_MORE_INPUT until the last one.
#include "inflate.h"
#include <cstddef>
#include <cstdint>

namespace {
int onOutput(const char* data, size_t size, void* user) {
    // Touch every output byte so ASan sees reads of the produced data.
    unsigned* sum = static_cast<unsigned*>(user);
    for (size_t i = 0; i < size; ++i) {
        *sum += (unsigned char)data[i];
    }
    return size;
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 2) {
        return -1;
    }
    inflate_opts opts = {};
    opts.window_bits = INFLATE_MIN_WINDOW_BITS + (data[0] % (INFLATE_MAX_WINDOW_BITS - INFLATE_MIN_WINDOW_BITS + 1));
    size_t chunk = (data[1] % 64) + 1;
    data += 2;
    size -= 2;
    unsigned sum = 0;
    inflate_ctx* ctx = nullptr;
    if (inflate_create(&ctx, &opts, onOutput, &sum) != 0 || !ctx) {
        return 0;
    }
    size_t pos = 0;
    for (int pass = 0; pass < 2; ++pass) {
        pos = 0;
        for (;;) {
            size_t n = size - pos;
            if (n > chunk) {
                n = chunk;
            }
            const bool last = (pos + n >= size);
            size_t consumed = n;
            int r = inflate_input(ctx, (const char*)data + pos, &consumed, last ? 0 : INFLATE_HAS_MORE_INPUT);
            if (r < 0 || r == INFLATE_DONE) {
                break;
            }
            pos += consumed;
            if (r == INFLATE_NEEDS_MORE_INPUT && pos >= size) {
                break;
            }
            if (consumed == 0 && r != INFLATE_HAS_MORE_OUTPUT) {
                break;
            }
        }
        // Exercise inflate_reset() and decode the same stream again from scratch.
        inflate_reset(ctx);
    }
    inflate_destroy(ctx);
    return 0;
}
