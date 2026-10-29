#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "WindowsVRM5TensorConvolution.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include <simd/simd.h>
struct Params {
    simd_uint2 inSize, outSize;
    uint32_t inCh, outCh, stride, inputRelu, applyRelu, addResidual, weightOffset, biasOffset;
};
static_assert(sizeof(Params) == 48);
int main() {
    @autoreleasepool {
        auto device = MTLCreateSystemDefaultDevice();
        assert(device);
        WVRM5TensorConvolution gated;
        unsetenv("WVR_NEURAL_M5_TENSOR"); gated.initialize(device); assert(!gated.ready());
        setenv("WVR_NEURAL_M5_TENSOR", "1", 1); gated.initialize(device);
        if (![device supportsFamily:MTLGPUFamilyApple10]) assert(!gated.ready());
        unsetenv("WVR_NEURAL_M5_TENSOR");
        // Exercise the production kernels/encoder on the host GPU too. This
        // bypasses capability selection only inside this numerical test.
        WVRM5TensorConvolution backend;
        backend.device = device;
        auto options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion4_0;
        options.mathMode = MTLMathModeSafe;
        NSError *error = nil;
        auto library = [device newLibraryWithSource:kWVRM5TensorSource options:options error:&error];
        if (!library) { NSLog(@"%@", error); return 1; }
        backend.gather = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_gather"] error:&error];
        backend.multiply = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_matmul"] error:&error];
        backend.finish = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"tensor_conv_finish"] error:&error];
        assert(backend.ready());
        auto queue = [device newCommandQueue];
        for (unsigned variant = 0; variant < 8; ++variant) {
            unsigned w = variant < 4 ? 13 : 32, h = variant < 4 ? 11 : 24;
            unsigned ic = variant < 4 ? 3 : 40, oc = variant < 4 ? 5 : 32;
            unsigned stride = variant % 2 + 1, ow = (w + stride - 1) / stride, oh = (h + stride - 1) / stride;
            Params p{{w,h},{ow,oh},ic,oc,stride,variant%2,(variant/2)%2,variant%3==0,16,16+oc*ic*9};
            std::vector<_Float16> input(w*h*ic), weights(p.biasOffset+oc), residual(ow*oh*oc), expected(ow*oh*oc);
            for (unsigned i=0;i<input.size();++i) input[i]=std::sin(float(i)*0.7f)*0.3f;
            for (unsigned i=0;i<weights.size();++i) weights[i]=std::sin(float(i)*0.3f)*0.1f;
            for (unsigned i=0;i<residual.size();++i) residual[i]=std::cos(float(i))*0.2f;
            for (unsigned y=0;y<oh;++y) for(unsigned x=0;x<ow;++x) for(unsigned o=0;o<oc;++o) {
                float v=float(weights[p.biasOffset+o]);
                for(unsigned c=0;c<ic;++c) for(int ky=0;ky<3;++ky) for(int kx=0;kx<3;++kx) {
                    int sx=int(x*stride)-1+kx, sy=int(y*stride)-1+ky;
                    if(sx<0 || sy<0 || sx>=int(w) || sy>=int(h)) continue;
                    float a=float(input[(sy*w+sx)*ic+c]); if(p.inputRelu) a=std::max(a,0.0f);
                    v+=a*float(weights[p.weightOffset+o*ic*9+c*9+ky*3+kx]);
                }
                unsigned i=(y*ow+x)*oc+o;
                if(p.addResidual) v+=float(residual[i]);
                if(p.applyRelu) v=std::max(v,0.0f);
                expected[i]=v;
            }
            auto in=[device newBufferWithBytes:input.data() length:input.size()*2 options:MTLResourceStorageModeShared];
            auto res=[device newBufferWithBytes:residual.data() length:residual.size()*2 options:MTLResourceStorageModeShared];
            auto weightsBuffer=[device newBufferWithBytes:weights.data() length:weights.size()*2 options:MTLResourceStorageModeShared];
            auto out=[device newBufferWithLength:expected.size()*2 options:MTLResourceStorageModeShared];
            auto command=[queue commandBuffer]; auto encoder=[command computeCommandEncoder];
            [encoder setBuffer:in offset:0 atIndex:0]; [encoder setBuffer:res offset:0 atIndex:1];
            [encoder setBuffer:weightsBuffer offset:0 atIndex:2]; [encoder setBuffer:out offset:0 atIndex:3];
            [encoder setBytes:&p length:sizeof(p) atIndex:4];
            assert(backend.encode(encoder,p)); [encoder endEncoding];
            [command commit]; [command waitUntilCompleted];
            if(command.error) NSLog(@"%@",command.error);
            assert(command.status==MTLCommandBufferStatusCompleted);
            auto result=static_cast<const _Float16 *>(out.contents);
            float maxError=0;
            for(unsigned i=0;i<expected.size();++i) {
                assert(std::isfinite(float(result[i])));
                maxError=std::max(maxError,std::abs(float(result[i])-float(expected[i])));
            }
            printf("tensor variant=%u stride=%u channels=%u/%u maxAbsError=%g\n",variant,stride,ic,oc,maxError);
            assert(maxError<0.003f);
        }
        auto command=[queue commandBuffer]; auto encoder=[command computeCommandEncoder];
        Params enormous{{2048,2048},{2048,2048},40,32,1,0,0,0,0,0};
        assert(!backend.encode(encoder,enormous)); [encoder endEncoding];
        assert(backend.fallbacks==1);
        backend.gpuFailed->store(true);
        Params small{{1,1},{1,1},1,1,1,0,0,0,0,0};
        auto fallbackCommand=[queue commandBuffer]; auto fallbackEncoder=[fallbackCommand computeCommandEncoder];
        assert(!backend.encode(fallbackEncoder,small)); [fallbackEncoder endEncoding];
        assert(backend.fallbacks==2);
        printf("PASS: tensor numerical comparisons, stride/padding/ReLU/residual, scratch reuse/bound, default-off and M2 capability fallback on %s\n",device.name.UTF8String);
    }
}
