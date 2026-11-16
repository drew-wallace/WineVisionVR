#!/usr/bin/env python3
"""Exercise the actual native root enumerator across emulated processes."""
import argparse
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--wine-include', type=Path, required=True)
a = p.parse_args()
source = a.source.read_text()
start = source.index('#include <pthread.h>', source.index('static void load_root_certs'))
end = source.index('const unixlib_entry_t __wine_unix_call_funcs[]', start)
fixture = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "wine/list.h"
typedef int BOOL;
typedef unsigned int DWORD;
typedef int NTSTATUS;
#define TRUE 1
#define STATUS_SUCCESS 0
#define STATUS_NO_MORE_ENTRIES 1
struct enum_root_certs_params { void *buffer; DWORD size; DWORD *needed; };
struct root_cert { struct list entry; DWORD size; unsigned char data[32]; };
static struct list root_cert_list = LIST_INIT(root_cert_list);
static void load_root_certs(void) {
    for (unsigned int i = 1; i <= 3; ++i) {
        struct root_cert *c = calloc(1, sizeof(*c));
        c->size = i * 8;
        memset(c->data, i, c->size);
        list_add_tail(&root_cert_list, &c->entry);
    }
}
''' + source[start:end] + r'''
static void enumerate(int native) {
    unsigned char bytes[64]; DWORD needed;
    struct enum_root_certs_params p = { bytes, sizeof(bytes), &needed };
    for (unsigned int i = 1; i <= 3; ++i) {
        p.size = 1; memset(bytes, 0xcc, sizeof(bytes));
        assert((native ? enum_root_certs(&p) : ios_enum_root_certs_wow(&p)) == STATUS_SUCCESS);
        assert(needed == i * 8 && bytes[0] == 0xcc);
        p.size = sizeof(bytes);
        assert((native ? enum_root_certs(&p) : ios_enum_root_certs_wow(&p)) == STATUS_SUCCESS);
        assert(needed == i * 8);
        for (unsigned int j = 0; j < needed; ++j) assert(bytes[j] == i);
    }
    assert((native ? enum_root_certs(&p) : ios_enum_root_certs_wow(&p)) == STATUS_NO_MORE_ENTRIES);
}
static void *worker(void *arg) {
    for (int i = 0; i < 64; ++i) enumerate((i + (uintptr_t)arg) % 2);
    return NULL;
}
int main(void) {
    // Steam then successive games, including buffer growth retries.
    for (int i = 0; i < 64; ++i) enumerate(i % 2);
    pthread_t threads[8];
    for (uintptr_t i = 0; i < 8; ++i) assert(!pthread_create(&threads[i], NULL, worker, (void *)i));
    for (int i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    assert(list_count(&root_cert_list) == 3);
    while (!list_empty(&root_cert_list)) {
        struct list *entry = list_head(&root_cert_list);
        list_remove(entry); free(LIST_ENTRY(entry, struct root_cert, entry));
    }
    puts("PASS: actual native/WoW64 root enumeration, sequential processes, short buffers, repeated walks and 8 concurrent callers; ASan/UBSan");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-root-enumeration-') as d:
    root = Path(d)
    (root / 'test.c').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-std=c11', '-g', '-fsanitize=address,undefined',
                    '-I' + str(a.wine_include), str(root / 'test.c'), '-o', str(root / 'test')], check=True)
    subprocess.run([str(root / 'test')], check=True, timeout=20)
