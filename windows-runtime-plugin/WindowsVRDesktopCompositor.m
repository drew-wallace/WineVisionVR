/* Extend the receipt-verified pinned implementation in one translation unit.
 * No duplicate driver implementation or private UIKit introspection. Xcode
 * excludes the original Winios.m as a separate compilation unit. */
#import "Winios/Winios.m"
#import "../visionos-windows-vr/Sources/Desktop/WindowsDesktopPresentation.h"

int wvr_desktop_copy_presentation_v1(WVRDesktopPresentationV1 *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!NSThread.isMainThread || !g_compositor_view || g_comp_game || g_compositor_view.hidden) return 0;
    NSNumber *selected = nil;
    double largest = 0;
    /* GDI dialogs never replace the game. A hidden/minimized/destroyed game
     * drops out; among multiple D3D clients the largest visible one wins. */
    for (NSNumber *key in g_metal_layers) {
        CALayer *window = g_layers[key];
        CAMetalLayer *metal = g_metal_layers[key];
        NSValue *client = g_client_rects[key];
        if (!window || window.hidden || metal.hidden || !metal.superlayer || !client) continue;
        CGRect pixels = client.CGRectValue;
        if (pixels.size.width < 64 || pixels.size.height < 64 ||
            metal.drawableSize.width < 64 || metal.drawableSize.height < 64) continue;
        double area = pixels.size.width * pixels.size.height;
        if (area > largest || (area == largest && key.unsignedLongLongValue < selected.unsignedLongLongValue)) {
            selected = key;
            largest = area;
        }
    }
    if (!selected) return 0;
    CAMetalLayer *metal = g_metal_layers[selected];
    CGRect client = [metal convertRect:metal.bounds toLayer:g_compositor_view.superview.layer];
    CGRect compositor = g_compositor_view.frame;
    if (CGRectIsEmpty(client) || CGRectIsEmpty(compositor)) return 0;
    out->window = selected.unsignedLongLongValue;
    out->width = metal.drawableSize.width;
    out->height = metal.drawableSize.height;
    out->x = client.origin.x; out->y = client.origin.y;
    out->view_width = client.size.width; out->view_height = client.size.height;
    out->compositor_x = compositor.origin.x; out->compositor_y = compositor.origin.y;
    out->compositor_width = compositor.size.width; out->compositor_height = compositor.size.height;
    return 1;
}
