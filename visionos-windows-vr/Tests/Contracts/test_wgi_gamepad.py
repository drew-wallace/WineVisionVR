"""Run the same conversion compiled into the Windows Gaming Input guest DLL."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class WGIGamepad(unittest.TestCase):
    def test_reading_matches_windows_gamepad_contract(self):
        program = r'''
#include "WindowsVRWGIGamepad.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    struct wvr_wgi_gamepad_reading value = wvr_gamepad_to_wgi(0xf3ff, 255, 255, -32768, 32767, 32767, -32768);
    assert(value.buttons == 0x3fff);
    assert(value.left_trigger == 1.0 && value.right_trigger == 1.0);
    assert(value.lx == -1.0 && value.ly == 1.0 && value.rx == 1.0 && value.ry == -1.0);
    value = wvr_gamepad_to_wgi(0x1001, 0, 128, 0, 0, 0, 0);
    assert(value.buttons == (4 | 64)); /* A + D-pad up */
    assert(value.left_trigger == 0.0 && value.right_trigger > 0.50 && value.right_trigger < 0.51);
    assert(value.lx == 0.0 && value.ly == 0.0 && value.rx == 0.0 && value.ry == 0.0);
    value = wvr_gamepad_to_wgi(0x0010 | 0x0020 | 0x0200 | 0x0080, 0, 0, 0, 0, 0, 0);
    assert(value.buttons == (1 | 2 | 2048 | 8192)); /* Menu, View, RB, RS */
    value = wvr_gamepad_to_wgi(0x0400, 0, 0, 0, 0, 0, 0);
    assert(value.buttons == 0); /* Guide is reserved by this Windows API. */
    puts("PASS: actual WGI conversion, Windows button flags, independent simultaneous triggers, signed axes and neutral state");
}
'''
        with tempfile.TemporaryDirectory(prefix='wvr-wgi-') as temp:
            temp = Path(temp)
            (temp / 'probe.c').write_text(program)
            subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-I', str(ROOT / 'windows-vr-native/include'),
                            str(temp / 'probe.c'), '-o', str(temp / 'probe')], check=True)
            subprocess.run([str(temp / 'probe')], check=True, timeout=15)
