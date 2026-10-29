#pragma once
// Experimental Metal 4 tensor convolution. M2 never compiles this library.
// Existing OIHW FP16 weights are consumed directly; im2col preserves NHWC input.
#import <Metal/Metal.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <memory>

static NSString *const kWVRM5TensorSource = @R"metal(
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp::tensor_ops;
struct TensorConvParams {
    uint2 inSize, outSize;
    uint inCh, outCh, stride, inputRelu, applyRelu, addResidual, weightOffset, biasOffset;
};
kernel void tensor_conv_gather(device const half *input [[buffer(0)]],
                               device half *columns [[buffer(5)]],
                               constant TensorConvParams &p [[buffer(4)]],
                               uint2 pos [[thread_position_in_grid]]) {
    uint k = p.inCh * 9, pixels = p.outSize.x * p.outSize.y;
    if (pos.x >= k || pos.y >= pixels) return;
    uint ic = pos.x / 9, tap = pos.x % 9;
    int x = int(pos.y % p.outSize.x * p.stride) - 1 + int(tap % 3);
    int y = int(pos.y / p.outSize.x * p.stride) - 1 + int(tap / 3);
    half v = half(0);
    if (x >= 0 && y >= 0 && x < int(p.inSize.x) && y < int(p.inSize.y))
        v = input[(uint(y) * p.inSize.x + uint(x)) * p.inCh + ic];
    if (p.inputRelu) v = max(v, half(0));
    columns[pos.y * k + pos.x] = v;
}
kernel void tensor_conv_matmul(device half *weights [[buffer(2)]],
                               device half *columns [[buffer(5)]],
                               device float *sums [[buffer(6)]],
                               constant TensorConvParams &p [[buffer(4)]],
                               uint2 group [[threadgroup_position_in_grid]]) {
    using E = dextents<int, 2>;
    int k = int(p.inCh * 9), pixels = int(p.outSize.x * p.outSize.y);
    tensor<device half, E, tensor_inline> a(columns, E(k, pixels));
    tensor<device half, E, tensor_inline> b(weights + p.weightOffset, E(k, int(p.outCh)));
    tensor<device float, E, tensor_inline> c(sums, E(int(p.outCh), pixels));
    constexpr auto desc = matmul2d_descriptor(16, 32, int(dynamic_extent), false, true, false);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto tileA = a.slice(0, int(group.y * 16));
    auto tileB = b.slice(0, int(group.x * 32));
    auto tileC = c.slice(int(group.x * 32), int(group.y * 16));
    op.run(tileA, tileB, tileC);
}
kernel void tensor_conv_finish(device const half *residual [[buffer(1)]],
                               device const half *weights [[buffer(2)]],
                               device half *output [[buffer(3)]],
                               device const float *sums [[buffer(6)]],
                               constant TensorConvParams &p [[buffer(4)]],
                               uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= p.outCh || pos.y >= p.outSize.x * p.outSize.y) return;
    uint i = pos.y * p.outCh + pos.x;
    float v = sums[i] + float(weights[p.biasOffset + pos.x]);
    if (p.addResidual) v += float(residual[i]);
    if (p.applyRelu) v = max(v, 0.0f);
    output[i] = half(v);
}
)metal";

struct WVRM5TensorConvolution {
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> gather = nil, multiply = nil, finish = nil;
    id<MTLBuffer> columns = nil, sums = nil;
    uint64_t jobs = 0, fallbacks = 0;
    std::shared_ptr<std::atomic<bool>> gpuFailed = std::make_shared<std::atomic<bool>>(false);
    // Explicit opt-in only. No device has passed the sustained-play acceptance gate.
    void initialize(id<MTLDevice> d) {
        const char *opt = getenv("WVR_NEURAL_M5_TENSOR");
        if (!opt || strcmp(opt, "1") != 0 || ![d supportsFamily:MTLGPUFamilyApple10]) return;
        device = d;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion4_0;
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        id<MTLLibrary> library = [d newLibraryWithSource:kWVRM5TensorSource options:options error:&error];
        if (library) {
            gather = [d newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_gather"] error:&error];
            multiply = [d newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_matmul"] error:&error];
            finish = [d newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_finish"] error:&error];
        }
        NSLog(@"[WindowsVRNeural] Experimental M5 tensor pipelines=%@ error=%@", ready() ? @"ready" : @"fallback", error);
    }
    bool ready() const {
        return gather && multiply && finish &&
            multiply.threadExecutionWidth * 4 <= multiply.maxTotalThreadsPerThreadgroup &&
            gather.maxTotalThreadsPerThreadgroup >= 128 && finish.maxTotalThreadsPerThreadgroup >= 128;
    }
    uint64_t scratchBytes() const { return columns.length + sums.length; }
    template<class Params>
    bool encode(id<MTLComputeCommandEncoder> enc, const Params &p) {
        if (!ready()) return false;
        if (gpuFailed->load(std::memory_order_relaxed)) { ++fallbacks; return false; }
        uint64_t pixels = uint64_t(p.outSize.x) * p.outSize.y;
        uint64_t columnBytes = pixels * p.inCh * 9 * sizeof(uint16_t);
        uint64_t sumBytes = pixels * p.outCh * sizeof(float);
        uint64_t required = std::max<uint64_t>(columns.length, columnBytes) + std::max<uint64_t>(sums.length, sumBytes);
        // Bound scratch independently from the app's shared memory budget.
        if (!pixels || required > 64 * 1024 * 1024 ||
            device.currentAllocatedSize + required > device.recommendedMaxWorkingSetSize) { ++fallbacks; return false; }
        if (columns.length < columnBytes) columns = [device newBufferWithLength:columnBytes options:MTLResourceStorageModePrivate];
        if (sums.length < sumBytes) sums = [device newBufferWithLength:sumBytes options:MTLResourceStorageModePrivate];
        if (!columns || !sums) { ++fallbacks; return false; }
        [enc setBuffer:columns offset:0 atIndex:5];
        [enc setBuffer:sums offset:0 atIndex:6];
        [enc setComputePipelineState:gather];
        [enc dispatchThreads:MTLSizeMake(p.inCh * 9, pixels, 1) threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [enc setComputePipelineState:multiply];
        [enc dispatchThreadgroups:MTLSizeMake((p.outCh + 31) / 32, (pixels + 15) / 16, 1)
             threadsPerThreadgroup:MTLSizeMake(multiply.threadExecutionWidth * 4, 1, 1)];
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [enc setComputePipelineState:finish];
        [enc dispatchThreads:MTLSizeMake(p.outCh, pixels, 1) threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        ++jobs;
        return true;
    }
};
