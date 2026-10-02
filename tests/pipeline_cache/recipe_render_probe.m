// Reuse only the standalone rendering/readback helpers, not any cache behavior.
#define main standalone_archive_probe_unused_entry
#include "metal_archive_probe.m"
#undef main

#include "pipeline_recipe.h"
#include "../winemetal.h"

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 4, @"usage: recipe_probe fixture.metallib nonce output-directory");
    NSString *nonce = @(argv[2]);
    NSString *directory = @(argv[3]);
    unsigned red = 32 + strtoul(argv[2], NULL, 16) % 160;
    NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    require(bytes != nil, @"metallib fixture missing");
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, dispatch_get_global_queue(0, 0), ^{ (void)bytes; });
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    require(library != nil && error == nil, [NSString stringWithFormat:@"real metallib load: %@", error]);
    NSMutableDictionary *store = [NSMutableDictionary dictionary];
    require(dxmt_recipe_register_library(library, data, ^BOOL(NSString *key, NSData *content) {
      store[key] = [content copy];
      return YES;
    }), @"actual codec rejected real metallib bytes");
    NSString *vertexName = [@"vertex_" stringByAppendingString:nonce];
    NSString *fragmentName = [@"fragment_" stringByAppendingString:nonce];
    id<MTLFunction> vertex = [library newFunctionWithName:vertexName];
    id<MTLFunction> fragment = [library newFunctionWithName:fragmentName];
    require(dxmt_recipe_register_function(vertex, library, vertexName) &&
            dxmt_recipe_register_function(fragment, library, fragmentName), @"codec function registration");
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    struct WMTRenderPipelineInfo info = {0};
    info.vertex_function = (obj_handle_t)(__bridge void *)vertex;
    info.fragment_function = (obj_handle_t)(__bridge void *)fragment;
    NSDictionary *recipe = dxmt_recipe_capture(&info, descriptor);
    if (!recipe) fprintf(stderr, "capture state: vertexDescriptor=%p topology=%lu maxTess=%lu tessIndex=%lu amplification=%lu vertexStack=%lu fragmentStack=%lu shaderValidation=%lu\n",
                        descriptor.vertexDescriptor, (unsigned long)descriptor.inputPrimitiveTopology,
                        (unsigned long)descriptor.maxTessellationFactor, (unsigned long)descriptor.tessellationControlPointIndexType,
                        (unsigned long)descriptor.maxVertexAmplificationCount, (unsigned long)descriptor.maxVertexCallStackDepth,
                        (unsigned long)descriptor.maxFragmentCallStackDepth, (unsigned long)descriptor.shaderValidation);
    require(recipe != nil, @"actual codec capture rejected valid descriptor");
    NSData *encoded = dxmt_recipe_encode(recipe);
    NSDictionary *decoded = dxmt_recipe_decode(encoded);
    require(decoded != nil && [dxmt_recipe_key(recipe) isEqualToString:dxmt_recipe_key(decoded)], @"recipe identity changed on roundtrip");
    require([encoded writeToFile:[directory stringByAppendingPathComponent:@"recipe.json"] atomically:YES], @"recipe write");
    MTLRenderPipelineDescriptor *restored = dxmt_recipe_restore(device, decoded, ^NSData *(NSString *key) { return store[key]; }, &error);
    require(restored != nil && error == nil, [NSString stringWithFormat:@"real descriptor restore: %@", error]);
    double originalMs = 0, restoredMs = 0;
    id<MTLRenderPipelineState> original = create(device, descriptor, MTLPipelineOptionNone, &error, &originalMs);
    require(original != nil && error == nil, [NSString stringWithFormat:@"original pipeline creation: %@", error]);
    NSArray *originalPixels = checkPixels(device, original, red, 64);
    id<MTLRenderPipelineState> replayed = create(device, restored, MTLPipelineOptionNone, &error, &restoredMs);
    require(replayed != nil && error == nil, [NSString stringWithFormat:@"restored pipeline creation: %@", error]);
    NSArray *replayedPixels = checkPixels(device, replayed, red, 64);
    require([originalPixels isEqual:replayedPixels], @"restored descriptor changed rendered pixels");
    error = nil;
    MTLRenderPipelineDescriptor *corrupt = dxmt_recipe_restore(device, decoded, ^NSData *(NSString *key) {
      (void)key;
      return [@"invalid library payload" dataUsingEncoding:NSUTF8StringEncoding];
    }, &error);
    require(corrupt == nil && error != nil, @"corrupt persisted library was accepted");
    NSString *failureDomain = error.domain;
    error = nil;
    id<MTLRenderPipelineState> fallback = create(device, descriptor, MTLPipelineOptionNone, &error, &originalMs);
    require(fallback != nil && error == nil, @"normal creation after corrupt recipe failed");
    checkPixels(device, fallback, red, 64);
    NSDictionary *report = @{@"device":device.name, @"recipe_key":dxmt_recipe_key(recipe), @"recipe_bytes":@(encoded.length),
                              @"metallib_bytes":@(bytes.length), @"registered_libraries":@(store.count),
                              @"original_pixels":originalPixels, @"restored_pixels":replayedPixels,
                              @"corrupt_library_error_domain":failureDomain, @"fallback_pixels_passed":@YES};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
    require(json != nil, @"report JSON");
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
