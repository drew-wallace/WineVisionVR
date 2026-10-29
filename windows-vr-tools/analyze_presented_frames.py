#!/usr/bin/env python3
"""Decode bounded Metal drawable diagnostics to PNGs and numeric frame evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib


def decode(record, raw):
    width, height, pitch = (int(record[k]) for k in ("width", "height", "bytesPerRow"))
    fmt = int(record["format"])
    if not (0 < width <= 8192 and 0 < height <= 8192 and width * 4 <= pitch
            and len(raw) == pitch * height <= 8 * 1024 * 1024 and fmt in (70, 71, 80, 81, 90, 94)):
        raise ValueError("Invalid dimensions, stride, byte count or pixel format")
    rgb = bytearray()
    for y in range(height):
        row = raw[y * pitch:y * pitch + width * 4]
        if fmt in (90, 94):
            for value, in struct.iter_unpack("<I", row):
                channels = [(value & 1023) * 255 // 1023, ((value >> 10) & 1023) * 255 // 1023,
                            ((value >> 20) & 1023) * 255 // 1023]
                rgb.extend(channels[::-1] if fmt == 94 else channels)
        else:
            for p in range(0, len(row), 4):
                rgb.extend((row[p + 2], row[p + 1], row[p]) if fmt in (80, 81) else row[p:p + 3])
    return width, height, rgb


def png(width, height, rgb):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    rows = b"".join(b"\0" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="Fresh analysis directory")
    args = parser.parse_args()
    manifest = json.loads((args.input / "run.json").read_text())
    start, count = int(manifest["firstFrame"]), int(manifest["sampleCount"])
    if manifest["schemaVersion"] != 1 or not (1 <= start <= 10000 and 1 <= count <= 16):
        raise ValueError("Unexpected diagnostic manifest")
    args.output.mkdir(parents=True, exist_ok=False)
    frames, previous = [], None
    for frame in range(start, start + count):
        stem = f"frame-{frame:04d}"
        path = args.input / (stem + ".gpu.json")
        if not path.exists():
            frames.append({"frame": frame, "status": "missing-gpu-record"})
            continue
        record = json.loads(path.read_text())
        info = dict(record)
        presented = args.input / (stem + ".presented.json")
        info["presentedTime"] = json.loads(presented.read_text())["presentedTime"] if presented.exists() else None
        name = record.get("pixels")
        if name:
            if Path(name).name != name or not name.endswith(".pixels"):
                raise ValueError("Unsafe pixel filename")
            width, height, rgb = decode(record, (args.input / name).read_bytes())
            (args.output / (stem + ".png")).write_bytes(png(width, height, rgb))
            info["rgbSha256"] = hashlib.sha256(rgb).hexdigest()
            info["meanRGB"] = [round(sum(rgb[c::3]) / (width * height), 4) for c in range(3)]
            info["blackPixelFraction"] = round(sum(1 for p in range(0, len(rgb), 3)
                if max(rgb[p:p + 3]) <= 2) / (width * height), 6)
            if previous and previous[:2] == (width, height):
                old = previous[2]
                info["previousMeanAbsoluteDifference"] = round(sum(abs(a - b) for a, b in zip(rgb, old)) / len(rgb), 4)
                info["previousComplementDifference"] = round(sum(abs(a + b - 255) for a, b in zip(rgb, old)) / len(rgb), 4)
            previous = (width, height, rgb)
        source = record.get("source", {})
        source_name = source.get("pixels")
        if source_name:
            if Path(source_name).name != source_name or not source_name.endswith(".source.pixels"):
                raise ValueError("Unsafe source pixel filename")
            width, height, rgb = decode(source, (args.input / source_name).read_bytes())
            (args.output / (stem + ".source.png")).write_bytes(png(width, height, rgb))
            info["source"] = dict(source, rgbSha256=hashlib.sha256(rgb).hexdigest(),
                meanRGB=[round(sum(rgb[c::3]) / (width * height), 4) for c in range(3)],
                blackPixelFraction=round(sum(1 for p in range(0, len(rgb), 3)
                    if max(rgb[p:p + 3]) <= 2) / (width * height), 6))
        frames.append(info)
    result = {"manifest": manifest, "frames": frames}
    (args.output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"records": len(frames), "pixelFrames": sum("rgbSha256" in f for f in frames),
                      "nonzeroPresentationTimes": sum(bool(f.get("presentedTime")) for f in frames),
                      "summary": str(args.output / "summary.json")}))


if __name__ == "__main__":
    main()
