#!/usr/bin/env python3
"""Run one already-built probe in the diagnostic app on a physical headset.

The app must include --compatibility-probe support. Each invocation writes a
fresh run receipt, requires a matching run token, and never accepts stale output
as a successful run. It does not modify installed game files or app defaults.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

BUNDLE = "org.avpplay.visionos-windows-vr"
RESULTS = {"mapping": "mapping-result.txt", "managed": "managed-result.txt", "angle": "angle-result.txt"}
EXECUTABLES = {"mapping": "mapping-probe.exe", "managed": "ManagedRuntimeProbe.exe", "angle": "angle-probe.exe"}


def file_sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def result_status(text, run):
    lines = text.replace("\r", "").splitlines()
    if not lines or not lines[0].startswith("START ") or f"run={run}" not in lines[0]:
        return "stale-or-not-started"
    return "pass" if lines[-1] == "RESULT PASS" else "fail" if any(line.startswith("RESULT FAIL") for line in lines) else "incomplete"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--probe", required=True, choices=RESULTS)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New receipt directory; must not exist")
    parser.add_argument("--gc-region-range", help="Optional process-only hexadecimal .NET diagnostic comparison")
    parser.add_argument("--angle-color-bits", type=int, choices=(8, 10), help="Explicit ANGLE window color-format comparison")
    parser.add_argument("--timeout", type=int, default=45, choices=range(5, 61), metavar="5..60")
    args = parser.parse_args()
    if args.gc_region_range and (args.probe != "managed" or not re.fullmatch(r"[0-9a-fA-F]{1,16}", args.gc_region_range)):
        parser.error("GC region range is an explicit hexadecimal managed-probe comparison only")
    if args.angle_color_bits and args.probe != "angle":
        parser.error("Window color-bit comparison applies only to the ANGLE probe")
    args.output.mkdir(parents=True, exist_ok=False)
    run = str(uuid.uuid4())
    environment = {"WVR_AUTOMATED_LAUNCH": "1", "WINEVISION_PROBE_RUN_ID": run}
    if args.gc_region_range:
        environment["DOTNET_GCRegionRange"] = args.gc_region_range
    if args.angle_color_bits:
        environment["ANGLE_PROBE_COLOR_BITS"] = str(args.angle_color_bits)
    receipt = {"schemaVersion": 1, "runID": run, "probe": args.probe,
               "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "environment": environment, "status": "not-started"}
    base = ["xcrun", "devicectl", "device"]
    domain = ["--device", args.device, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE]
    # A fresh path avoids incremental-copy reuse without deleting any remote
    # directory or relying on transfer flags that affect a parent container.
    remote = "Documents/WindowsVR/ProbeRuns/" + run + "/" + args.probe
    receipt["remoteRunDirectory"] = remote

    def command(name, arguments):
        with (args.output / (name + ".log")).open("w") as log:
            result = subprocess.run([*base, *arguments], stdout=log, stderr=subprocess.STDOUT, timeout=60)
        return result.returncode

    try:
        # Never request removal of remote content: this option may affect the
        # enclosing app-data domain. Verify bytes and fail closed on stale copy.
        if command("copy", ["copy", "to", *domain, "--source", str(args.build / args.probe), "--destination", remote]):
            receipt["status"] = "copy-failed"
        elif command("verify-executable-copy", ["copy", "from", *domain, "--source", remote + "/" + EXECUTABLES[args.probe],
                                                "--destination", str(args.output / "uploaded-executable.exe")]):
            receipt["status"] = "copy-verification-failed"
        elif file_sha256(args.output / "uploaded-executable.exe") != file_sha256(args.build / args.probe / EXECUTABLES[args.probe]):
            receipt["status"] = "executable-hash-mismatch"
        elif command("launch", ["process", "launch", "--device", args.device, "--timeout", "25", "--terminate-existing",
                                "--environment-variables", json.dumps(environment), BUNDLE, "--", "--compatibility-probe=" + args.probe]):
            receipt["status"] = "launch-failed"
        else:
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                local = args.output / RESULTS[args.probe]
                if command("result-copy", ["copy", "from", *domain, "--source", remote + "/" + RESULTS[args.probe], "--destination", str(local)]) == 0:
                    receipt["status"] = result_status(local.read_text(errors="replace"), run)
                    if receipt["status"] in {"pass", "fail"}: break
                else:
                    receipt["status"] = "no-result"
                time.sleep(2)
            for name in ["launcher-log.txt", "madeira-log.txt"]:
                command("copy-" + name, ["copy", "from", *domain, "--source", "Documents/" + name,
                                         "--destination", str(args.output / name)])
    except (OSError, subprocess.SubprocessError) as error:
        receipt["status"] = "tool-failed"
        receipt["error"] = str(error)
    finally:
        if (args.output / "uploaded-executable.exe").exists():
            receipt["uploadedExecutableSha256"] = file_sha256(args.output / "uploaded-executable.exe")
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{args.probe}: {receipt['status']} (run {run}); receipt {args.output / 'receipt.json'}")
    return 0 if receipt["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
