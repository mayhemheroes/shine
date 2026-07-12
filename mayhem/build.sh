#!/usr/bin/env bash
#
# mayhem/build.sh — build the libshine fuzz harness + standalone reproducer + KAT oracle.
#
# libshine is a small, self-contained fixed-point MP3 encoder (src/lib/*.c). We compile the library
# straight from its sources (no autotools needed) so the build is trivially idempotent + air-gapped.
# The library sources are recompiled per artifact (they are tiny) so each links the right runtime:
#   /mayhem/shine            libFuzzer harness — library+harness compiled WITH $LIB_FUZZING_ENGINE so
#                            the FUZZED code carries SanitizerCoverage (edges) + ASan/UBSan + DWARF<4.
#   /mayhem/shine-standalone run-once reproducer — same sources, LLVM standalone driver, NO libFuzzer.
#   /mayhem/shine_kat        KAT oracle — project NORMAL flags (no sanitizers), for test.sh.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

LIB_SRCS=(src/lib/bitstream.c src/lib/huffman.c src/lib/l3bitstream.c \
          src/lib/l3loop.c src/lib/l3mdct.c src/lib/l3subband.c \
          src/lib/layer3.c src/lib/reservoir.c src/lib/tables.c)
INCLUDE=-Isrc/lib

# 1) libFuzzer harness — the Mayhem target. Compiling the library sources together with
#    $LIB_FUZZING_ENGINE instruments the fuzzed code with SanitizerCoverage (so Mayhem records edges).
#    Keep the target name `shine` (matches the original CLI target) so run history isn't orphaned.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCLUDE $LIB_FUZZING_ENGINE \
    mayhem/fuzz_shine.c "${LIB_SRCS[@]}" -lm -o /mayhem/shine

# 2) Standalone (non-fuzzer) run-once reproducer for the same harness — no libFuzzer runtime, so it
#    is recompiled WITHOUT $LIB_FUZZING_ENGINE (its SanCov callbacks would otherwise be undefined).
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCLUDE "$STANDALONE_FUZZ_MAIN" \
    mayhem/fuzz_shine.c "${LIB_SRCS[@]}" -lm -o /mayhem/shine-standalone

# 3) KAT oracle — project's NORMAL flags (no sanitizers) so test.sh stays an honest functional oracle.
#    $COVERAGE_FLAGS (empty by default) optionally instruments the oracle build for coverage measurement.
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS $INCLUDE mayhem/shine_kat.c "${LIB_SRCS[@]}" -lm -o /mayhem/shine_kat

echo "build.sh: built /mayhem/shine, /mayhem/shine-standalone, /mayhem/shine_kat"
