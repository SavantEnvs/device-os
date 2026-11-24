#!/usr/bin/env bash
#
# mayhem/build.sh — device-os host-side fuzz harnesses + unit-test oracle.
#
# The firmware itself targets ARM; upstream's host build is test/unit_tests (CMake + Catch2 + Boost),
# which compiles per-module source subsets for PLATFORM_ID=3 (gcc). We reuse those source lists,
# include paths and defines directly with clang (no Catch/Boost in the fuzz build):
#   fuzz_inflate : hal/shared/inflate*.cpp + miniz tinfl  (test/unit_tests/hal)
#   fuzz_json    : wiring JSON (jsmn) + Variant::fromJSON (test/unit_tests/wiring)
#   fuzz_cbor    : wiring Variant CBOR decode/encode      (test/unit_tests/wiring)
#   fuzz_ledger  : LedgerManager over the v2 CoAP channel  (test/unit_tests/system/ledger)
# Submodules are not part of the checkout; miniz and Catch2 are pinned in the image under
# /opt/toolchains/deps (see mayhem/Dockerfile).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MINIZ_DIR:=/opt/toolchains/deps/miniz-edb0b3d/src}"
: "${CATCH2_DIR:=/opt/toolchains/deps/catch2-c4e3767/src}"
: "${NANOPB_DIR:=/opt/toolchains/deps/nanopb-1b205c8/src}"
: "${LITTLEFS_DIR:=/opt/toolchains/deps/littlefs-6095f54/src}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"
D="$SRC"
T="$D/test/unit_tests"
OUT="$D/mayhem/build-out"     # gitignored (mayhem/.gitignore)
mkdir -p "$OUT/fuzz" "$OUT/test"

COMMON_DEFS="-DLOG_DISABLE -DRELEASE_BUILD -DUNIT_TEST -DPLATFORM_ID=3"
WIRING_DEFS="$COMMON_DEFS -DHAL_PLATFORM_ERROR_MESSAGES=1"
WIRING_INC="-I$T -I$T/stub -I$D/communication/inc -I$D/hal/inc -I$D/hal/src/gcc -I$D/hal/shared \
 -I$D/platform/MCU/gcc/inc -I$D/dynalib/inc -I$D/services/inc -I$D/system/inc -I$D/wiring/inc \
 -I$D/third_party/hippomocks"
HAL_DEFS="$COMMON_DEFS -DHAL_PLATFORM_COMPRESSED_OTA=1"
HAL_INC="-I$T -I$D/hal/inc -I$D/hal/shared -I$D/hal -I$D/hal/src/nRF52840 -I$D/hal/src/gcc \
 -I$D/services/inc -I$MINIZ_DIR"

# Product sources (from test/unit_tests/wiring/CMakeLists.txt, minus the test files/utilities).
WIRING_SRCS=(
  hal/src/gcc/timer_hal.cpp hal/src/template/wlan_hal.cpp
  services/src/completion_handler.cpp services/src/system_error.cpp services/src/jsmn.c
  wiring/src/spark_wiring_async.cpp wiring/src/spark_wiring_print.cpp wiring/src/spark_wiring_stream.cpp
  wiring/src/spark_wiring_random.cpp wiring/src/spark_wiring_string.cpp wiring/src/spark_wiring_wifi.cpp
  wiring/src/spark_wiring_network.cpp wiring/src/spark_wiring_json.cpp wiring/src/spark_wiring_fuel.cpp
  wiring/src/spark_wiring_i2c.cpp wiring/src/spark_wiring_ipaddress.cpp wiring/src/spark_wiring_variant.cpp
  wiring/src/spark_wiring_buffer.cpp wiring_globals/src/wiring_globals_i2c.cpp hal/src/template/i2c_hal.cpp
  wiring/src/string_convert.cpp
  test/unit_tests/stub/system_network.cpp test/unit_tests/stub/inet_hal_compat.cpp
)
WIRING_TESTS=(
  test/unit_tests/util/alloc.cpp test/unit_tests/util/buffer.cpp test/unit_tests/util/string.cpp
  test/unit_tests/util/random_old.cpp
  async print vector print2 random string character error flags fuel_gauge ipaddress json
  std_functions wlan map variant buffer sleep_configuration
)
# From test/unit_tests/system/ledger/CMakeLists.txt (minus the Catch2 test files).
LEDGER_DEFS="$COMMON_DEFS -DHAL_PLATFORM_ERROR_MESSAGES=1 -DHAL_PLATFORM_OTA_PROTOCOL_V3=1 \
 -DMBEDTLS_SSL_MAX_CONTENT_LEN=1500 -DLFS_CONFIG=lfs_config.h -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR -DLFS_NO_ASSERT"
LEDGER_INC="-I$T/system/ledger -I$LITTLEFS_DIR -I$T/stub -I$D/hal/src/gcc/littlefs -I$T -I$T/communication/util \
 -I$D/communication/inc -I$D/communication/src -I$D/crypto/inc -I$D/system/inc -I$D/system/src -I$D/services/inc \
 -I$D/hal/inc -I$D/hal/shared -I$D/hal/src/gcc -I$D/wiring/inc -I$D/dynalib/inc -I$D/proto_defs/src -I$NANOPB_DIR"
LEDGER_SRCS=(
  system/src/ledger/ledger_manager.cpp system/src/ledger/ledger.cpp system/src/ledger/ledger_util.cpp
  services/src/file_util.cpp services/src/nanopb_misc.c services/src/system_error.cpp services/src/call_once.cpp
  services/src/jsmn.c services/src/stream.cpp proto_defs/src/cloud/cloud.pb.c proto_defs/src/cloud/ledger.pb.c proto_defs/src/ledger.pb.c
  "$NANOPB_DIR/pb_common.c" "$NANOPB_DIR/pb_encode.c" "$NANOPB_DIR/pb_decode.c" "$LITTLEFS_DIR/lfs.c"
  communication/src/v2/coap_channel.cpp communication/src/v2/coap_payload.cpp communication/src/v2/coap_options.cpp
  communication/src/v2/coap_tag.cpp communication/src/v2/coap_api.cpp communication/src/coap_message_encoder.cpp
  communication/src/coap_message_decoder.cpp communication/src/coap_util.cpp communication/src/coap_defs.cpp
  communication/src/protocol_util.cpp communication/src/protocol_defs.cpp communication/src/coap.cpp
  communication/src/coap_channel.cpp communication/src/protocol.cpp communication/src/messages.cpp
  communication/src/subscriptions.cpp communication/src/description.cpp communication/src/publisher.cpp
  communication/src/variables.cpp communication/src/chunked_transfer.cpp communication/src/firmware_update.cpp
  communication/src/communication_diagnostic.cpp wiring/src/spark_wiring_json.cpp
  test/unit_tests/communication/util/coap_message.cpp test/unit_tests/communication/util/coap_message_channel.cpp
  test/unit_tests/system/ledger/util/coap_api_fake.cpp test/unit_tests/system/ledger/util/filesystem_ram.cpp
  test/unit_tests/system/ledger/util/system_fakes.cpp test/unit_tests/system/ledger/util/ledger_pb.cpp
)
HAL_SRCS=( hal/shared/inflate.cpp hal/shared/inflate_impl.cpp "$MINIZ_DIR/miniz_tinfl.c" )

# compile <outdir> <flags> <src> — C or C++ by extension
compile() {
  local outdir="$1" flags="$2" src="$3" obj
  obj="$outdir/$(echo "$src" | sed 's#^/##; s#/#_#g').o"
  # miniz deliberately does unaligned 16/32-bit loads on x86 (MINIZ_USE_UNALIGNED_LOADS_AND_STORES);
  # relax only UBSan's alignment check, only on the vendored miniz file (ASan + all other UBSan stay on).
  case "$src" in */miniz_tinfl.c) flags="$flags -fno-sanitize=alignment" ;; esac
  # CoapTag(data, 0) does memcpy(dst, nullptr, 0) for every token-less message (e.g. an empty ACK):
  # benign, but it would stop every input that acks a request. Relax only nonnull-attribute, only here.
  case "$src" in */v2/coap_tag.cpp) flags="$flags -fno-sanitize=nonnull-attribute" ;; esac
  case "$src" in
    *.c) $CC -std=gnu11 $flags -c "$src" -o "$obj" ;;
    *)   $CXX -std=gnu++17 -Wno-deprecated-declarations $flags -c "$src" -o "$obj" ;;
  esac
  echo "$obj"
}

# SanCov on the product objects too (not only the harness TU), unconditionally.
FZ="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"

# 1) Sanitized product objects
WIRING_OBJS=() ; for s in "${WIRING_SRCS[@]}"; do WIRING_OBJS+=("$(compile "$OUT/fuzz" "$FZ $WIRING_DEFS $WIRING_INC" "$s")"); done
HAL_OBJS=()    ; for s in "${HAL_SRCS[@]}";    do HAL_OBJS+=("$(compile "$OUT/fuzz" "$FZ $HAL_DEFS $HAL_INC" "$s")"); done
LEDGER_OBJS=() ; for s in "${LEDGER_SRCS[@]}"; do LEDGER_OBJS+=("$(compile "$OUT/fuzz" "$FZ $LEDGER_DEFS $LEDGER_INC" "$s")"); done
rm -f "$OUT/fuzz/libwiring.a" "$OUT/fuzz/libhal.a" "$OUT/fuzz/libledger.a"
ar rcs "$OUT/fuzz/libledger.a" "${LEDGER_OBJS[@]}"
ar rcs "$OUT/fuzz/libwiring.a" "${WIRING_OBJS[@]}"
ar rcs "$OUT/fuzz/libhal.a" "${HAL_OBJS[@]}"
LSAN_OFF="$(compile "$OUT/fuzz" "$FZ" mayhem/lsan_off.cc)"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/fuzz/standalone_main.o"

# 2) Harnesses: libFuzzer binary + standalone reproducer each
link_harness() {
  local name="$1" flags="$2" lib="$3" hobj
  hobj="$(compile "$OUT/fuzz" "$FZ $flags" "mayhem/harnesses/$name.cpp")"
  $CXX $FZ $LIB_FUZZING_ENGINE "$hobj" "$LSAN_OFF" "$lib" -o "$D/$name"
  $CXX $FZ "$OUT/fuzz/standalone_main.o" "$hobj" "$LSAN_OFF" "$lib" -o "$D/$name-standalone"
}
link_harness fuzz_inflate "$HAL_DEFS $HAL_INC" "$OUT/fuzz/libhal.a"
link_harness fuzz_json    "$WIRING_DEFS $WIRING_INC" "$OUT/fuzz/libwiring.a"
link_harness fuzz_cbor    "$WIRING_DEFS $WIRING_INC" "$OUT/fuzz/libwiring.a"
link_harness fuzz_ledger  "$LEDGER_DEFS $LEDGER_INC" "$OUT/fuzz/libledger.a"

# 3) Upstream unit tests (Catch2), NORMAL flags: wiring suite + hal inflate suite.
TF="-O1 $COVERAGE_FLAGS -I$CATCH2_DIR/single_include"
OBJS=()
for s in "${WIRING_SRCS[@]}"; do OBJS+=("$(compile "$OUT/test" "$TF $WIRING_DEFS $WIRING_INC" "$s")"); done
for s in "${WIRING_TESTS[@]}"; do
  case "$s" in */*) f="$s" ;; *) f="test/unit_tests/wiring/$s.cpp" ;; esac
  OBJS+=("$(compile "$OUT/test" "$TF $WIRING_DEFS $WIRING_INC" "$f")")
done
$CXX $COVERAGE_FLAGS "${OBJS[@]}" -o "$OUT/test/wiring_tests"
OBJS=()
for s in "${HAL_SRCS[@]}" test/unit_tests/hal/inflate.cpp; do OBJS+=("$(compile "$OUT/test" "$TF $HAL_DEFS $HAL_INC" "$s")"); done
$CXX $COVERAGE_FLAGS "${OBJS[@]}" -lboost_iostreams -lz -o "$OUT/test/hal_inflate_tests"
OBJS=()
for s in "${LEDGER_SRCS[@]}" test/unit_tests/system/ledger/ledger_manager.cpp test/unit_tests/system/ledger/main.cpp; do
  OBJS+=("$(compile "$OUT/test" "$TF $LEDGER_DEFS $LEDGER_INC" "$s")")
done
$CXX $COVERAGE_FLAGS "${OBJS[@]}" -o "$OUT/test/ledger_tests"
echo "build.sh: done"
