"""Exercise the actual native desktop snapshot against a real Core Animation tree."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class DesktopPresentation(unittest.TestCase):
    def test_visible_client_selection_and_coordinate_snapshot(self):
        implementation = (ROOT / 'windows-runtime-plugin/WindowsVRDesktopCompositor.m').read_text()
        implementation = implementation[implementation.index('int wvr_desktop_copy_presentation_v1'):]
        fixture = r'''
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "WindowsDesktopPresentation.h"
#include <assert.h>
static NSView *g_compositor_view;
static BOOL g_comp_game;
@interface NSValue (WVRRect)
@property (readonly) CGRect CGRectValue;
@end
@implementation NSValue (WVRRect)
- (CGRect)CGRectValue { return NSRectToCGRect(self.rectValue); }
@end
static NSMutableDictionary<NSNumber *, CALayer *> *g_layers;
static NSMutableDictionary<NSNumber *, CAMetalLayer *> *g_metal_layers;
static NSMutableDictionary<NSNumber *, NSValue *> *g_client_rects;
''' + implementation + r'''
static void add(unsigned key, double w, double h, BOOL metal) {
    CALayer *window = [CALayer layer]; window.frame = CGRectMake(0, 0, w, h);
    [g_compositor_view.layer addSublayer:window]; g_layers[@(key)] = window;
    g_client_rects[@(key)] = [NSValue valueWithRect:NSMakeRect(0, 0, w, h)];
    if (metal) {
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.frame = CGRectMake(10, 20, w / 2, h / 2);
        layer.drawableSize = CGSizeMake(w, h);
        [window addSublayer:layer]; g_metal_layers[@(key)] = layer;
    }
}
int main(void) { @autoreleasepool {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1600, 1000)]; root.wantsLayer = YES;
    g_compositor_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)];
    g_compositor_view.wantsLayer = YES; [root addSubview:g_compositor_view];
    g_layers = [NSMutableDictionary new]; g_metal_layers = [NSMutableDictionary new];
    g_client_rects = [NSMutableDictionary new]; WVRDesktopPresentationV1 out;
    assert(!wvr_desktop_copy_presentation_v1(NULL));
    assert(!wvr_desktop_copy_presentation_v1(&out));
    add(1, 800, 600, YES); add(2, 1920, 1080, YES); add(3, 4000, 3000, NO);
    assert(wvr_desktop_copy_presentation_v1(&out) && out.window == 2);
    assert(out.width == 1920 && out.height == 1080 && out.view_width == 960 && out.view_height == 540);
    assert(out.compositor_width == 1280 && out.compositor_height == 720);
    ((CALayer *)g_layers[@2]).hidden = YES;
    assert(wvr_desktop_copy_presentation_v1(&out) && out.window == 1);
    ((CALayer *)g_layers[@2]).hidden = NO;
    g_client_rects[@2] = [NSValue valueWithRect:NSMakeRect(0, 0, 600, 400)];
    assert(wvr_desktop_copy_presentation_v1(&out) && out.window == 1);
    [g_metal_layers removeObjectForKey:@1];
    assert(wvr_desktop_copy_presentation_v1(&out) && out.window == 2);
    g_comp_game = YES; assert(!wvr_desktop_copy_presentation_v1(&out));
    g_comp_game = NO; g_compositor_view.hidden = YES;
    assert(!wvr_desktop_copy_presentation_v1(&out));
    puts("PASS: actual native snapshot, largest visible client, GDI dialog exclusion, hidden/destroyed/resized windows, VR exclusion");
} }
'''
        with tempfile.TemporaryDirectory(prefix='wvr-desktop-presentation-') as temp:
            temp = Path(temp)
            (temp / 'probe.m').write_text(fixture)
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(ROOT / 'visionos-windows-vr/Sources/Desktop'),
                            str(temp / 'probe.m'), '-framework', 'AppKit', '-framework', 'QuartzCore',
                            '-framework', 'Metal', '-o', str(temp / 'probe')], check=True)
            subprocess.run([str(temp / 'probe')], check=True, timeout=15)
