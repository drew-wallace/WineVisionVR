#include "WindowsVRVideoDecoder.h"
#include "WindowsVRH264AnnexB.hpp"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {
struct Frame {
    CVPixelBufferRef image = nullptr;
    int64_t pts = 0;
    Frame(CVPixelBufferRef value, int64_t time): image(CVPixelBufferRetain(value)),pts(time) {}
    ~Frame() { if (image) CVPixelBufferRelease(image); }
    Frame(const Frame&) = delete;
};
struct Decoder {
    std::mutex operations, output;
    bool closed = false;
    uint32_t requestedWidth = 0, requestedHeight = 0;
    CMVideoFormatDescriptionRef format = nullptr;
    VTDecompressionSessionRef session = nullptr;
    std::vector<uint8_t> sps, pps, activeSPS, activePPS;
    std::deque<std::shared_ptr<Frame>> frames;
    uint64_t decoded = 0, read = 0;
    OSStatus callbackError = noErr;
    void resetSession() {
        if (session) {
            VTDecompressionSessionWaitForAsynchronousFrames(session);
            VTDecompressionSessionInvalidate(session); CFRelease(session); session = nullptr;
        }
        if (format) { CFRelease(format); format = nullptr; }
        activeSPS.clear(); activePPS.clear();
    }
    ~Decoder() { resetSession(); }
};
std::mutex registryMutex;
std::unordered_map<uint64_t,std::shared_ptr<Decoder>> registry;
uint64_t nextStream = 1;

bool valid(WVRVideoCall* call) { return call && call->version == WVR_VIDEO_ABI && call->size == sizeof(*call); }
std::shared_ptr<Decoder> find(uint64_t id) {
    std::lock_guard lock(registryMutex); auto it = registry.find(id);
    return it == registry.end() ? nullptr : it->second;
}
void output(void* ref, void*, OSStatus status, VTDecodeInfoFlags flags,
            CVImageBufferRef image, CMTime pts, CMTime) {
    auto& decoder = *static_cast<Decoder*>(ref);
    std::lock_guard lock(decoder.output);
    if (status) { decoder.callbackError = status; return; }
    if (!image || flags & kVTDecodeInfo_FrameDropped) return;
    auto width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
    if (!width || !height || width > WVR_VIDEO_MAX_DIMENSION || height > WVR_VIDEO_MAX_DIMENSION ||
        CVPixelBufferGetPlaneCount(image) != 2) { decoder.callbackError = kVTVideoDecoderBadDataErr; return; }
    // At most six completed pictures. Backpressure is applied before decode,
    // and the callback can retire only older, already decoded pictures.
    if (decoder.frames.size() == 6) decoder.frames.pop_front();
    int64_t time = CMTIME_IS_VALID(pts) ? CMTimeConvertScale(pts,10000000,kCMTimeRoundingMethod_Default).value : 0;
    decoder.frames.push_back(std::make_shared<Frame>(image,time)); ++decoder.decoded;
}
int initialize(Decoder& decoder) {
    if (decoder.sps.empty() || decoder.pps.empty()) return WVR_VIDEO_NO_FRAME;
    if (decoder.session && decoder.sps == decoder.activeSPS && decoder.pps == decoder.activePPS) return WVR_VIDEO_OK;
    decoder.resetSession();
    const uint8_t* sets[]{decoder.sps.data(),decoder.pps.data()};
    size_t sizes[]{decoder.sps.size(),decoder.pps.size()};
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,sets,sizes,4,&decoder.format);
    if (status) return WVR_VIDEO_CODEC_ERROR;
    auto dimensions = CMVideoFormatDescriptionGetDimensions(decoder.format);
    if (dimensions.width <= 0 || dimensions.height <= 0 || dimensions.width > WVR_VIDEO_MAX_DIMENSION ||
        dimensions.height > WVR_VIDEO_MAX_DIMENSION || dimensions.width % 2 || dimensions.height % 2) {
        decoder.resetSession(); return WVR_VIDEO_UNSUPPORTED;
    }
    int32_t pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef number = CFNumberCreate(nullptr,kCFNumberSInt32Type,&pixelFormat);
    const void* keys[]{kCVPixelBufferPixelFormatTypeKey,kCVPixelBufferIOSurfacePropertiesKey};
    CFDictionaryRef empty = CFDictionaryCreate(nullptr,nullptr,nullptr,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    const void* values[]{number,empty};
    CFDictionaryRef attrs = CFDictionaryCreate(nullptr,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    VTDecompressionOutputCallbackRecord callback{output,&decoder};
    status = VTDecompressionSessionCreate(nullptr,decoder.format,nullptr,attrs,&callback,&decoder.session);
    CFRelease(attrs); CFRelease(empty); CFRelease(number);
    if (status) { decoder.resetSession(); return WVR_VIDEO_CODEC_ERROR; }
    decoder.activeSPS = decoder.sps; decoder.activePPS = decoder.pps;
    fprintf(stderr,"[wvr-video] H.264 session %dx%d initialized\n",dimensions.width,dimensions.height);
    return WVR_VIDEO_OK;
}
uint32_t openCall(void* ptr) {
    auto* call = static_cast<WVRVideoCall*>(ptr); if (!valid(call)) return 0xc000000d;
    call->stream = 0; call->result = WVR_VIDEO_INVALID;
    if (!call->width || !call->height || call->width > WVR_VIDEO_MAX_DIMENSION || call->height > WVR_VIDEO_MAX_DIMENSION ||
        call->width % 2 || call->height % 2) return 0;
    auto decoder = std::make_shared<Decoder>(); decoder->requestedWidth = call->width; decoder->requestedHeight = call->height;
    std::lock_guard lock(registryMutex);
    if (registry.size() >= 16 || !nextStream) { call->result = WVR_VIDEO_UNSUPPORTED; return 0; }
    call->stream = nextStream++; registry.emplace(call->stream,decoder); call->result = WVR_VIDEO_OK; return 0;
}
uint32_t submitCall(void* ptr) {
    auto* call = static_cast<WVRVideoCall*>(ptr); if (!valid(call)) return 0xc000000d;
    call->result = WVR_VIDEO_INVALID;
    if (!call->input || call->inputSize > WVR_VIDEO_MAX_PACKET) return 0;
    auto decoder = find(call->stream); if (!decoder) { call->result = WVR_VIDEO_CLOSED; return 0; }
    std::lock_guard operation(decoder->operations);
    if (decoder->closed) { call->result = WVR_VIDEO_CLOSED; return 0; }
    {
        std::lock_guard lock(decoder->output);
        if (decoder->frames.size() >= 6) { call->result = WVR_VIDEO_QUEUE_FULL; return 0; }
    }
    std::vector<wvr::video::NAL> nals;
    if (!wvr::video::splitAnnexB(reinterpret_cast<const uint8_t*>(call->input),call->inputSize,nals)) return 0;
    std::vector<uint8_t> packet; bool vcl = false, idr = false;
    for (auto nal: nals) {
        if (nal.type == 7 || nal.type == 8) {
            if (nal.size > 65535) return 0;
            auto& parameter = nal.type == 7 ? decoder->sps : decoder->pps;
            parameter.assign(nal.data,nal.data+nal.size);
        } else {
            wvr::video::appendLengthPrefixed(packet,nal);
            if (nal.type >= 1 && nal.type <= 5) vcl = true;
            if (nal.type == 5) idr = true;
        }
    }
    if (!vcl) { call->result = WVR_VIDEO_OK; return 0; }
    call->result = initialize(*decoder); if (call->result != WVR_VIDEO_OK) return 0;
    CMBlockBufferRef block = nullptr; CMSampleBufferRef sample = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(nullptr,nullptr,packet.size(),nullptr,nullptr,0,packet.size(),0,&block);
    if (!status) status = CMBlockBufferReplaceDataBytes(packet.data(),block,0,packet.size());
    CMSampleTimingInfo timing{kCMTimeInvalid,CMTimeMake(call->pts,10000000),kCMTimeInvalid}; size_t bytes = packet.size();
    if (!status) status = CMSampleBufferCreateReady(nullptr,block,decoder->format,1,1,&timing,1,&bytes,&sample);
    if (!status) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample,true);
        if (attachments && CFArrayGetCount(attachments)) CFDictionarySetValue(
            static_cast<CFMutableDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(attachments,0))),
            kCMSampleAttachmentKey_NotSync,idr ? kCFBooleanFalse : kCFBooleanTrue);
        { std::lock_guard lock(decoder->output); decoder->callbackError = noErr; }
        status = VTDecompressionSessionDecodeFrame(decoder->session,sample,0,nullptr,nullptr);
        if (!status) status = VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);
        { std::lock_guard lock(decoder->output); if (!status) status = decoder->callbackError; }
    }
    if (sample) CFRelease(sample); if (block) CFRelease(block);
    call->result = status ? WVR_VIDEO_CODEC_ERROR : WVR_VIDEO_OK;
    { std::lock_guard lock(decoder->output); call->framesDecoded = decoder->decoded; call->framesRead = decoder->read; }
    if (status) fprintf(stderr,"[wvr-video] decode failed OSStatus=%d\n",int(status));
    return 0;
}
uint32_t readCall(void* ptr) {
    auto* call = static_cast<WVRVideoCall*>(ptr); if (!valid(call)) return 0xc000000d;
    auto decoder = find(call->stream); if (!decoder) { call->result = WVR_VIDEO_CLOSED; return 0; }
    std::lock_guard operation(decoder->operations);
    if (decoder->closed) { call->result = WVR_VIDEO_CLOSED; return 0; }
    std::lock_guard lock(decoder->output); call->framesDecoded = decoder->decoded; call->framesRead = decoder->read;
    if (decoder->frames.empty()) { call->result = WVR_VIDEO_NO_FRAME; return 0; }
    auto frame = decoder->frames.front(); auto image = frame->image;
    call->width = uint32_t(CVPixelBufferGetWidth(image)); call->height = uint32_t(CVPixelBufferGetHeight(image)); call->pts = frame->pts;
    auto format = CVPixelBufferGetPixelFormatType(image);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        decoder->frames.pop_front(); call->result = WVR_VIDEO_UNSUPPORTED; return 0;
    }
    call->fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!call->y || !call->uv || call->yPitch < call->width || call->uvPitch < call->width ||
        call->yCapacity < uint64_t(call->yPitch)*call->height || call->uvCapacity < uint64_t(call->uvPitch)*((call->height+1)/2)) {
        call->result = WVR_VIDEO_BUFFER_TOO_SMALL; return 0;
    }
    if (CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly)) { call->result = WVR_VIDEO_CODEC_ERROR; return 0; }
    for (size_t plane = 0; plane != 2; ++plane) {
        auto* source = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(image,plane));
        auto* dest = reinterpret_cast<uint8_t*>(plane ? call->uv : call->y);
        size_t pitch = CVPixelBufferGetBytesPerRowOfPlane(image,plane), targetPitch = plane ? call->uvPitch : call->yPitch;
        size_t rows = plane ? (call->height+1)/2 : call->height;
        if (!source || pitch < call->width) { CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly); call->result = WVR_VIDEO_CODEC_ERROR; return 0; }
        for (size_t row = 0; row < rows; ++row) memcpy(dest+row*targetPitch,source+row*pitch,call->width);
    }
    CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
    decoder->frames.pop_front(); call->framesRead = ++decoder->read; call->result = WVR_VIDEO_OK; return 0;
}
uint32_t flushCall(void* ptr) {
    auto* call = static_cast<WVRVideoCall*>(ptr); if (!valid(call)) return 0xc000000d;
    auto decoder = find(call->stream); if (!decoder) { call->result = WVR_VIDEO_CLOSED; return 0; }
    std::lock_guard operation(decoder->operations);
    if (decoder->closed) { call->result = WVR_VIDEO_CLOSED; return 0; }
    decoder->resetSession();
    { std::lock_guard lock(decoder->output); decoder->frames.clear(); decoder->callbackError = noErr; }
    call->result = WVR_VIDEO_OK; return 0;
}
uint32_t closeCall(void* ptr) {
    auto* call = static_cast<WVRVideoCall*>(ptr); if (!valid(call)) return 0xc000000d;
    std::shared_ptr<Decoder> decoder;
    { std::lock_guard lock(registryMutex); auto it = registry.find(call->stream);
      if (it == registry.end()) { call->result = WVR_VIDEO_CLOSED; return 0; }
      decoder = it->second; registry.erase(it); }
    std::lock_guard operation(decoder->operations); decoder->closed = true; decoder->resetSession();
    { std::lock_guard lock(decoder->output); decoder->frames.clear(); }
    call->result = WVR_VIDEO_OK; return 0;
}
const void* const table[]{reinterpret_cast<void*>(openCall),reinterpret_cast<void*>(submitCall),reinterpret_cast<void*>(readCall),
                         reinterpret_cast<void*>(flushCall),reinterpret_cast<void*>(closeCall)};
}
extern "C" __attribute__((visibility("default"))) const void* const* wvr_video_unix_call_table_v1(uint32_t version, uint32_t count) {
    return version == WVR_VIDEO_ABI && count == WVR_VIDEO_CALL_COUNT ? table : nullptr;
}
extern "C" __attribute__((visibility("default"))) void wvr_video_reset_all_v1() {
    decltype(registry) retiring;
    { std::lock_guard lock(registryMutex); retiring.swap(registry); }
    for (auto& entry: retiring) {
        auto& decoder = *entry.second;
        std::lock_guard operation(decoder.operations);
        decoder.closed = true; decoder.resetSession();
        std::lock_guard lock(decoder.output); decoder.frames.clear();
    }
}
