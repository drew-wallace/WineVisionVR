#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Desktop-only input sequencing. Counts guest presentation submissions,
 * without GPU waits, texture reads, diagnostic capture, or disk writes. */
int wvr_desktop_pointer_timing_install_v1(void);
uint64_t wvr_desktop_pointer_frame_v1(void);
#ifdef __cplusplus
}
#endif
