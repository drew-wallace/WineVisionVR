#!/usr/bin/env python3
"""Check the actual presentation selector against SDR/HDR and disabled cases."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", type=Path, required=True)
    args = parser.parse_args()
    source = args.runtime_source.resolve() / "dxmt/src"
    fixture = r'''
#include "dxmt_present_format.hpp"
#include <cassert>
int main() {
  WMTPixelFormat formats[] = {WMTPixelFormatInvalid, WMTPixelFormatRGBA8Unorm,
    WMTPixelFormatBGRA8Unorm, WMTPixelFormatRGB10A2Unorm, WMTPixelFormatBGR10A2Unorm,
    WMTPixelFormatRGBA16Float, WMTPixelFormatRGBA8Unorm_sRGB};
  WMTColorSpace spaces[] = {WMTColorSpaceSRGB, WMTColorSpaceSRGBLinear,
    WMTColorSpaceBT2020, WMTColorSpaceHDR_PQ, WMTColorSpaceHDR_scRGB, WMTColorSpaceInvalid};
  for (auto format : formats) for (auto space : spaces) {
    assert(dxmt::SelectSDRPresentationFormat(format, space, false) == format);
    auto expected = format == WMTPixelFormatRGB10A2Unorm && space == WMTColorSpaceSRGB
      ? WMTPixelFormatBGRA8Unorm : format;
    assert(dxmt::SelectSDRPresentationFormat(format, space, true) == expected);
  }
  // A dynamic display override may select HDR and then return to SDR.
  assert(dxmt::SelectSDRPresentationFormat(WMTPixelFormatRGB10A2Unorm, WMTColorSpaceHDR_PQ, true)
    == WMTPixelFormatRGB10A2Unorm);
  assert(dxmt::SelectSDRPresentationFormat(WMTPixelFormatRGB10A2Unorm, WMTColorSpaceSRGB, true)
    == WMTPixelFormatBGRA8Unorm);
}
'''
    with tempfile.TemporaryDirectory(prefix="wvr-sdr-format-") as work:
        work = Path(work)
        (work / "probe.cpp").write_text(fixture)
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I", str(source / "dxmt"),
                        "-I", str(source / "winemetal"), str(work / "probe.cpp"),
                        "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=15)
    print("PASS: explicit packed-10-bit SDR conversion; disabled, HDR, linear/wide and other formats preserved; ASan/UBSan")


if __name__ == "__main__":
    main()
