#!/usr/bin/env python3
"""Exercise production output-recovery ordering and failures without starting Wine."""
from pathlib import Path
import argparse,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator',help='Also exercise real RemoteIO on this booted visionOS simulator UUID')
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='wvr-audio-recovery-') as temp:
 w=Path(temp);src=w/'build/ntdll-unix/audio_null_ios.c';src.parent.mkdir(parents=True)
 shutil.copy2(ROOT/'third-party/madeira/build/ntdll-unix/audio_null_ios.c',src)
 subprocess.run(['git','-C',str(w),'apply',str(ROOT/'windows-runtime-plugin/patches/0023-madeira-audio-output-recovery.patch')],check=True)
 subprocess.run(['git','-C',str(w),'apply',str(ROOT/'windows-runtime-plugin/patches/0024-madeira-reinitialize-audio-output.patch')],check=True)
 s=src.read_text();body=s[s.index('/* WVR audio output recovery v1:'):s.index('/* ml1026: "this client feeds the real endpoint"')]
 pre=r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>
#include <string.h>
#define noErr 0
#define kAudioUnitErr_Uninitialized -10867
#define kAudioUnitScope_Global 0
#define IOS_MAX_STREAMS 16
typedef int32_t OSStatus;
struct ios_stream { int started; uint64_t write_pos, play_pos; };
static struct { void *au; int running; } g_dev;
static _Atomic(struct ios_stream *) g_mix[IOS_MAX_STREAMS];
static pthread_mutex_t g_dev_lock=PTHREAD_MUTEX_INITIALIZER;
static int stop_result, uninitialize_result, initialize_result, start_result;
static char trace[128];static unsigned count;
static OSStatus AudioOutputUnitStop(void *p) { assert(p==g_dev.au);trace[count++]='S';return stop_result; }
static OSStatus AudioUnitUninitialize(void *p) { assert(p==g_dev.au);trace[count++]='U';return uninitialize_result; }
static OSStatus AudioUnitInitialize(void *p) { assert(p==g_dev.au);trace[count++]='I';return initialize_result; }
static OSStatus AudioOutputUnitStart(void *p) { assert(p==g_dev.au);trace[count++]='A';return start_result; }
'''
 post=r'''
static void fresh(void) { memset(trace,0,sizeof(trace));count=0;stop_result=uninitialize_result=initialize_result=start_result=0; }
static void expect(const char *s) { assert(count==strlen(s));assert(!memcmp(trace,s,count)); }
int main(void) {
 fresh();assert(wvr_audio_output_reset_v1()==kAudioUnitErr_Uninitialized);expect("");
 int unit;g_dev.au=&unit;
 struct ios_stream stream={.started=1,.write_pos=48000,.play_pos=43000};atomic_store(&g_mix[1],&stream);
 g_dev.running=1;assert(!wvr_audio_output_reset_v1());expect("SUIA");assert(g_dev.running);
 assert(stream.write_pos==48000 && stream.play_pos==43000 && atomic_load(&g_mix[1])==&stream);
 fresh();stop_result=-5;assert(wvr_audio_output_reset_v1()==-5);expect("S");assert(g_dev.running);
 fresh();uninitialize_result=-9;assert(wvr_audio_output_reset_v1()==-9);expect("SUA");assert(g_dev.running);
 fresh();initialize_result=-8;assert(wvr_audio_output_reset_v1()==-8);expect("SUI");assert(!g_dev.running);
 fresh();assert(!wvr_audio_output_reset_v1());expect("UIA");assert(g_dev.running);
 fresh();start_result=-10;assert(wvr_audio_output_reset_v1()==-10);expect("SUIA");assert(!g_dev.running);
 fresh();assert(!wvr_audio_output_reset_v1());expect("UIA");assert(g_dev.running);
 fresh();stream.started=0;assert(!wvr_audio_output_reset_v1());expect("SUI");assert(!g_dev.running);
 fresh();assert(!wvr_audio_output_reset_v1());expect("UI");assert(!g_dev.running);
 assert(stream.write_pos==48000 && stream.play_pos==43000 && atomic_load(&g_mix[1])==&stream);
 puts("PASS output recovery reinitializes one unit, preserves clients/rings, restores playback, retries failures and propagates real errors");
 return 0;
}
'''
 harness=w/'probe.c';harness.write_text(pre+body+post)
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(harness),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True)
 if args.simulator:
  (w/'AudioRecoveryImplementation.h').write_text(body)
  sdk=subprocess.check_output(['xcrun','--sdk','xrsimulator','--show-sdk-path'],text=True).strip()
  subprocess.run(['xcrun','--sdk','xrsimulator','clang','-target','arm64-apple-xros27.0-simulator',
                  '-isysroot',sdk,'-fobjc-arc','-Wall','-Wextra','-Werror','-I',str(w),
                  str(ROOT/'windows-vr-native/Tests/SimulatorAudioRecoveryProbe.m'),
                  '-framework','Foundation','-framework','AVFAudio','-framework','AudioToolbox',
                  '-o',str(w/'simulator-probe')],check=True)
  subprocess.run(['xcrun','simctl','spawn',args.simulator,str(w/'simulator-probe')],check=True,timeout=30)
