#!/usr/bin/env python3
"""Exercise the actual mobile display fallbacks with poisoned bridge outputs."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", type=Path, required=True)
    args = parser.parse_args()
    root = args.runtime_source.resolve() / "dxmt/src/winemetal"
    source = (root / "unix/winemetal_unix.c").read_text()
    start = source.index("static NTSTATUS\n_WMTGetDisplayDescription(void *obj)",
                         source.index("_WMTQueryDisplaySettingForLayer(void *obj)"))
    functions = source[start:source.index("#endif", start)]
    fixture = r'''
#include "winemetal_thunks.h"
#include <assert.h>
#include <string.h>
typedef int NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_NOT_SUPPORTED -1
''' + functions + r'''
int main() {
  for (unsigned poison = 1; poison <= 255; ++poison) {
    struct WMTDisplayDescription desc;
    memset(&desc, poison, sizeof(desc));
    struct unixcall_generic_obj_ptr_noret generic = {0};
    generic.arg.ptr = &desc;
    assert(_WMTGetDisplayDescription(&generic) == STATUS_SUCCESS);
    assert(desc.red_primaries[0] == 0.64f && desc.red_primaries[1] == 0.33f);
    assert(desc.green_primaries[0] == 0.30f && desc.green_primaries[1] == 0.60f);
    assert(desc.blue_primaries[0] == 0.15f && desc.blue_primaries[1] == 0.06f);
    assert(desc.white_points[0] == 0.3127f && desc.white_points[1] == 0.3290f);
    assert(desc.maximum_edr_color_component_value == 1.0f);
    assert(desc.maximum_potential_edr_color_component_value == 1.0f);
    assert(desc.maximum_reference_edr_color_component_value == 0.0f);
    struct WMTEDRValue edr;
    memset(&edr, poison, sizeof(edr)); generic.arg.ptr = &edr;
    assert(_MetalLayer_getEDRValue(&generic) == STATUS_SUCCESS);
    assert(edr.maximum_edr_color_component_value == 1.0f);
    assert(edr.maximum_potential_edr_color_component_value == 1.0f);
    struct WMTHDRMetadata metadata, zero = {0};
    memset(&metadata, poison, sizeof(metadata));
    struct unixcall_query_display_setting query;
    memset(&query, poison, sizeof(query)); query.hdr_metadata.ptr = &metadata;
    assert(_WMTQueryDisplaySetting(&query) == STATUS_SUCCESS);
    assert(!query.ret && query.colorspace == WMTColorSpaceSRGB);
    assert(memcmp(&metadata, &zero, sizeof(metadata)) == 0);
    struct unixcall_query_display_setting_for_layer layer;
    memset(&layer, poison, sizeof(layer)); layer.hdr_metadata.ptr = &metadata;
    memset(&metadata, poison, sizeof(metadata));
    assert(_WMTQueryDisplaySettingForLayer(&layer) == STATUS_SUCCESS);
    assert(layer.version == 0 && layer.colorspace == WMTColorSpaceSRGB);
    assert(layer.edr_value.maximum_edr_color_component_value == 1.0f);
    assert(layer.edr_value.maximum_potential_edr_color_component_value == 1.0f);
    assert(memcmp(&metadata, &zero, sizeof(metadata)) == 0);
    assert(_WMTUpdateDisplaySetting(NULL) == STATUS_NOT_SUPPORTED);
    // Null optional metadata must also establish the no-override outputs.
    layer.hdr_metadata.ptr = NULL; query.hdr_metadata.ptr = NULL;
    assert(_WMTQueryDisplaySettingForLayer(&layer) == STATUS_SUCCESS);
    assert(_WMTQueryDisplaySetting(&query) == STATUS_SUCCESS);
    assert(layer.version == 0 && !query.ret);
  }
}
'''
    with tempfile.TemporaryDirectory(prefix="wvr-display-queries-") as work:
        work = Path(work)
        (work / "probe.c").write_text(fixture)
        subprocess.run(["xcrun", "clang", "-std=c2x", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-I", str(root), str(work / "probe.c"),
                        "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=15)
    print("PASS: four mobile display query outputs, 255 poison patterns, SDR/no override, null metadata; ASan/UBSan")


if __name__ == "__main__":
    main()
