#define main standalone_archive_probe_unused_entry
#include "metal_archive_probe.m"
#undef main

#include "pipeline_recipe.h"
#include "pipeline_cache.h"
#include "../winemetal.h"

static MTLRenderPipelineDescriptor *makeDescriptor(id<MTLFunction> vertex, id<MTLFunction> fragment) {
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = vertex;
  descriptor.fragmentFunction = fragment;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  return descriptor;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 4, @"usage: manager_probe fixture.metallib nonce mode");
    NSString *nonce = @(argv[2]);
    NSString *mode = @(argv[3]);
    unsigned red = 32 + strtoul(argv[2], NULL, 16) % 160;
    NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    require(bytes != nil, @"metallib fixture missing");
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, dispatch_get_global_queue(0, 0), ^{ (void)bytes; });
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    require(library != nil && error == nil, [NSString stringWithFormat:@"real metallib load: %@", error]);
    BOOL enabled = dxmt_pipeline_cache_enabled();
    BOOL registered = enabled && dxmt_recipe_register_library(library, data, ^BOOL(NSString *key, NSData *content) {
      return dxmt_pipeline_cache_store_library(device, key, content);
    });
    require(registered == enabled, @"library registration did not follow cache enablement");
    NSString *vertexName = [@"vertex_" stringByAppendingString:nonce];
    id<MTLFunction> vertex = [library newFunctionWithName:vertexName];
    BOOL vertexRegistered = enabled && dxmt_recipe_register_function(vertex, library, vertexName);
    require(vertexRegistered == enabled, @"vertex registration enablement");
    const unsigned recipes = [mode hasPrefix:@"growth_"] ? 3 : 1;
    NSMutableArray *pixels = [NSMutableArray array], *identities = [NSMutableArray array];
    double firstMs = 0, secondMs = 0;
    BOOL allIdentical = YES;
    for (unsigned recipeIndex = 0; recipeIndex < recipes; ++recipeIndex) {
      id<MTLLibrary> recipeLibrary = library;
      id<MTLFunction> recipeVertex = vertex;
      if (recipeIndex) {
        NSString *extraPath = [[@(argv[1]) stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:[NSString stringWithFormat:@"fixture_%u.metallib", recipeIndex]];
        NSData *extraBytes = [NSData dataWithContentsOfFile:extraPath];
        require(extraBytes != nil, @"distinct recipe metallib missing");
        dispatch_data_t extraData = dispatch_data_create(extraBytes.bytes, extraBytes.length,
            dispatch_get_global_queue(0, 0), ^{ (void)extraBytes; });
        recipeLibrary = [device newLibraryWithData:extraData error:&error];
        require(recipeLibrary != nil && error == nil, @"distinct recipe library load");
        require(enabled && dxmt_recipe_register_library(recipeLibrary, extraData, ^BOOL(NSString *key, NSData *content) {
          return dxmt_pipeline_cache_store_library(device, key, content);
        }), @"distinct recipe library registration");
        recipeVertex = [recipeLibrary newFunctionWithName:vertexName];
        require(dxmt_recipe_register_function(recipeVertex, recipeLibrary, vertexName), @"distinct recipe vertex registration");
      }
      NSString *fragmentName = [NSString stringWithFormat:@"fragment_%@%@", nonce,
                                recipeIndex ? [NSString stringWithFormat:@"_%u", recipeIndex] : @""];
      id<MTLFunction> fragment = [recipeLibrary newFunctionWithName:fragmentName];
      require((enabled && dxmt_recipe_register_function(fragment, recipeLibrary, fragmentName)) == enabled, @"fragment registration enablement");
      struct WMTRenderPipelineInfo info = {0};
      info.vertex_function = (obj_handle_t)(__bridge void *)recipeVertex;
      info.fragment_function = (obj_handle_t)(__bridge void *)fragment;
      const unsigned green = recipeIndex == 0 ? 64 : recipeIndex == 1 ? 115 : 153;
      const double began = milliseconds();
      id<MTLRenderPipelineState> first = dxmt_pipeline_cache_new_render_pipeline(
          device, makeDescriptor(recipeVertex, fragment), &info, MTLPipelineOptionNone, &error);
      firstMs += milliseconds() - began;
      require(first != nil && error == nil, [NSString stringWithFormat:@"first managed pipeline: %@", error]);
      [pixels addObject:checkPixels(device, first, red, green)];
      error = nil;
      const double again = milliseconds();
      id<MTLRenderPipelineState> second = dxmt_pipeline_cache_new_render_pipeline(
          device, makeDescriptor(recipeVertex, fragment), &info, MTLPipelineOptionNone, &error);
      secondMs += milliseconds() - again;
      require(second != nil && error == nil, [NSString stringWithFormat:@"repeat managed pipeline: %@", error]);
      checkPixels(device, second, red, green);
      allIdentical &= first == second;
      [identities addObject:@(first == second)];
      if (enabled) require(first == second, @"repeat cache lookup did not return identical retained Metal PSO");
    }
    // Allow the actual periodic worker to persist the bounded learning queue
    // and publish its summary; no test-only manager flush or shutdown is used.
    [NSThread sleepForTimeInterval:2.2];
    NSDictionary *report = @{@"mode":mode, @"enabled":@(enabled), @"device":device.name,
                              @"same_pso_identity":@(allIdentical), @"first_lookup_ms":@(firstMs),
                              @"second_lookup_ms":@(secondMs), @"pixels":pixels, @"recipe_count":@(recipes),
                              @"pso_identities":identities,
                              @"startup_budget_ms":@(getenv("DXMT_PIPELINE_CACHE_PREWARM_MS") ?: "unset")};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
    require(json != nil, @"report JSON");
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    dxmt_pipeline_cache_shutdown(); // Admission only; parent checks persisted pre-exit summaries.
    return 0;
  }
}
