"""The source preparer and strict stager must agree on every DXMT patch."""
import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GraphicsInputContractTests(unittest.TestCase):
    def test_preparation_and_staging_require_the_same_dxmt_patches(self):
        prepare = (ROOT / "windows-vr-tools/prepare_d3d12_profile.sh").read_text()
        stage = (ROOT / "windows-vr-tools/stage_d3d12_profile.sh").read_text()
        patches = ast.literal_eval(re.search(r"patches=(\[.*?\])", prepare, re.S).group(1))
        required = ast.literal_eval(re.search(r"required=(\{.*?\})\nif set\(inputs\)", stage, re.S).group(1))
        expected = {p for p in required if p.startswith("windows-vr-openxr/patches/")}
        self.assertEqual(set(patches), expected)
        self.assertTrue(all((ROOT / p).is_file() for p in expected))


if __name__ == "__main__":
    unittest.main()
