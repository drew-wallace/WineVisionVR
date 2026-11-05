#include "WindowsVRVideoDecoder.h"
#include "../Sources/WindowsVRH264AnnexB.hpp"
#import <VideoToolbox/VideoToolbox.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
#include <algorithm>

using Packet = std::vector<uint8_t>;
static void encoded(void* ref, void*, OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
    assert(!status && sample);
    auto& packet = *static_cast<Packet*>(ref);
    auto format = CMSampleBufferGetFormatDescription(sample);
    const uint8_t* parameter = nullptr; size_t size = 0, count = 0; int lengthBytes = 0;
    assert(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,0,&parameter,&size,&count,&lengthBytes));
    for (size_t i=0;i<count;++i) {
        assert(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,i,&parameter,&size,nullptr,nullptr));
        packet.insert(packet.end(),{0,0,0,1}); packet.insert(packet.end(),parameter,parameter+size);
    }
    auto block = CMSampleBufferGetDataBuffer(sample); size_t total = CMBlockBufferGetDataLength(block);
    std::vector<uint8_t> bytes(total); assert(!CMBlockBufferCopyDataBytes(block,0,total,bytes.data()));
    assert(lengthBytes == 4);
    for (size_t pos=0;pos<total;) {
        assert(pos+4<=total); uint32_t n = uint32_t(bytes[pos])<<24 | uint32_t(bytes[pos+1])<<16 | uint32_t(bytes[pos+2])<<8 | bytes[pos+3]; pos+=4;
        assert(n && n<=total-pos); packet.insert(packet.end(),{0,0,0,1}); packet.insert(packet.end(),bytes.data()+pos,bytes.data()+pos+n); pos+=n;
    }
}
static Packet fixture(int width,int height) {
    Packet packet; VTCompressionSessionRef encoder = nullptr;
    assert(!VTCompressionSessionCreate(nullptr,width,height,kCMVideoCodecType_H264,nullptr,nullptr,nullptr,encoded,&packet,&encoder));
    assert(!VTSessionSetProperty(encoder,kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_Baseline_AutoLevel));
    assert(!VTSessionSetProperty(encoder,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue));
    assert(!VTSessionSetProperty(encoder,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse));
    int rate=1000000; CFNumberRef bitrate=CFNumberCreate(nullptr,kCFNumberIntType,&rate);
    assert(!VTSessionSetProperty(encoder,kVTCompressionPropertyKey_AverageBitRate,bitrate)); CFRelease(bitrate);
    CVPixelBufferRef image = nullptr;
    assert(!CVPixelBufferCreate(nullptr,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nullptr,&image));
    assert(!CVPixelBufferLockBaseAddress(image,0));
    auto* y = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image,0)); auto* uv = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image,1));
    for(int row=0;row<height;++row) memset(y+row*CVPixelBufferGetBytesPerRowOfPlane(image,0),82,CVPixelBufferGetBytesPerRowOfPlane(image,0));
    for(int row=0;row<height/2;++row) for(size_t col=0;col<CVPixelBufferGetBytesPerRowOfPlane(image,1);col+=2) {
        auto* pixel = uv+row*CVPixelBufferGetBytesPerRowOfPlane(image,1)+col; pixel[0]=90; pixel[1]=240;
    }
    CVPixelBufferUnlockBaseAddress(image,0);
    assert(!VTCompressionSessionEncodeFrame(encoder,image,CMTimeMake(0,30),CMTimeMake(1,30),nullptr,nullptr,nullptr));
    assert(!VTCompressionSessionCompleteFrames(encoder,kCMTimeInvalid));
    CVPixelBufferRelease(image); VTCompressionSessionInvalidate(encoder); CFRelease(encoder); assert(!packet.empty()); return packet;
}
static WVRVideoCall call(uint64_t stream=0) { WVRVideoCall p{};p.version=WVR_VIDEO_ABI;p.size=sizeof(p);p.stream=stream;return p; }
static void invoke(unsigned index,WVRVideoCall& p) {
    auto table=wvr_video_unix_call_table_v1(WVR_VIDEO_ABI,WVR_VIDEO_CALL_COUNT);assert(table);
    assert(!reinterpret_cast<uint32_t(*)(void*)>(const_cast<void*>(table[index]))(&p));
}
static uint64_t open() { auto p=call();p.width=32;p.height=32;invoke(WVR_VIDEO_OPEN,p);assert(p.result==WVR_VIDEO_OK && p.stream);return p.stream; }
static void submit(uint64_t stream,const Packet& packet,int64_t pts=123) {
    auto p=call(stream);p.input=reinterpret_cast<uint64_t>(packet.data());p.inputSize=packet.size();p.pts=pts;invoke(WVR_VIDEO_SUBMIT,p);assert(p.result==WVR_VIDEO_OK);
}
static void read(uint64_t stream,unsigned width,unsigned height,int64_t pts) {
    auto p=call(stream);invoke(WVR_VIDEO_READ,p);assert(p.result==WVR_VIDEO_BUFFER_TOO_SMALL && p.width==width && p.height==height);
    std::vector<uint8_t> y(width*height+32,0xa5),uv(width*height/2+32,0xa5);
    p.y=reinterpret_cast<uint64_t>(y.data());p.uv=reinterpret_cast<uint64_t>(uv.data());p.yPitch=p.uvPitch=width;p.yCapacity=width*height;p.uvCapacity=width*height/2;
    invoke(WVR_VIDEO_READ,p);assert(p.result==WVR_VIDEO_OK && p.pts==pts);
    auto range=std::minmax_element(y.begin(),y.begin()+width*height);
    fprintf(stderr,"decoded %ux%u range=%u..%u uv=%u,%u full=%u\n",width,height,*range.first,*range.second,uv[0],uv[1],p.fullRange);
    for(size_t i=0;i<width*height;++i) assert(y[i]>=74 && y[i]<=90);
    for(size_t i=0;i<width*height/2;i+=2) assert(uv[i]>=82 && uv[i]<=98 && uv[i+1]>=232 && uv[i+1]<=248);
    for(size_t i=width*height;i<y.size();++i) assert(y[i]==0xa5);
    for(size_t i=width*height/2;i<uv.size();++i) assert(uv[i]==0xa5);
}
int main(int argc,char** argv) {
    assert(!wvr_video_unix_call_table_v1(2,WVR_VIDEO_CALL_COUNT));
    assert(!wvr_video_unix_call_table_v1(1,WVR_VIDEO_CALL_COUNT+1));
    std::vector<wvr::video::NAL> nals;
    const uint8_t malformed[]{0,0,0,1,0x80}; assert(!wvr::video::splitAnnexB(malformed,sizeof(malformed),nals));
    const uint8_t empty[]{0,0,0,1,0,0,1}; assert(!wvr::video::splitAnnexB(empty,sizeof(empty),nals));
    const uint8_t mixed[]{0,0,1,0x67,0x42,0,0,0,1,0x68,0xaa};
    assert(wvr::video::splitAnnexB(mixed,sizeof(mixed),nals) && nals.size()==2 && nals[0].type==7 && nals[1].type==8);
    auto p=call();p.width=4098;p.height=32;invoke(WVR_VIDEO_OPEN,p);assert(p.result==WVR_VIDEO_INVALID && !p.stream);
    Packet red=fixture(32,32),wide=fixture(64,32);
    if(argc>1) { FILE* f=fopen(argv[1],"wb");assert(f);assert(fwrite(red.data(),1,red.size(),f)==red.size());fclose(f); }
    uint64_t stream=open();
    // Match BigSoup: separate SPS, PPS, and picture packets.
    assert(wvr::video::splitAnnexB(red.data(),red.size(),nals));
    for(auto nal:nals) { Packet one{0,0,0,1};one.insert(one.end(),nal.data,nal.data+nal.size);submit(stream,one); }
    read(stream,32,32,123);
    p=call(stream);invoke(WVR_VIDEO_READ,p);assert(p.result==WVR_VIDEO_NO_FRAME);
    submit(stream,wide,456);read(stream,64,32,456);
    p=call(stream);invoke(WVR_VIDEO_FLUSH,p);assert(p.result==WVR_VIDEO_OK);
    for(int i=0;i<6;++i) submit(stream,red,1000+i);
    p=call(stream);p.input=reinterpret_cast<uint64_t>(red.data());p.inputSize=red.size();invoke(WVR_VIDEO_SUBMIT,p);assert(p.result==WVR_VIDEO_QUEUE_FULL);
    for(int i=0;i<6;++i) read(stream,32,32,1000+i);
    p=call(stream);invoke(WVR_VIDEO_CLOSE,p);assert(p.result==WVR_VIDEO_OK);
    invoke(WVR_VIDEO_CLOSE,p);assert(p.result==WVR_VIDEO_CLOSED);
    invoke(WVR_VIDEO_READ,p);assert(p.result==WVR_VIDEO_CLOSED);
    uint64_t next=open();assert(next!=stream);submit(next,red);
    wvr_video_reset_all_v1();p=call(next);invoke(WVR_VIDEO_READ,p);assert(p.result==WVR_VIDEO_CLOSED);
    uint64_t fresh=open();assert(fresh!=next);p=call(fresh);invoke(WVR_VIDEO_CLOSE,p);assert(p.result==WVR_VIDEO_OK);
    puts("VIDEO DECODER CHECKS PASSED: real H.264 pixels, separate parameter packets, resolution changes, queue pressure, flush and close");
}
