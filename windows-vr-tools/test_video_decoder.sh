#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUTPUT="${1:-$ROOT/.build-device/video-decoder-test}"
mkdir -p "$OUTPUT"
xcrun clang++ -std=c++20 -fobjc-arc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$ROOT/windows-vr-native/include" \
  "$ROOT/windows-vr-native/Sources/WindowsVRVideoDecoder.mm" \
  "$ROOT/windows-vr-native/Tests/VideoDecoderProbe.mm" \
  -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  -o "$OUTPUT/video-decoder-probe"
"$OUTPUT/video-decoder-probe" "$OUTPUT/red32.h264"
