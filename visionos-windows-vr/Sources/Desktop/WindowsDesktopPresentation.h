#ifndef WVR_DESKTOP_PRESENTATION_H
#define WVR_DESKTOP_PRESENTATION_H
#include <stdint.h>

/* Main-thread snapshot of the largest visible D3D client. Coordinates are
 * window points, identical to winios_desktop_point_from_window's input. */
typedef struct {
    uint64_t window;
    double width, height;
    double x, y, view_width, view_height;
    double compositor_x, compositor_y, compositor_width, compositor_height;
} WVRDesktopPresentationV1;
int wvr_desktop_copy_presentation_v1(WVRDesktopPresentationV1 *out);
#endif
