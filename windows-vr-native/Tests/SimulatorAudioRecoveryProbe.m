#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#define IOS_MAX_STREAMS 16
struct ios_stream { int started; uint64_t write_pos, play_pos; };
static struct { AudioUnit au; int running; } g_dev;
static _Atomic(struct ios_stream *) g_mix[IOS_MAX_STREAMS];
static pthread_mutex_t g_dev_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t passes;

// Generated from the actual patched runtime by test_audio_recovery.py.
#include "AudioRecoveryImplementation.h"

static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                       AudioBufferList *buffers) {
    (void)context; (void)flags; (void)time; (void)bus; (void)frames;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
        if (buffers->mBuffers[i].mData)
            memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
    atomic_fetch_add(&passes, 1);
    return noErr;
}

static void wait_for_render(uint64_t previous) {
    for (int i = 0; i < 300 && atomic_load(&passes) <= previous; ++i) usleep(10000);
    assert(atomic_load(&passes) > previous);
}

int main(void) { @autoreleasepool {
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    assert([session setCategory:AVAudioSessionCategoryPlayback
                   withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]);
    assert([session setActive:YES error:&error]);
    AudioComponentDescription desc = { .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    assert(component && !AudioComponentInstanceNew(component, &g_dev.au));
    AudioUnit original = g_dev.au;
    AudioStreamBasicDescription format = { .mSampleRate = 48000,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mFramesPerPacket = 1, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
        .mBytesPerFrame = 8, .mBytesPerPacket = 8 };
    AURenderCallbackStruct callback = { .inputProc = render };
    assert(!AudioUnitSetProperty(original, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &format, sizeof(format)));
    assert(!AudioUnitSetProperty(original, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &callback, sizeof(callback)));
    assert(!AudioUnitInitialize(original));
    struct ios_stream stream = { .started = 1, .write_pos = 48000, .play_pos = 43000 };
    atomic_store(&g_mix[0], &stream);
    assert(!AudioOutputUnitStart(original)); g_dev.running = 1;
    wait_for_render(0);
    for (int i = 0; i < 3; ++i) {
        assert(!wvr_audio_output_reset_v1());
        assert(g_dev.au == original && g_dev.running);
        uint64_t before = atomic_load(&passes);
        wait_for_render(before);
        assert(stream.write_pos == 48000 && stream.play_pos == 43000);
        assert(atomic_load(&g_mix[0]) == &stream);
    }
    stream.started = 0;
    assert(!wvr_audio_output_reset_v1() && !g_dev.running);
    assert(!AudioUnitUninitialize(original));
    assert(!AudioComponentInstanceDispose(original));
    assert([session setActive:NO error:&error]);
    puts("PASS real RemoteIO resumes callbacks after three resource reinitializations; one instance and client state preserved; idle stays stopped");
} }
