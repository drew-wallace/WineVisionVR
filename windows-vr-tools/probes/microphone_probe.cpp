#define INITGUID
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>

static FILE* report;
static void check(bool ok,const char* label) {
  fprintf(report,"%s %s\n",ok?"PASS":"FAIL",label);fflush(report);
  if(!ok) {fprintf(report,"RESULT FAIL\n");fclose(report);ExitProcess(1);}
}
static void hr(HRESULT value,const char* label) {
  if(FAILED(value)) fprintf(report,"HRESULT %s 0x%08lx\n",label,(unsigned long)value);
  check(SUCCEEDED(value),label);
}
int main() {
  report=fopen("mapping-result.txt","w");if(!report)return 2;
  const char* token=getenv("WINEVISION_PROBE_RUN_ID");
  fprintf(report,"START microphone run=%s\n",token?token:"missing");fflush(report);
  hr(CoInitializeEx(nullptr,COINIT_MULTITHREADED),"COM initialization");
  IMMDeviceEnumerator* enumerator=nullptr;
  hr(CoCreateInstance(__uuidof(MMDeviceEnumerator),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&enumerator)),"device enumerator");
  IMMDeviceCollection* devices=nullptr;UINT count=0;
  hr(enumerator->EnumAudioEndpoints(eCapture,DEVICE_STATE_ACTIVE,&devices),"enumerate capture devices");
  hr(devices->GetCount(&count),"capture device count");check(count>0,"microphone endpoint is visible");devices->Release();
  IMMDevice *input=nullptr,*output=nullptr;
  hr(enumerator->GetDefaultAudioEndpoint(eCapture,eCommunications,&input),"default communications microphone");
  hr(enumerator->GetDefaultAudioEndpoint(eRender,eConsole,&output),"default playback device");
  IAudioClient *captureClient=nullptr,*renderClient=nullptr;
  hr(input->Activate(__uuidof(IAudioClient),CLSCTX_INPROC_SERVER,nullptr,(void**)&captureClient),"activate capture client");
  hr(output->Activate(__uuidof(IAudioClient),CLSCTX_INPROC_SERVER,nullptr,(void**)&renderClient),"activate playback client");
  WAVEFORMATEX *captureFormat=nullptr,*renderFormat=nullptr;
  hr(captureClient->GetMixFormat(&captureFormat),"capture mix format");
  hr(renderClient->GetMixFormat(&renderFormat),"playback mix format");
  fprintf(report,"FORMAT capture rate=%lu channels=%u bits=%u tag=%u\n",(unsigned long)captureFormat->nSamplesPerSec,captureFormat->nChannels,captureFormat->wBitsPerSample,captureFormat->wFormatTag);
  check(captureFormat->nSamplesPerSec==48000&&captureFormat->nChannels==1&&captureFormat->wBitsPerSample==32,"mono 48kHz float microphone format");
  WAVEFORMATEX* closest=nullptr;
  hr(captureClient->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,captureFormat,&closest),"capture format supported");
  CoTaskMemFree(closest);
  hr(captureClient->Initialize(AUDCLNT_SHAREMODE_SHARED,AUDCLNT_STREAMFLAGS_EVENTCALLBACK,1000000,0,captureFormat,nullptr),"initialize event capture");
  hr(renderClient->Initialize(AUDCLNT_SHAREMODE_SHARED,0,1000000,0,renderFormat,nullptr),"initialize concurrent playback");
  HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);check(event!=nullptr,"capture event");
  hr(captureClient->SetEventHandle(event),"set capture event");
  IAudioCaptureClient* capture=nullptr;IAudioRenderClient* render=nullptr;IAudioClock* outputClock=nullptr;
  hr(captureClient->GetService(IID_PPV_ARGS(&capture)),"capture buffer service");
  hr(renderClient->GetService(IID_PPV_ARGS(&render)),"playback buffer service");
  hr(renderClient->GetService(IID_PPV_ARGS(&outputClock)),"playback clock service");
  UINT32 outputCapacity=0;hr(renderClient->GetBufferSize(&outputCapacity),"playback capacity");
  auto feedOutput=[&]() {
    UINT32 padding=0;hr(renderClient->GetCurrentPadding(&padding),"playback padding");
    if(padding<outputCapacity) {
      BYTE* bytes=nullptr;UINT32 frames=outputCapacity-padding;
      hr(render->GetBuffer(frames,&bytes),"playback buffer");
      hr(render->ReleaseBuffer(frames,AUDCLNT_BUFFERFLAGS_SILENT),"queue playback silence");
    }
  };
  feedOutput();hr(renderClient->Start(),"start playback");
  UINT64 total=0,lastPosition=0,lastQpc=0;double peak=0,sumSquares=0;UINT64 samples=0;
  for(unsigned cycle=0;cycle<3;++cycle) {
    hr(captureClient->Start(),"start microphone");
    ULONGLONG deadline=GetTickCount64()+1200;
    while(GetTickCount64()<deadline) {
      feedOutput();DWORD wait=WaitForSingleObject(event,100);
      check(wait==WAIT_OBJECT_0||wait==WAIT_TIMEOUT,"capture event wait");
      UINT32 packet=0;hr(capture->GetNextPacketSize(&packet),"next capture packet");
      while(packet) {
        BYTE* bytes=nullptr;UINT32 frames=0;DWORD flags=0;UINT64 position=0,qpc=0;
        hr(capture->GetBuffer(&bytes,&frames,&flags,&position,&qpc),"read microphone packet");
        check(bytes&&frames&&position>=lastPosition&&qpc>=lastQpc,"real capture buffer and monotonic positions");
        bool finite=true;
        for(UINT32 i=0;i<frames;++i) {
          float value;memcpy(&value,bytes+i*sizeof(float),sizeof(float));
          if(!std::isfinite(value)) finite=false;
          double amplitude=std::fabs(value);if(amplitude>peak)peak=amplitude;sumSquares+=value*value;++samples;
        }
        check(finite,"finite captured samples");
        total+=frames;lastPosition=position;lastQpc=qpc;
        hr(capture->ReleaseBuffer(frames),"release microphone packet");
        hr(capture->GetNextPacketSize(&packet),"drain capture packets");
      }
    }
    hr(captureClient->Stop(),"stop microphone");
    UINT64 before=0,after=0,qpc=0;
    hr(outputClock->GetPosition(&before,&qpc),"playback position after microphone stop");
    for(unsigned i=0;i<5;++i) {feedOutput();Sleep(20);}
    hr(outputClock->GetPosition(&after,&qpc),"playback position with microphone stopped");
    check(after>before,"playback survives microphone stop");
    hr(captureClient->Reset(),"reset stopped capture stream");lastPosition=lastQpc=0;
  }
  fprintf(report,"CAPTURE frames=%llu peak=%.8f rms=%.8f cycles=3\n",(unsigned long long)total,peak,samples?std::sqrt(sumSquares/samples):0);
  check(total>48000,"sustained captured audio");
  check(peak>0.000001,"nonzero physical microphone samples");
  hr(renderClient->Stop(),"stop playback");
  capture->Release();captureClient->Release();
  outputClock->Release();render->Release();renderClient->Release();
  CloseHandle(event);input->Release();output->Release();enumerator->Release();
  CoTaskMemFree(captureFormat);CoTaskMemFree(renderFormat);CoUninitialize();
  fprintf(report,"RESULT PASS\n");fclose(report);return 0;
}
