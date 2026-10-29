#!/usr/bin/env python3
"""Compile the prepared pool policy and verify bounded allocation sizes."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", type=Path, required=True)
    args = parser.parse_args()
    text = (args.runtime_source / "app/Madeira/FEXBridge.mm").read_text()
    start = text.index("static constexpr size_t JIT_POOL_SIZE")
    end = text.index("static constexpr size_t JIT_PAGE_SIZE", start)
    policy = text[start:end]
    fixture = r'''
#include <cstddef>
#include <cassert>
#include <string>
''' + policy + r'''
int main() {
    constexpr size_t mib = 1024 * 1024;
    assert(jit_pool_size_for_override(nullptr) == 640 * mib);
    for (unsigned value = 0; value <= 2048; ++value) {
        const size_t expected = value >= 640 && value <= 1024 && value % 64 == 0 ? value : 640;
        assert(jit_pool_size_for_override(std::to_string(value).c_str()) == expected * mib);
    }
    const char *invalid[] = {"", "-896", "+896", " 896", "896 ", "896MiB", "0x380",
        "9999999999999999999999999999999999999999999", "896\n"};
    for (const char *value : invalid) assert(jit_pool_size_for_override(value) == 640 * mib);
    assert(jit_pool_size_for_override("000896") == 896 * mib);
    // No arithmetic overflow even with a much longer-than-normal environment value.
    assert(jit_pool_size_for_override(std::string(10000, '9').c_str()) == 640 * mib);
}
'''
    with tempfile.TemporaryDirectory(prefix="wvr-jit-policy-") as work:
        work = Path(work)
        (work / "probe.cpp").write_text(fixture)
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", str(work / "probe.cpp"), "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=15)
    print("PASS: actual JIT pool policy, 640–1024 MiB aligned bounds, invalid/overflow fallback; ASan/UBSan")


if __name__ == "__main__":
    main()
