"""Exercise the production shared-section classifier, including native exclusions.

The Windows device fixture separately checks real section coherence, code
execution and translation invalidation. This host check guards its scope.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SharedExecutableSections(unittest.TestCase):
    def test_native_memory_and_unowned_ranges_keep_the_existing_path(self):
        patch = (ROOT / "windows-runtime-plugin/patches/0019-wine-shared-executable-sections.patch").read_text()
        additions = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
        helper = additions[additions.index("static int ios_guest_shared_section_is_host_data"):]
        helper = helper[:helper.index("\n}\n") + 3]
        source = r'''
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#define WINE_IOS 1
enum { SEC_RESERVE=1<<0, SEC_COMMIT=1<<1, SEC_IMAGE=1<<2, SEC_FILE=1<<3,
       VPROT_ARM64EC=1<<4, VPROT_SYSTEM=1<<5, VPROT_WRITECOPY=1<<6 };
struct file_view { void *base; size_t size; unsigned int protect; };
static struct file_view views[4];
static int count, ios_alloc_ec_code;
static void *arm64ec_view=(void *)1;
static void *ios_jit_rx_base_global=(void *)0x800000;
static void *ios_jit_rw_base_global=(void *)0x900000;
static size_t ios_jit_pool_size_global=0x10000;
static uintptr_t alias_start, alias_end;
static struct file_view *find_view(const void *p,size_t size) {
    for(int i=0;i<count;++i) if((uintptr_t)p >= (uintptr_t)views[i].base &&
        (uintptr_t)p+size <= (uintptr_t)views[i].base+views[i].size) return &views[i];
    return NULL;
}
static int ios_jit_anon_alias_overlaps(void *p,size_t size,uintptr_t *start,uintptr_t *end) {
    (void)start; (void)end;
    return alias_end > (uintptr_t)p && alias_start < (uintptr_t)p+size;
}
''' + helper + r'''
int main(void) {
    count=1; views[0]=(struct file_view){(void *)0x10000,0x10000,SEC_RESERVE};
    assert(ios_guest_shared_section_is_host_data((void *)0x10000,0x10000));
    views[0].protect=SEC_COMMIT;
    assert(ios_guest_shared_section_is_host_data((void *)0x10000,0x10000));
    unsigned int rejected[]={0,SEC_IMAGE,SEC_FILE,VPROT_ARM64EC,VPROT_SYSTEM,VPROT_WRITECOPY};
    for(unsigned int i=0;i<sizeof(rejected)/sizeof(*rejected);++i) {
        views[0].protect=rejected[i] ? SEC_RESERVE|rejected[i] : 0;
        assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0x10000));
    }
    views[0].protect=SEC_RESERVE;
    ios_alloc_ec_code=1; assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0x10000)); ios_alloc_ec_code=0;
    arm64ec_view=NULL; assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0x10000)); arm64ec_view=(void *)1;
    assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0));
    assert(!ios_guest_shared_section_is_host_data((void *)(UINTPTR_MAX-0x1000),0x2000));
    assert(!ios_guest_shared_section_is_host_data((void *)0x18000,0x10000));
    alias_start=0x1f000;alias_end=0x21000;
    assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0x10000)); alias_start=alias_end=0;
    count=2; views[1]=(struct file_view){(void *)0x20000,0x10000,SEC_COMMIT};
    assert(ios_guest_shared_section_is_host_data((void *)0x10000,0x20000));
    views[1].protect|=VPROT_ARM64EC;
    assert(!ios_guest_shared_section_is_host_data((void *)0x10000,0x20000));
    views[0]=(struct file_view){(void *)0x800000,0x10000,SEC_COMMIT}; count=1;
    assert(!ios_guest_shared_section_is_host_data((void *)0x800000,0x10000));
    views[0].base=(void *)0x900000;
    assert(!ios_guest_shared_section_is_host_data((void *)0x900000,0x10000));
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="wvr-shared-sections-") as work:
            work = Path(work)
            (work / "test.c").write_text(source)
            subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", str(work / "test.c"),
                            "-o", str(work / "test")], check=True)
            subprocess.run([str(work / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
