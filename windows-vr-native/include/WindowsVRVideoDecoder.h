#pragma once
#include <stdint.h>

// Same layout in the Windows guest and native host. No native object pointers
// cross the boundary; stream IDs are owned by the host and never reused.
enum { WVR_VIDEO_ABI = 1, WVR_VIDEO_MAX_DIMENSION = 4096,
       WVR_VIDEO_MAX_PACKET = 8 * 1024 * 1024 };
enum { WVR_VIDEO_OK = 0, WVR_VIDEO_NO_FRAME = 1,
       WVR_VIDEO_INVALID = -1, WVR_VIDEO_UNSUPPORTED = -2,
       WVR_VIDEO_CODEC_ERROR = -3, WVR_VIDEO_CLOSED = -4,
       WVR_VIDEO_BUFFER_TOO_SMALL = -5, WVR_VIDEO_QUEUE_FULL = -6 };
enum { WVR_VIDEO_OPEN, WVR_VIDEO_SUBMIT, WVR_VIDEO_READ,
       WVR_VIDEO_FLUSH, WVR_VIDEO_CLOSE, WVR_VIDEO_CALL_COUNT };
typedef struct WVRVideoCall {
    uint32_t version, size;
    int32_t result;
    uint32_t width, height, fullRange;
    uint64_t stream;
    uint64_t input, inputSize;
    int64_t pts;
    uint64_t y, uv, yCapacity, uvCapacity;
    uint32_t yPitch, uvPitch;
    uint64_t framesDecoded, framesRead;
} WVRVideoCall;
#ifdef __cplusplus
extern "C" {
#endif
// Native unix-call table for the matching, explicitly packaged guest adapter.
const void* const* wvr_video_unix_call_table_v1(uint32_t version, uint32_t count);
void wvr_video_reset_all_v1(void);
#ifdef __cplusplus
}
static_assert(sizeof(WVRVideoCall) == 112);
#endif
