"""Pinned renderer packaging must fail closed before an app can be installed."""
from pathlib import Path
import hashlib
import json
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'windows-vr-tools'))
import stage_angle_compatibility as angle


class AngleResources(unittest.TestCase):
    def test_runtime_and_packaging_pins_agree(self):
        runtime = (ROOT / 'visionos-windows-vr/Sources/WindowsVRAngleTrial.swift').read_text()
        for name, digest in re.findall(r'Asset\(name: "([^"]+)", sha256: "([^"]+)"\)', runtime):
            self.assertEqual(angle.FILES[name], digest)
        self.assertIn('stage_angle_compatibility.py', (ROOT / 'windows-vr-tools/verify_wine_bundle.sh').read_text())
        for spec in ['project.yml', 'project.prebuilt.yml']:
            self.assertIn('path: Resources/ANGLECompatibility', (ROOT / 'visionos-windows-vr' / spec).read_text())

    def test_missing_corrupt_or_symlinked_resources_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError): angle.verify(root / 'absent')
            (root / 'manifest.json').write_text(json.dumps(angle.MANIFEST))
            for name in angle.FILES: (root / name).write_bytes(b'bad')
            with self.assertRaises(ValueError): angle.verify(root)
            (root / 'libEGL.dll').unlink()
            (root / 'libEGL.dll').symlink_to(root / 'ABOUT')
            with self.assertRaises(ValueError): angle.verify(root)

    def test_hash_match_alone_cannot_admit_wrong_architecture(self):
        original = angle.FILES['libEGL.dll']
        try:
            data = b'MZ' + b'\0' * 254
            angle.FILES['libEGL.dll'] = hashlib.sha256(data).hexdigest()
            with self.assertRaises(ValueError): angle.check('libEGL.dll', data)
        finally:
            angle.FILES['libEGL.dll'] = original
