#!/usr/bin/env python3
"""Require Wine's data-only Normaliz forwarder for managed TLS; execute no guest code."""
from pathlib import Path


def is_data_only_x64_pe(path):
    """Wine's forwarding-only DLLs have no entry point or executable sections."""
    import struct
    try:
        data = path.read_bytes()
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        if data[:2] != b'MZ' or data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, pe+4)[0] != 0x8664:
            return False
        count, = struct.unpack_from('<H', data, pe + 6)
        optional_size, = struct.unpack_from('<H', data, pe + 20)
        optional = pe + 24
        magic, = struct.unpack_from('<H', data, optional)
        code_size, = struct.unpack_from('<I', data, optional + 4)
        entry, = struct.unpack_from('<I', data, optional + 16)
        if magic != 0x20b or code_size or entry or not 0 < count <= 96:
            return False
        sections = optional + optional_size
        return all(not (struct.unpack_from('<I', data, sections + i * 40 + 36)[0] & 0x20000020)
                   for i in range(count))
    except (OSError, ValueError, struct.error):
        return False



if __name__ == "__main__":
    import sys
    path = Path(sys.argv[1]) / "Runtime/arm64ec-windows/normaliz.dll"
    if path.is_symlink() or not is_data_only_x64_pe(path):
        raise SystemExit("Missing or invalid Wine Normaliz data-only forwarder for managed HTTPS: " + str(path))
    print("Managed HTTPS normalization dependency verified.")
