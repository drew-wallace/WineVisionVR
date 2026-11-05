#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>
#include "WindowsVRAudioSession.h"
#include <atomic>

namespace {
using LegacyCategoryIMP = BOOL (*)(id, SEL, NSString *, NSError **);
using OptionsCategoryIMP = BOOL (*)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
LegacyCategoryIMP originalLegacyCategory = nullptr;
OptionsCategoryIMP originalOptionsCategory = nullptr;
std::atomic<bool> captureAuthorized{false};

BOOL CooperativeOptionsCategory(id session, SEL selector, NSString *category,
                                AVAudioSessionCategoryOptions options, NSError **error) {
    if (captureAuthorized.load(std::memory_order_acquire) &&
        [category isEqualToString:AVAudioSessionCategoryPlayback]) {
        category = AVAudioSessionCategoryPlayAndRecord;
    }
    return originalOptionsCategory(session, selector, category, options, error);
}

BOOL CooperativeLegacyCategory(id session, SEL selector, NSString *category, NSError **error) {
    if ([category isEqualToString:AVAudioSessionCategoryPlayback]) {
        // The host owns its audio session. The preserved runtime still uses
        // the legacy API, which otherwise clears mixWithOthers set by Swift.
        // Forward the real API result/error; do not synthesize activation.
        return originalOptionsCategory(session, @selector(setCategory:withOptions:error:),
            captureAuthorized.load(std::memory_order_acquire) ? AVAudioSessionCategoryPlayAndRecord : category,
            AVAudioSessionCategoryOptionMixWithOthers, error);
    }
    return originalLegacyCategory(session, selector, category, error);
}
}

void wvr_audio_capture_set_authorized_v1(int32_t authorized) {
    captureAuthorized.store(authorized != 0, std::memory_order_release);
}

int32_t wvr_audio_capture_is_authorized_v1(void) {
    return captureAuthorized.load(std::memory_order_acquire) ? 1 : 0;
}

int32_t wvr_audio_session_install_mixing_policy_v1(void) {
    static dispatch_once_t once;
    static bool installed = false;
    dispatch_once(&once, ^{
        Method legacy = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:error:));
        Method options = class_getInstanceMethod([AVAudioSession class], @selector(setCategory:withOptions:error:));
        if (!legacy || !options) return;
        originalLegacyCategory = reinterpret_cast<LegacyCategoryIMP>(method_getImplementation(legacy));
        originalOptionsCategory = reinterpret_cast<OptionsCategoryIMP>(method_getImplementation(options));
        method_setImplementation(legacy, reinterpret_cast<IMP>(CooperativeLegacyCategory));
        method_setImplementation(options, reinterpret_cast<IMP>(CooperativeOptionsCategory));
        installed = true;
    });
    return installed ? 0 : -1;
}
