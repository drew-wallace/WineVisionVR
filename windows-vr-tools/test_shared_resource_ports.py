#!/usr/bin/env python3
"""Exercise app-local Winemetal sharing with real Mach rights and Metal textures."""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--winemetal-source",type=Path,help="Also verify the pinned native dispatch slots and guest record layout")
args=parser.parse_args()
if args.winemetal_source:
    text=(args.winemetal_source/"unix/winemetal_unix.c").read_text()
    start=text.index("dxmt_winemetal_unix_call_funcs")
    begin=text.index("{",start)
    slots=re.findall(r"&([A-Za-z_0-9]+)|\b(NULL)\b",text[begin:text.index("};",begin)])
    assert len(slots)==149 and slots[121][0]=="_WMTBootstrapRegister" and slots[122][0]=="_WMTBootstrapLookUp"
    header=(args.winemetal_source/"winemetal_thunks.h").read_text()
    record=re.search(r"struct unixcall_bootstrap\s*\{([^}]+)\}",header).group(1)
    assert " ".join(record.split())=="char name[128]; uint32_t mach_port; uint32_t reserved;"
    print("PASS: pinned Winemetal slots 121/122, dispatch count 149 and 136-byte guest record",flush=True)
with tempfile.TemporaryDirectory(prefix="winevision-shared-ports-") as temporary:
    executable=Path(temporary)/"test"
    subprocess.run(["xcrun","clang++","-std=c++20","-O1","-g","-fobjc-arc",
        "-fsanitize=address,undefined","-fno-omit-frame-pointer",
        "-I",str(root/"windows-vr-native/include"),
        str(root/"windows-vr-native/Tests/SharedResourcePortsTests.mm"),
        "-framework","Foundation","-framework","Metal","-o",str(executable)],check=True)
    subprocess.run([str(executable)],check=True,timeout=45)
