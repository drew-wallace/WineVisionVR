"""Guard the fallback alias against merging unrelated DLLs or process state."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BootstrapNtdll(unittest.TestCase):
    def test_only_the_current_process_bootstrap_module_is_reused(self):
        patch = (ROOT / "windows-runtime-plugin/patches/0020-wine-bootstrap-ntdll-fallback.patch").read_text()
        additions = "\n".join(line[1:] for line in patch.splitlines()
                              if line.startswith("+") and not line.startswith("+++"))
        helper = additions[additions.index("static WINE_MODREF *madeira_bootstrap_ntdll_for_fallback"):]
        helper = helper[:helper.index("\n}") + 2]
        source = r'''
#include <assert.h>
#include <wchar.h>
#define WCHAR wchar_t
#define wcsicmp wcscasecmp
typedef struct { struct { void *DdagNode; } ldr; } WINE_MODREF;
static void *node_ntdll;
static WINE_MODREF *loaded;
static WINE_MODREF *find_basename_module(const WCHAR *name) {
    assert(!wcscmp(name, L"ntdll.dll")); return loaded;
}
''' + helper + r'''
int main(void) {
    int bootstrap, other_process;
    WINE_MODREF first = {{&bootstrap}}, second = {{&other_process}};
    node_ntdll = &bootstrap; loaded = &first;
    assert(madeira_bootstrap_ntdll_for_fallback(L"ntdll.dll") == &first);
    assert(madeira_bootstrap_ntdll_for_fallback(L"NTDLL.DLL") == &first);
    assert(madeira_bootstrap_ntdll_for_fallback(L"ntdll") == &first);
    const WCHAR *unrelated[] = {L"kernel32.dll", L"kernelbase.dll", L"user32.dll",
        L"myntdll.dll", L"ntdll.dll.backup", L"", L"ntdll.exe"};
    for (unsigned int i = 0; i < sizeof(unrelated)/sizeof(*unrelated); ++i)
        assert(!madeira_bootstrap_ntdll_for_fallback(unrelated[i]));
    loaded = &second;
    assert(!madeira_bootstrap_ntdll_for_fallback(L"ntdll.dll"));
    loaded = NULL;
    assert(!madeira_bootstrap_ntdll_for_fallback(L"ntdll.dll"));
    loaded = &first; node_ntdll = NULL;
    assert(!madeira_bootstrap_ntdll_for_fallback(L"ntdll.dll"));
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wvr-bootstrap-ntdll-") as work:
            work = Path(work)
            (work / "probe.c").write_text(source)
            subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", str(work / "probe.c"),
                            "-o", str(work / "probe")], check=True)
            subprocess.run([str(work / "probe")], check=True)


if __name__ == "__main__":
    unittest.main()
