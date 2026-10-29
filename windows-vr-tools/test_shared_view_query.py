#!/usr/bin/env python3
"""Exercise the prepared get_committed_size implementation with server/view fixtures."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", required=True, type=Path)
    args = parser.parse_args()
    source = (args.runtime_source / "build/ntdll-unix/virtual_ios.c").read_text()
    start = source.index("static SIZE_T get_committed_size(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    helper = source[start:end]
    fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
typedef size_t SIZE_T;
typedef unsigned char BYTE;
#define WINE_IOS 1
#define SEC_RESERVE 1
#define VPROT_COMMITTED 0x20
#define STATUS_NOT_MAPPED_VIEW 0xc0000019u
#define STATUS_ACCESS_DENIED 0xc0000022u
#define min(a,b) ((a) < (b) ? (a) : (b))
#define ROUND_ADDR(p,m) ((void *)((uintptr_t)(p) & ~(uintptr_t)(m)))
static const uintptr_t page_mask = 4095;
struct file_view { void *base; SIZE_T size; unsigned int protect; };
struct request { uintptr_t base; SIZE_T offset; };
struct reply { SIZE_T size; int committed; };
static struct request request_value;
static struct reply reply_value;
static unsigned int server_status, calls, changes;
static BYTE pages[4];
static uintptr_t fixture_base = 0x10000;
#define SERVER_START_REQ(name) do { struct request *req=&request_value; struct reply *reply=&reply_value;
#define SERVER_END_REQ } while (0)
#define wine_server_client_ptr(p) ((uintptr_t)(p))
static unsigned int wine_server_call(struct request *req) { (void)req; ++calls; return server_status; }
static BYTE get_page_vprot(void *p) { return pages[((uintptr_t)p-fixture_base)/4096]; }
static void set_page_vprot_bits(void *p, SIZE_T size, BYTE bits, BYTE clear) {
    ++changes;
    for (SIZE_T i=0;i<size;i+=4096) {
        SIZE_T index=((uintptr_t)p+i-fixture_base)/4096;
        pages[index]=(pages[index]&~clear)|bits;
    }
}
static SIZE_T get_vprot_range_size(void *p, SIZE_T size, BYTE mask, BYTE *vprot) {
    *vprot=get_page_vprot(p);
    for (SIZE_T i=4096;i<size;i+=4096)
        if ((*vprot^get_page_vprot((char *)p+i))&mask) return i;
    return size;
}
''' + helper + r'''
int main(void) {
    struct file_view view={(void *)0x10000,0x4000,SEC_RESERVE};
    BYTE prot=0;
    pages[0]=pages[1]=1|VPROT_COMMITTED; pages[2]=pages[3]=1;
    server_status=STATUS_NOT_MAPPED_VIEW;
    // A physical sibling view must advance a query and preserve local commit
    // boundaries, without claiming a successful server commit or changing bits.
    assert(get_committed_size(&view,(void *)0x10000,SIZE_MAX,&prot,0xff)==0x2000);
    assert(prot==(1|VPROT_COMMITTED) && !changes);
    assert(get_committed_size(&view,(void *)0x12000,SIZE_MAX,&prot,0xff)==0x2000);
    assert(prot==1 && !changes);
    assert(get_committed_size(&view,(void *)0x10000,0x1000,&prot,0xff)==0x1000);
    // Registered mappings retain server-authoritative commitment.
    server_status=0; reply_value.size=0x4000; reply_value.committed=1;
    assert(get_committed_size(&view,(void *)0x10000,SIZE_MAX,&prot,0xff)==0x4000);
    assert(changes==1 && (pages[3]&VPROT_COMMITTED));
    // Other server errors must never be disguised as valid mapping metadata.
    server_status=STATUS_ACCESS_DENIED;
    assert(get_committed_size(&view,(void *)0x10000,SIZE_MAX,&prot,0xff)==0);
    assert(changes==1);
    // Private/non-reserved mappings never consult this fallback/server path.
    unsigned int before=calls;
    view.protect=0;
    assert(get_committed_size(&view,(void *)0x11000,SIZE_MAX,&prot,0xff)==0x3000);
    assert(calls==before);
}
'''
    with tempfile.TemporaryDirectory(prefix="wvr-view-query-") as work:
        work = Path(work)
        (work / "probe.c").write_text(fixture)
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                        str(work / "probe.c"), "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=10)
    print("PASS: foreign-view progress/protections, owned server commits, error scope; ASan/UBSan")


if __name__ == "__main__":
    main()
