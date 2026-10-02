/* Exercise the actual built presentation shaders on Metal, with pixel readback. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double kernel(double x) {
    x=fabs(x);
    if(x<1) return 1.5*x*x*x-2.5*x*x+1;
    if(x<2) return -.5*x*x*x+2.5*x*x-4*x+2;
    return 0;
}
static int bound(int value,int hi) {return value<0?0:value>hi?hi:value;}
int main(int argc,char **argv) {@autoreleasepool {
    if(argc!=3)return 2;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
    if(!library){fprintf(stderr,"%s\n",error.description.UTF8String);return 1;}
    id<MTLCommandQueue> queue=[device newCommandQueue];
    NSMutableArray *results=[NSMutableArray array];
    const unsigned sw=64,sh=48;
    unsigned char input[sw*sh*4];
    for(unsigned y=0;y<sh;y++)for(unsigned x=0;x<sw;x++) {
        unsigned i=(y*sw+x)*4;
        input[i]=((x/3+y/3)%2)?240:16; // Thin repeated high-contrast edges.
        input[i+1]=x*4; input[i+2]=y*5; input[i+3]=255;
    }
    MTLTextureDescriptor *srcDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:sw height:sh mipmapped:NO];
    srcDesc.storageMode=MTLStorageModeShared;srcDesc.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> source=[device newTextureWithDescriptor:srcDesc];
    [source replaceRegion:MTLRegionMake2D(0,0,sw,sh) mipmapLevel:0 withBytes:input bytesPerRow:sw*4];
    for(NSNumber *width in @[@64,@101,@96]) {
        unsigned dw=width.unsignedIntValue,dh=dw==64?48:dw==101?76:60;
        MTLFunctionConstantValues *constants=[MTLFunctionConstantValues new];
        for(NSUInteger i=0x100;i<=0x106;i++) {BOOL value=(i==0x100 && dw==sw)||(i==0x106);[constants setConstantValue:&value type:MTLDataTypeBool atIndex:i];}
        id<MTLFunction> vs=[library newFunctionWithName:@"vs_present_quad"];
        id<MTLFunction> fs=[library newFunctionWithName:@"fs_present_quad" constantValues:constants error:&error];
        MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
        desc.vertexFunction=vs;desc.fragmentFunction=fs;desc.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:desc error:&error];
        if(!pipeline){fprintf(stderr,"%s\n",error.description.UTF8String);return 1;}
        MTLTextureDescriptor *dstDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:dw height:dh mipmapped:NO];
        dstDesc.storageMode=MTLStorageModeShared;dstDesc.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> target=[device newTextureWithDescriptor:dstDesc];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLCommandBuffer> buffer=[queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];[encoder setFragmentTexture:source atIndex:0];
        float metadata[]={1,100,100};[encoder setFragmentBytes:metadata length:sizeof(metadata) atIndex:0];
        [encoder setViewport:(MTLViewport){0,0,dw,dh,0,1}];[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];[buffer commit];[buffer waitUntilCompleted];
        if(buffer.status==MTLCommandBufferStatusError)return 1;
        unsigned char *output=calloc(dw*dh,4);[target getBytes:output bytesPerRow:dw*4 fromRegion:MTLRegionMake2D(0,0,dw,dh) mipmapLevel:0];
        double maxError=0;
        for(unsigned y=0;y<dh;y++)for(unsigned x=0;x<dw;x++)for(unsigned c=0;c<4;c++) {
            double px=(x+.5)*sw/dw-.5,py=(y+.5)*sh/dh-.5,value=0,low=255,high=0;
            int bx=floor(px),by=floor(py);
            for(int j=-1;j<=2;j++)for(int i=-1;i<=2;i++) {
                double v=input[(bound(by+j,sh-1)*sw+bound(bx+i,sw-1))*4+c];
                value+=v*kernel(px-(bx+i))*kernel(py-(by+j));
                if(i>=0&&i<=1&&j>=0&&j<=1){low=fmin(low,v);high=fmax(high,v);}
            }
            value=fmin(high,fmax(low,value));
            maxError=fmax(maxError,fabs(output[(y*dw+x)*4+c]-value));
        }
        [results addObject:@{@"source":@[@(sw),@(sh)],@"output":@[@(dw),@(dh)],@"maximum_byte_error":@(maxError),@"pass":@(maxError<1.1)}];
        free(output);
        if(maxError>=1.1){fprintf(stderr,"pixel error %f\n",maxError);return 1;}
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@(argv[2]) atomically:YES];puts("PASS: actual presentation shader preserves 1:1 pixels and matches bounded cubic reconstruction.");
    return 0;
}}
