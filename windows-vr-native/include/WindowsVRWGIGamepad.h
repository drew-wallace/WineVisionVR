#ifndef WINDOWS_VR_WGI_GAMEPAD_H
#define WINDOWS_VR_WGI_GAMEPAD_H
#include <stdint.h>

/* Windows.Gaming.Input.GamepadReading values from the host's XInput layout.
 * Keep this conversion independent of DirectInput's combined trigger axis. */
struct wvr_wgi_gamepad_reading {
    uint32_t buttons;
    double left_trigger, right_trigger;
    double lx, ly, rx, ry;
};

static inline double wvr_wgi_axis(int16_t value) {
    return value < 0 ? value / 32768.0 : value / 32767.0;
}

static inline struct wvr_wgi_gamepad_reading wvr_gamepad_to_wgi(
    uint16_t buttons, uint8_t lt, uint8_t rt, int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    struct wvr_wgi_gamepad_reading out = {0};
    /* Destination bits are Windows Gaming Input's GamepadButtons flags. */
    static const uint16_t source[] = {
        0x0010, 0x0020, 0x1000, 0x2000, 0x4000, 0x8000, 0x0001,
        0x0002, 0x0004, 0x0008, 0x0100, 0x0200, 0x0040, 0x0080
    };
    unsigned i;
    for (i = 0; i < sizeof(source) / sizeof(source[0]); ++i)
        if (buttons & source[i]) out.buttons |= 1u << i;
    out.left_trigger = lt / 255.0;
    out.right_trigger = rt / 255.0;
    out.lx = wvr_wgi_axis(lx); out.ly = wvr_wgi_axis(ly);
    out.rx = wvr_wgi_axis(rx); out.ry = wvr_wgi_axis(ry);
    return out;
}
#endif
