#pragma once
#ifdef __cplusplus
extern "C" {
#endif
/* Explicit WVR_PRESENT_DIAGNOSTICS=1 only; writes a bounded, unique local run. */
void wvr_present_diagnostics_install_v1(const char *parent_directory);
#ifdef __cplusplus
}
#endif
