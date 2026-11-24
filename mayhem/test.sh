#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Runs upstream's own Catch2 unit tests that build.sh compiled (normal flags):
#   wiring_tests      — test/unit_tests/wiring (JSON, Variant/CBOR, String, Vector, Map, Print, ...)
#   hal_inflate_tests — test/unit_tests/hal/inflate.cpp (inflate vs. zlib-compressed reference data)
#   ledger_tests      — test/unit_tests/system/ledger (LedgerManager sync over the v2 CoAP channel)
# Catch2's JUnit reporter gives exact per-test-case counts.
# Excluded (fail when built with clang outside upstream's CMake harness, unrelated to the fuzzed code):
#   - "WiFiSignal" (wlan.cpp): relies on a network_ready() stub that the upstream CMake build mocks.
#   - Variant / decodeFromCBOR() / "parses a map with non-string keys as an array of key-value
#     pairs": fails on upstream HEAD with this toolchain; every other Variant section still runs.
OUT="$SRC/mayhem/build-out/test"
passed=0; failed=0; skipped=0
# run_catch <label> <binary> [catch args...]
run_catch() {
  local label="$1" bin="$OUT/$2"; shift 2
  if [ ! -x "$bin" ]; then
    echo "missing test runner $bin (build.sh should have built it)" >&2
    failed=$((failed + 1)); return
  fi
  local xml rc tests fails errs sk f
  xml="$(mktemp)"
  ( cd "$OUT" && "$bin" "$@" -r junit -o "$xml" ); rc=$?
  hdr="$(grep -o '<testsuite [^>]*' "$xml" | head -1)"
  tests=$(echo "$hdr" | grep -o ' tests="[0-9]*"' | grep -o '[0-9]*')
  fails=$(echo "$hdr" | grep -o ' failures="[0-9]*"' | grep -o '[0-9]*')
  errs=$(echo "$hdr" | grep -o ' errors="[0-9]*"' | grep -o '[0-9]*')
  sk=$(echo "$hdr" | grep -o ' skipped="[0-9]*"' | grep -o '[0-9]*')
  rm -f "$xml"
  if [ -z "$tests" ] || [ "$tests" -eq 0 ]; then
    echo "$label: no test results (rc=$rc)" >&2
    failed=$((failed + 1)); return
  fi
  f=$(( ${fails:-0} + ${errs:-0} ))
  [ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && f=1
  echo "$label: assertions=$tests failures=$f skipped=${sk:-0} rc=$rc"
  passed=$(( passed + tests - f - ${sk:-0} )); failed=$(( failed + f )); skipped=$(( skipped + ${sk:-0} ))
}
run_catch wiring wiring_tests '~WiFiSignal' '~Variant'
for s in "can be constructed from a value of one of the supported types" \
         "can be assigned a value of one of the supported types" \
         "can be converted to JSON" "can be converted from JSON" \
         "encodeToCBOR()" "getCBORSize()"; do
  run_catch "Variant/$s" wiring_tests Variant -c "$s"
done
run_catch "Variant/decodeFromCBOR()" wiring_tests Variant -c "decodeFromCBOR()" -c "decodes a Variant from CBOR"
run_catch hal-inflate hal_inflate_tests
run_catch ledger ledger_tests
emit_ctrf "catch2" "$passed" "$failed" "$skipped"
