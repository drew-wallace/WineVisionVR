#!/usr/bin/env python3
"""Exercise the actual microphone ring from the prepared Wine audio patch."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wvr-microphone-") as temporary:
    work=Path(temporary)
    source=work/"build/ntdll-unix/audio_null_ios.c"
    source.parent.mkdir(parents=True)
    shutil.copy2(root/"third-party/madeira/build/ntdll-unix/audio_null_ios.c",source)
    for patch in ("0023-madeira-audio-output-recovery.patch",
                  "0024-madeira-reinitialize-audio-output.patch",
                  "0026-madeira-microphone-capture.patch"):
        subprocess.run(["git","apply",str(root/"windows-runtime-plugin/patches"/patch)],cwd=work,check=True)
    code=r'''
#include "ios_capture_ring.h"
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include <sched.h>
static unsigned char data[8192], scratch[8192];
static struct wvr_capture_ring ring;
static uint32_t frames,flags; static uint64_t pos,qpc;
static void setup(unsigned rate,unsigned channels,unsigned bits,int floating,unsigned capacity) {
 assert(!wvr_capture_init(&ring,data,capacity,rate,channels,bits,floating));
}
static void get(void) {assert(wvr_capture_get(&ring,scratch,&frames,&flags,&pos,&qpc)==1);}
static void* producer(void* unused) {
 (void)unused;
 for(unsigned i=0;i<10000;++i) {
  while(wvr_capture_available(&ring)>=ring.capacity) sched_yield();
  float sample=(float)(i%101)/101;
  wvr_capture_push(&ring,&sample,1,48000,100000+i*208);
 }
 return 0;
}
int main(void) {
 assert(!wvr_capture_format(1000,1,16,0));assert(!wvr_capture_format(48000,6,16,0));
 assert(!wvr_capture_format(48000,1,24,0));assert(!wvr_capture_format(48000,1,16,1));
 setup(48000,1,16,0,16);
 assert(!wvr_capture_get(&ring,scratch,&frames,&flags,&pos,&qpc)&&!frames);
 float samples[]={-2,-1,-.5,0,.5,1,2,NAN};
 wvr_capture_push(&ring,samples,8,48000,123456);
 get();assert(frames==8&&pos==0&&qpc==123456&&!flags);
 const int16_t expected[]={-32768,-32768,-16383,0,16383,32767,32767,0};
 assert(!memcmp(scratch,expected,sizeof(expected)));
 assert(wvr_capture_get(&ring,scratch,&frames,&flags,&pos,&qpc)==-1);
 assert(wvr_capture_release(&ring,7)==-1&&ring.pending==8);
 assert(!wvr_capture_release(&ring,0));get();assert(pos==0&&frames==8);
 assert(!wvr_capture_release(&ring,8));assert(wvr_capture_available(&ring)==0);
 assert(wvr_capture_release(&ring,0)==-1);
 /* Wrap across the end, with two separately timestamped hardware blocks. */
 wvr_capture_push(&ring,samples,8,48000,223456);get();assert(pos==8&&qpc==223456);
 assert(!wvr_capture_release(&ring,8));
 wvr_capture_push(&ring,samples,8,48000,323456);get();assert(pos==16&&qpc==323456);
 assert(!memcmp(scratch,expected,sizeof(expected)));assert(!wvr_capture_release(&ring,8));
 wvr_capture_destroy(&ring);
 /* Never overwrite a packet that the application hasn't released. */
 setup(48000,1,32,1,4);wvr_capture_push(&ring,samples,8,48000,100);
 get();assert(frames==4&&flags==1);float preserved[4];memcpy(preserved,scratch,16);
 wvr_capture_push(&ring,samples+4,4,48000,200);
 assert(!wvr_capture_release(&ring,0));get();assert(flags==1&&!memcmp(preserved,scratch,16));
 assert(!wvr_capture_release(&ring,4));
 wvr_capture_push(&ring,samples+4,4,48000,300);get();assert(pos==12&&flags==1);
 assert(!wvr_capture_release(&ring,4));wvr_capture_reset(&ring);assert(!atomic_load(&ring.clock));
 wvr_capture_destroy(&ring);
 /* Real rate conversion and channel duplication, no invented silence packets. */
 setup(16000,2,32,1,1024);float input[480];
 for(unsigned i=0;i<480;++i) input[i]=(float)i/480;
 wvr_capture_push(&ring,input,480,48000,1000);assert(wvr_capture_available(&ring)==160);
 get();assert(frames==160);
 for(unsigned i=0;i<frames;++i) {float left,right;memcpy(&left,scratch+i*8,4);memcpy(&right,scratch+i*8+4,4);assert(left==right&&fabsf(left-input[i*3])<1e-6);}
 assert(!wvr_capture_release(&ring,frames));wvr_capture_destroy(&ring);
 setup(44100,1,32,1,1024);
 wvr_capture_push(&ring,input,240,48000,1000);
 wvr_capture_push(&ring,input+240,240,48000,51000);
 assert(wvr_capture_available(&ring)==441);wvr_capture_destroy(&ring);
 /* Concurrent producer/consumer keeps sequence, packets and positions intact. */
 setup(48000,1,32,1,64);pthread_t thread;assert(!pthread_create(&thread,0,producer,0));
 unsigned total=0;
 while(total<10000) {
  int status=wvr_capture_get(&ring,scratch,&frames,&flags,&pos,&qpc);
  if(!status) {sched_yield();continue;}
  assert(status==1&&pos==total&&!flags);
  for(unsigned i=0;i<frames;++i) {float value;memcpy(&value,scratch+i*4,4);assert(fabsf(value-(float)((total+i)%101)/101)<1e-6);}
  total+=frames;assert(!wvr_capture_release(&ring,frames));
 }
 assert(!pthread_join(thread,0));wvr_capture_destroy(&ring);
 puts("PASS: production microphone ring formats, PCM, resampling, timestamps, packet ownership, overflow, reset and concurrent capture");
}
'''
    (work/"test.c").write_text(code)
    subprocess.run(["xcrun","clang","-std=c11","-O1","-g","-fsanitize=address,undefined",
                    "-I",str(source.parent),str(work/"test.c"),"-o",str(work/"test")],check=True)
    subprocess.run([str(work/"test")],check=True,timeout=30)
    text=source.read_text()
    start=text.index("static OSStatus ios_capture_configure_locked(")
    end=text.index("\nstatic int ios_capture_any_started",start)
    control=text[start:end]
    harness=r'''
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>
typedef int OSStatus;typedef unsigned UInt32;
enum {noErr=0,kAudioUnitErr_Uninitialized=-10,kAudioOutputUnitProperty_EnableIO=1,
 kAudioUnitScope_Input=2,kAudioUnitScope_Output=3,kAudioUnitScope_Global=4,
 kAudioFormatLinearPCM=5,kAudioFormatFlagIsFloat=1,kAudioFormatFlagIsPacked=2,
 kAudioUnitProperty_StreamFormat=6,kAudioUnitProperty_ShouldAllocateBuffer=7,
 kAudioOutputUnitProperty_SetInputCallback=8,kAudioUnitProperty_MaximumFramesPerSlice=9};
typedef struct {double mSampleRate;unsigned mFormatID,mFormatFlags,mBytesPerPacket,mBytesPerFrame,
 mFramesPerPacket,mChannelsPerFrame,mBitsPerChannel;} AudioStreamBasicDescription;
typedef struct {int(*fn)(void);void*ref;} AURenderCallbackStruct;
#define IOS_MAX_STREAMS 2
struct ios_stream {int started;};
static struct {void*au;int running,input_enabled;unsigned rate;} g_dev;
static _Atomic(struct ios_stream*)g_capture[IOS_MAX_STREAMS];
static int hardware_running,input_enabled,property_failure,start_failure;
static int ios_audio_capture_cb(void){return 0;}
static OSStatus AudioOutputUnitStop(void*au){assert(au);hardware_running=0;return 0;}
static OSStatus AudioUnitUninitialize(void*au){assert(au&&!hardware_running);return 0;}
static OSStatus AudioUnitInitialize(void*au){assert(au&&!hardware_running);return 0;}
static OSStatus AudioOutputUnitStart(void*au){assert(au);if(start_failure){start_failure=0;return -88;}hardware_running=1;return 0;}
static OSStatus AudioUnitSetProperty(void*au,unsigned prop,unsigned scope,unsigned bus,const void*data,unsigned bytes){
 (void)scope;(void)bus;(void)bytes;assert(au&&!hardware_running);
 if(prop==kAudioOutputUnitProperty_EnableIO){if(property_failure){property_failure=0;return -77;}input_enabled=*(const UInt32*)data;}
 return 0;
}
''' + control + r'''
static void reset(int input) {memset(&g_dev,0,sizeof(g_dev));g_dev.au=(void*)1;
 g_dev.running=hardware_running=1;g_dev.input_enabled=input_enabled=input;g_dev.rate=48000;
 property_failure=start_failure=0;for(unsigned i=0;i<IOS_MAX_STREAMS;++i)atomic_store(&g_capture[i],0);}
int main(void){
 reset(0);assert(!ios_capture_configure_locked(1,0));assert(g_dev.running&&hardware_running&&input_enabled);
 assert(!ios_capture_configure_locked(0,0));assert(g_dev.running&&hardware_running&&!input_enabled);
 reset(0);property_failure=1;assert(ios_capture_configure_locked(1,0)==-77);
 assert(g_dev.running&&hardware_running&&!input_enabled);
 reset(1);property_failure=1;assert(ios_capture_configure_locked(0,0)==-77);
 assert(!g_dev.running&&!hardware_running); /* failed stop must not resume capture */
 reset(0);start_failure=1;assert(ios_capture_configure_locked(1,0)==-88);
 assert(g_dev.running&&hardware_running&&!input_enabled&&!g_dev.input_enabled);
 reset(1);struct ios_stream retired={0},active={1};atomic_store(&g_capture[0],&retired);atomic_store(&g_capture[1],&active);
 assert(!ios_capture_configure_locked(1,&retired));assert(!atomic_load(&g_capture[0])&&atomic_load(&g_capture[1])==&active);
 assert(g_dev.running&&hardware_running&&input_enabled);
 puts("PASS: production microphone control preserves playback, propagates failures, quiesces retirement and never restarts input after failed disable");
}
'''
    (work/"control.c").write_text(harness)
    subprocess.run(["xcrun","clang","-std=c11","-O1","-g","-fsanitize=address,undefined",
                    str(work/"control.c"),"-o",str(work/"control")],check=True)
    subprocess.run([str(work/"control")],check=True,timeout=30)
