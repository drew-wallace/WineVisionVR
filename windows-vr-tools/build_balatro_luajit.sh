#!/usr/bin/env bash
# Build a Windows x64 Lua 5.1 ABI replacement with GC64 for Balatro.
# The stock LuaJIT 2.0 allocator requires addresses below visionOS's page zero.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD="${AVPPLAY_BALATRO_BUILD_ROOT:-$ROOT/.build-device/balatro-luajit}"
TOOLCHAIN="${AVPPLAY_LLVM_MINGW_ROOT:?Set AVPPLAY_LLVM_MINGW_ROOT to llvm-mingw}"
REVISION=ea9eb7edb5eac4a9d175d74523db34fac0fa5180
mkdir -p "$BUILD"
if [[ ! -d "$BUILD/source/.git" ]]; then
    git clone https://github.com/LuaJIT/LuaJIT.git "$BUILD/source"
fi
git -C "$BUILD/source" checkout --detach "$REVISION"
[[ -z "$(git -C "$BUILD/source" status --porcelain --untracked-files=no)" ]] || {
    echo "LuaJIT source has local changes; use a clean build directory." >&2
    exit 1
}
make -C "$BUILD/source" TARGET_SYS=Windows CROSS="$TOOLCHAIN/bin/x86_64-w64-mingw32-" clean
# GC64 is the default on x64. Interpret Lua to avoid nested guest JIT mappings.
make -C "$BUILD/source" -j8 HOST_CC=clang \
    CROSS="$TOOLCHAIN/bin/x86_64-w64-mingw32-" TARGET_SYS=Windows \
    BUILDMODE=dynamic XCFLAGS=-DLUAJIT_DISABLE_JIT
mkdir -p "$BUILD/output"
cp "$BUILD/source/src/lua51.dll" "$BUILD/output/"
cp "$BUILD/source/COPYRIGHT" "$BUILD/output/LuaJIT-COPYRIGHT.txt"
python3 - "$BUILD/output" "$REVISION" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
receipt = dict(source="https://github.com/LuaJIT/LuaJIT", revision=sys.argv[2],
               target="x86_64-w64-mingw32", gc64=True, jit=False,
               sha256=hashlib.sha256((out / "lua51.dll").read_bytes()).hexdigest())
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
PY
echo "Built compatibility DLL: $BUILD/output/lua51.dll"
RESOURCE_DIR="${AVPPLAY_BALATRO_RESOURCE_DIR:-$ROOT/visionos-windows-vr/Resources/GameCompatibility/Balatro}"
mkdir -p "$RESOURCE_DIR"
cp "$BUILD/output/lua51.dll" "$BUILD/output/LuaJIT-COPYRIGHT.txt" "$BUILD/output/receipt.json" "$RESOURCE_DIR/"
