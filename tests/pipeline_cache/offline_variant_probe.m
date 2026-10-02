#define main standalone_archive_probe_unused_entry
#include "metal_archive_probe.m"
#undef main
#include "pipeline_recipe.h"
#include "pipeline_cache.h"
#include "../winemetal.h"

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 5, @"metallib nonce existing-isolated-namespace variant-count");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, dispatch_get_global_queue(0, 0), ^{ (void)bytes; });
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    require(library && !error, @"real fixture library");
    NSString *directory = @(argv[3]);
    require([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"recipes"]], @"existing isolated namespace");
    require(dxmt_recipe_register_library(library, data, ^BOOL(NSString *key, NSData *content) {
      NSString *path = [[directory stringByAppendingPathComponent:@"libraries"] stringByAppendingPathComponent:[key stringByAppendingString:@".air"]];
      return [content writeToFile:path atomically:YES];
    }), @"register actual library bytes");
    NSString *vertexName = [@"vertex_" stringByAppendingString:@(argv[2])];
    NSString *fragmentName = [@"fragment_" stringByAppendingString:@(argv[2])];
    id<MTLFunction> vertex = [library newFunctionWithName:vertexName];
    id<MTLFunction> fragment = [library newFunctionWithName:fragmentName];
    require(dxmt_recipe_register_function(vertex, library, vertexName) && dxmt_recipe_register_function(fragment, library, fragmentName), @"actual function identity");
    struct WMTRenderPipelineInfo info = {0};
    info.vertex_function = (obj_handle_t)(__bridge void *)vertex;
    info.fragment_function = (obj_handle_t)(__bridge void *)fragment;
    unsigned count = (unsigned)strtoul(argv[4], NULL, 10);
    require(count > 0 && count <= 512, @"bounded variant count");
    NSMutableArray *pixels = [NSMutableArray array];
    for (unsigned i = 1; i <= count; ++i) {
      @autoreleasepool {
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        for (unsigned bit = 0; bit < 10; ++bit)
          descriptor.vertexBuffers[bit].mutability = (i & (1u << bit)) ? MTLMutabilityImmutable : MTLMutabilityDefault;
        NSDictionary *recipe = dxmt_recipe_capture(&info, descriptor);
        require(recipe != nil, @"real descriptor capture");
        NSString *key = dxmt_recipe_key(recipe);
        require([dxmt_recipe_key(dxmt_recipe_decode(dxmt_recipe_encode(recipe))) isEqualToString:key], @"canonical codec identity");
        NSDictionary *envelope = @{@"recipe":recipe, @"cost_us":@30000};
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&error];
        NSString *path = [[directory stringByAppendingPathComponent:@"recipes"] stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
        require(encoded && [encoded writeToFile:path atomically:YES], @"isolated recipe envelope write");
        if (i == 1 || i == count) {
          id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
          require(state && !error, @"sample real pipeline");
          unsigned red = 32 + strtoul(argv[2], NULL, 16) % 160;
          [pixels addObject:checkPixels(device, state, red, 64)];
        }
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"variants":@(count), @"sample_pixels":pixels} options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
  }
}
