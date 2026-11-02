#ifndef WINDOWS_VR_AUDIO_SESSION_H
#define WINDOWS_VR_AUDIO_SESSION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Keep the legacy embedded runtime's playback activation cooperative with the
// external JIT helper. Returns zero only when the public API adapter is installed.
__attribute__((visibility("default"))) int32_t wvr_audio_session_install_mixing_policy_v1(void);
// Control-thread recovery of the embedded runtime's shared RemoteIO output.
// Reinitializes the existing unit's resources, preserves game audio clients,
// and returns the actual Core Audio status (not a claim about audible recovery).
__attribute__((visibility("default"))) int32_t wvr_audio_output_reset_v1(void);
#ifdef __cplusplus
}
#endif
#endif
