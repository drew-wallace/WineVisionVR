#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install before Wine starts. Its virtual Windows processes share this native
// task, so shared texture/event send rights need an app-local name registry.
// Returns 1 when installed, 0 when the pinned writable dispatch ABI is absent.
int wvr_shared_resource_ports_install_v1(void);

#ifdef __cplusplus
}
#endif
