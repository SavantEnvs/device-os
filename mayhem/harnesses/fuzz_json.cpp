// Fuzz the cloud/event JSON parser: spark::JSONValue::parseCopy() (jsmn based) and
// the JSON -> Variant conversion (Variant::fromJSON), walking every value.
#include "spark_wiring_json.h"
#include "spark_wiring_variant.h"
#include <cstddef>
#include <cstdint>
#include <string>

using namespace spark;

namespace {
size_t walk(const JSONValue& v, int depth) {
    size_t n = 0;
    if (depth > 64) {
        return n;
    }
    switch (v.type()) {
    case JSON_TYPE_OBJECT: {
        JSONObjectIterator it(v);
        while (it.next()) {
            JSONString name = it.name();
            n += name.size();
            n += std::string(name.data(), name.size()).size();
            n += walk(it.value(), depth + 1);
        }
        break;
    }
    case JSON_TYPE_ARRAY: {
        JSONArrayIterator it(v);
        while (it.next()) {
            n += walk(it.value(), depth + 1);
        }
        break;
    }
    default: {
        JSONString s = v.toString();
        n += s.size();
        n += (unsigned)v.toInt();
        n += (v.toDouble() > 0.0) ? 1 : 0;
        n += v.toBool() ? 1 : 0;
        break;
    }
    }
    return n;
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    JSONValue v = JSONValue::parseCopy((const char*)data, size);
    if (v.isValid()) {
        walk(v, 0);
        particle::Variant var = particle::Variant::fromJSON(v);
        String out = var.toJSON();
        (void)out.length();
    }
    // Also through the NUL-terminated entry point.
    std::string s((const char*)data, size);
    particle::Variant var2 = particle::Variant::fromJSON(s.c_str());
    (void)var2.toJSON().length();
    return 0;
}
