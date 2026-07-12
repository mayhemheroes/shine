#!/usr/bin/env bash
#
# mayhem/test.sh — AUTHORED behavioral known-answer oracle for libshine.
#
# Upstream ships NO C unit/functional suite (only a JS/emscripten node test for the wasm build, and a
# build-only CI job), so this is an authored oracle (tests_found=0). It RUNS the KAT binary built by
# build.sh (/mayhem/shine_kat) to encode a deterministic 440 Hz sine at a FIXED config, then parses
# the emitted MP3 bitstream and asserts real structural properties: frame sync, MPEG version/layer,
# the bitrate/samplerate/channel-mode header fields that must match the KAT config, frame count, and
# full-stream consumption. A no-op / exit(0) "fix" emits no (or malformed) bitstream and FAILS these
# assertions — so it is not reward-hackable.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

KAT=/mayhem/shine_kat
if [ ! -x "$KAT" ]; then
  echo "test.sh: $KAT missing — build.sh must build it" >&2
  emit_ctrf "shine-kat" 0 1
  exit 1
fi

OUT="$(mktemp /tmp/shine-kat.XXXXXX.mp3)"
trap 'rm -f "$OUT"' EXIT

# Run the KAT encoder. If neutered to exit(0), no bitstream is written and the parser below fails.
"$KAT" "$OUT" || true

# Verify the bitstream; the parser prints per-assertion PASS/FAIL to stderr and
# "<passed> <failed>" to stdout.
COUNTS="$(python3 - "$OUT" <<'PY'
import sys

# KAT config (mirrors mayhem/shine_kat.c) — the known answer the bitstream must encode.
KAT_PASSES = 64
EXPECT_VERSION = 3   # MPEG-1
EXPECT_LAYER = 1     # Layer III
EXPECT_MODE = 3      # mono
EXPECT_SR = 44100
EXPECT_BR = 128000

# MPEG audio header tables (only the MPEG-1 Layer III rows are exercised by the KAT config).
BITRATES_MPEG1_L3 = [None,32,40,48,56,64,80,96,112,128,160,192,224,256,320,None]  # kbps
SAMPLERATES_MPEG1 = [44100,48000,32000,None]

data = open(sys.argv[1], "rb").read()

results = {}
results["output_nonempty"] = len(data) > 0

frames = 0
off = 0
all_headers_ok = True
consumed_fully = True
n = len(data)
while off + 4 <= n:
    b0, b1, b2, b3 = data[off], data[off+1], data[off+2], data[off+3]
    if b0 != 0xFF or (b1 & 0xE0) != 0xE0:   # 11-bit frame sync
        consumed_fully = False
        all_headers_ok = False
        break
    version = (b1 >> 3) & 0x03
    layer = (b1 >> 1) & 0x03
    br_idx = (b2 >> 4) & 0x0F
    sr_idx = (b2 >> 2) & 0x03
    padding = (b2 >> 1) & 0x01
    mode = (b3 >> 6) & 0x03

    if version != EXPECT_VERSION or layer != EXPECT_LAYER or mode != EXPECT_MODE:
        all_headers_ok = False
    br = BITRATES_MPEG1_L3[br_idx]
    sr = SAMPLERATES_MPEG1[sr_idx]
    if br is None or sr is None:
        all_headers_ok = False
        consumed_fully = False
        break
    if br * 1000 != EXPECT_BR or sr != EXPECT_SR:
        all_headers_ok = False
    frame_len = (144 * (br * 1000)) // sr + padding
    if frame_len <= 4:
        all_headers_ok = False
        consumed_fully = False
        break
    off += frame_len
    frames += 1

# shine_flush() emits only the buffered reservoir bits, so the LAST frame may be truncated
# (off > n) or leave < 4 trailing bytes (no room for another header). Both are normal EOS shapes;
# anything else (mid-stream desync, >=4 unparseable trailing bytes) fails.
if off < n and (n - off) >= 4:
    consumed_fully = False

results["all_frames_valid_headers"] = all_headers_ok and frames > 0
results["full_stream_consumed"] = consumed_fully and frames > 0
# One MP3 frame per encoder pass; the bit reservoir can shift a frame across the flush boundary,
# so allow a small tolerance around KAT_PASSES.
results["frame_count_in_range"] = (KAT_PASSES - 3) <= frames <= (KAT_PASSES + 1)

for k, v in results.items():
    print(f"  [{'PASS' if v else 'FAIL'}] {k}", file=sys.stderr)
print(f"  frames={frames} bytes={n}", file=sys.stderr)

passed = sum(1 for v in results.values() if v)
failed = sum(1 for v in results.values() if not v)
print(f"{passed} {failed}")
PY
)" || COUNTS=""

read -r PASSED FAILED <<< "${COUNTS:-0 4}"
emit_ctrf "shine-kat" "$PASSED" "$FAILED"
