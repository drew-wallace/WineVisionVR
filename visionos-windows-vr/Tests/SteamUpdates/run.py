#!/usr/bin/env python3
"""Run production update/install code against an encrypted local Steam CDN fixture."""
from pathlib import Path
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import struct
import subprocess
import tempfile
import threading
import zipfile
import zlib

root = Path(__file__).resolve().parents[3]
src = root / 'visionos-windows-vr/Sources/Steam'
steam = src / 'SwiftSteam'
key = '42' * 32
iv = '13' * 16
requests = []


def varint(n):
    result = bytearray()
    while n > 127:
        result.append((n & 127) | 128)
        n >>= 7
    return bytes(result + bytes([n]))


def number(field, value):
    return varint(field << 3) + varint(value)


def blob(field, value):
    return varint(field << 3 | 2) + varint(len(value)) + value


def encrypt(data, ecb=False):
    args = ['openssl', 'enc', '-aes-256-ecb' if ecb else '-aes-256-cbc', '-K', key]
    args += ['-nopad'] if ecb else ['-iv', iv]
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


chunks = {}

def chunk(data, offset):
    sha = hashlib.sha1(data).digest()
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('chunk', data)
    encrypted = encrypt(bytes.fromhex(iv), ecb=True) + encrypt(archive.getvalue())
    chunks[f'/depot/11/chunk/{sha.hex()}'] = encrypted
    return (blob(1, sha) + varint(2 << 3 | 5) + struct.pack('<I', zlib.adler32(data, 0))
            + number(3, offset) + number(4, len(data)) + number(5, len(encrypted)))


def manifest(files):
    result = b''
    for name, pieces in files:
        payload = blob(1, name.encode()) + number(2, sum(map(len, pieces or [])))
        offset = 0
        if pieces is None:
            payload += number(3, 0x40)
        for data in pieces or []:
            payload += blob(6, chunk(data, offset))
            offset += len(data)
        result += blob(1, payload)
    return result


manifests = {
    '/depot/11/manifest/101/5': manifest([
        ('game.bin', [b'AAAA', b'BBBB', b'CCCC']),
        ('old/obsolete.bin', [b'gone']), ('modified.bin', [b'keep']), ('empty.bin', []), ('empty-dir', None)]),
    '/depot/11/manifest/102/5': manifest([('GAME.BIN', [b'CCCC', b'NEW!', b'AAAA'])]),
    '/depot/11/manifest/103/5': manifest([('game.bin', [b'AAAA', b'CCCC'])]),
}


class CDN(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        requests.append(path)
        payload = manifests.get(path, chunks.get(path))
        self.send_response(200 if payload is not None else 404)
        self.end_headers()
        self.wfile.write(payload or b'')

    def log_message(self, *_):
        pass


files = ['SteamInstall.swift', 'SteamKeyValues.swift',
         'SwiftSteam/Library/SteamAppInfo.swift', 'SwiftSteam/Library/SteamLibraryFetcher.swift',
         'SwiftSteam/Library/SteamPICSMetadata.swift', 'SwiftSteam/Proto/SteamProtoMessages.swift',
         'SwiftSteam/Core/SteamError.swift', 'SwiftSteam/Core/SteamProtocol.swift',
         'SwiftSteam/Core/SteamMessageCodec.swift', 'SwiftSteam/Core/SteamCMSession.swift',
         'SwiftSteam/Install/AppManifestWriter.swift', 'SwiftSteam/Content/DepotManifest.swift',
         'SwiftSteam/Content/DepotDownloader.swift', 'SwiftSteam/Content/ContentDecryptor.swift',
         'SwiftSteam/Content/SteamBackgroundTransfers.swift']
with tempfile.TemporaryDirectory(prefix='wvr-steam-updates-') as temp:
    objects = []
    for name in ['lzma_shim', 'zstd_edu', 'chunk_zip']:
        obj = str(Path(temp) / (name + '.o'))
        subprocess.run(['xcrun', 'clang', '-c', str(steam / (name + '.c')), '-o', obj], check=True)
        objects.append(obj)
    executable = str(Path(temp) / 'probe')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-import-objc-header', str(steam / 'lzma_shim.h'), '-lz', '-llzma',
                    *[str(src / f) for f in files], *objects,
                    str(Path(__file__).with_name('Probe.swift')), '-o', executable], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), CDN)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([executable, f'http://127.0.0.1:{server.server_port}', temp], check=True)
    finally:
        server.shutdown()
    counts = {path: requests.count(path) for path in chunks}
    # All original chunks were fetched once. The changed chunk is fetched for
    # the first update and again for the later cancelled/resumed update.
    changed = '/depot/11/chunk/' + hashlib.sha1(b'NEW!').hexdigest()
    assert all(n == (2 if path == changed else 1) for path, n in counts.items()), counts
    print('PASS CDN request counts: no unchanged or relocated chunk downloaded again')
