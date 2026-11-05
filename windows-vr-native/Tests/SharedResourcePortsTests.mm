#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../Sources/WindowsVRSharedResourcePorts.mm"
#include <cassert>
#include <thread>
#include <vector>

@interface MTLSharedTextureHandle (WVRPortTest)
- (mach_port_t)createMachPort;
- (instancetype)initWithMachPort:(mach_port_t)port;
@end

static mach_port_t makePort(bool send = true) {
    mach_port_t port = MACH_PORT_NULL;
    assert(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS);
    if (send) assert(mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    return port;
}
static unsigned refs(mach_port_t port, mach_port_right_t right = MACH_PORT_RIGHT_SEND) {
    mach_port_urefs_t value = 0;
    assert(mach_port_get_refs(mach_task_self(), port, right, &value) == KERN_SUCCESS);
    return value;
}
static PortRequest request(const char* name, mach_port_t port = MACH_PORT_NULL) {
    PortRequest value{};
    std::snprintf(value.name, sizeof(value.name), "%s", name);
    value.port = port;
    return value;
}
static int32_t oldHandler(void*) { return int32_t(0xc00000bbu); }

static void testDispatch() {
    void* table[149];
    for (auto& entry : table) entry = reinterpret_cast<void*>(oldHandler);
    assert(!installTable(nullptr,149,1));
    assert(!installTable(table,148,1) && !installTable(table,149,2));
    table[122] = nullptr;
    assert(!installTable(table,149,1));
    table[122] = reinterpret_cast<void*>(oldHandler);
    vm_address_t readOnly = 0;
    assert(vm_allocate(mach_task_self(), &readOnly, vm_page_size, VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    auto* protectedTable = reinterpret_cast<void**>(readOnly);
    std::memcpy(protectedTable, table, sizeof(table));
    assert(vm_protect(mach_task_self(), readOnly, vm_page_size, false, VM_PROT_READ) == KERN_SUCCESS);
    assert(!installTable(protectedTable,149,1));
    assert(protectedTable[121] == reinterpret_cast<void*>(oldHandler));
    vm_deallocate(mach_task_self(), readOnly, vm_page_size);
    assert(installTable(table,149,1));
    for (size_t i=0;i<149;++i) {
        const void* expected = i==121 ? reinterpret_cast<void*>(registerPort) :
            i==122 ? reinterpret_cast<void*>(lookupPort) : reinterpret_cast<void*>(oldHandler);
        assert(table[i]==expected);
    }
    // Execute through the installed ABI, including null and malformed records.
    using Handler = int32_t(*)(void*);
    assert(reinterpret_cast<Handler>(table[121])(nullptr)==invalidParameter);
    PortRequest missing=request("missing",123);
    assert(reinterpret_cast<Handler>(table[122])(&missing)==notFound && missing.port==0);
    PortRequest invalid{}; std::memset(invalid.name,'x',128); invalid.port=1;
    assert(registerPort(&invalid)==invalidParameter);
    assert(lookupPort(&invalid)==invalidParameter && invalid.port==0);
}

static void testRights() {
    auto port=makePort(), other=makePort(), receiveOnly=makePort(false);
    auto value=request("texture",port);
    assert(refs(port)==1 && registerPort(&value)==success && refs(port)==2);
    assert(registerPort(&value)==success && refs(port)==2);
    auto duplicate=request("texture",other);
    assert(registerPort(&duplicate)==collision && refs(other)==1);
    auto invalid=request("receive-only",receiveOnly);
    assert(registerPort(&invalid)==invalidParameter);
    auto found=request("texture");
    assert(lookupPort(&found)==success && found.port==port && refs(port)==3);
    assert(mach_port_deallocate(mach_task_self(),found.port)==KERN_SUCCESS && refs(port)==2);
    std::vector<std::thread> threads;
    for(int t=0;t<8;++t) threads.emplace_back([] {
        for(int n=0;n<250;++n) {
            auto found=request("texture");
            assert(lookupPort(&found)==success);
            assert(mach_port_deallocate(mach_task_self(),found.port)==KERN_SUCCESS);
        }
    });
    for(auto& thread:threads) thread.join();
    assert(refs(port)==2);
    registry().clear();
    assert(refs(port)==1);
    for(size_t i=0;i<maximumNames;++i) {
        auto entry=request(std::to_string(i).c_str(),port);
        assert(registerPort(&entry)==success);
    }
    auto overflow=request("overflow",port);
    assert(registerPort(&overflow)==noResources && refs(port)==maximumNames+1);
    registry().clear();
    assert(refs(port)==1);
    // A dead receive endpoint must not be returned as a live send right.
    auto dead=request("dead",other);
    assert(registerPort(&dead)==success);
    assert(mach_port_mod_refs(mach_task_self(),other,MACH_PORT_RIGHT_RECEIVE,-1)==KERN_SUCCESS);
    assert(registerPort(&dead)==invalidParameter);
    assert(lookupPort(&dead)==notFound && dead.port==0);
    assert(refs(other,MACH_PORT_RIGHT_DEAD_NAME)==1);
    mach_port_deallocate(mach_task_self(),other);
    mach_port_mod_refs(mach_task_self(),port,MACH_PORT_RIGHT_SEND,-1);
    mach_port_mod_refs(mach_task_self(),port,MACH_PORT_RIGHT_RECEIVE,-1);
    mach_port_mod_refs(mach_task_self(),receiveOnly,MACH_PORT_RIGHT_RECEIVE,-1);
    std::puts("PASS: dispatch ABI, malformed records, duplicates, collisions, bounded capacity, concurrent lookups, dead names and exact send-right cleanup");
}

static void testMetal() {
    mach_port_t texturePort=MACH_PORT_NULL;
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        assert(device);
        auto* descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;
        descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
        id<MTLTexture> original=[device newSharedTextureWithDescriptor:descriptor];
        assert(original);
        MTLSharedTextureHandle* handle=[original newSharedTextureHandle];
        texturePort=[handle createMachPort];
        assert(MACH_PORT_VALID(texturePort));
        auto entry=request("real-metal-texture",texturePort);
        assert(registerPort(&entry)==success);
        auto lookup=request("real-metal-texture");
        assert(lookupPort(&lookup)==success);
        MTLSharedTextureHandle* importedHandle=[[MTLSharedTextureHandle alloc] initWithMachPort:lookup.port];
        id<MTLTexture> imported=[device newSharedTextureWithHandle:importedHandle];
        assert(imported && imported.width==4 && imported.height==4);
        id<MTLBuffer> input=[device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        auto* bytes=static_cast<uint8_t*>(input.contents);
        for(int y=0;y<4;++y) for(int x=0;x<16;++x) bytes[y*256+x]=uint8_t(13+y*17+x);
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLCommandBuffer> write=[queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder=[write blitCommandEncoder];
        [encoder copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(4,4,1) toTexture:original destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [encoder endEncoding]; [write commit]; [write waitUntilCompleted];
        assert(write.status==MTLCommandBufferStatusCompleted);
        id<MTLCommandBuffer> read=[queue commandBuffer];
        encoder=[read blitCommandEncoder];
        [encoder copyFromTexture:imported sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [encoder endEncoding]; [read commit]; [read waitUntilCompleted];
        assert(read.status==MTLCommandBufferStatusCompleted);
        for(int y=0;y<4;++y) assert(std::memcmp(bytes+y*256,static_cast<uint8_t*>(output.contents)+y*256,16)==0);
    }
    registry().clear();
    // All temporary Metal handles have been destroyed. Release remaining test
    // send refs regardless of whether initWithMachPort consumed its argument.
    mach_port_urefs_t remaining=0;
    if(mach_port_get_refs(mach_task_self(),texturePort,MACH_PORT_RIGHT_SEND,&remaining)==KERN_SUCCESS && remaining)
        mach_port_mod_refs(mach_task_self(),texturePort,MACH_PORT_RIGHT_SEND,-int(remaining));
    std::puts("PASS: real Metal shared texture registered/imported through the production registry; GPU write/readback pixels match");
}

int main() {
    testDispatch(); testRights(); testMetal();
}
