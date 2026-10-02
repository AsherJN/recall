#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

static double milliseconds(void) {
  static mach_timebase_info_data_t timebase;
  if (!timebase.denom) mach_timebase_info(&timebase);
  return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

static void require(BOOL success, NSString *message) {
  if (!success) {
    fprintf(stderr, "FAIL %s\n", message.UTF8String);
    exit(2);
  }
}

static NSArray *checkPixels(id<MTLDevice> device, id<MTLRenderPipelineState> pipeline,
                           unsigned red, unsigned green) {
  MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                              width:32 height:32 mipmapped:NO];
  textureDescriptor.storageMode = MTLStorageModePrivate;
  textureDescriptor.usage = MTLTextureUsageRenderTarget;
  id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
  id<MTLBuffer> buffer = [device newBufferWithLength:32 * 256 options:MTLResourceStorageModeShared];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> command = [queue commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
  [render setRenderPipelineState:pipeline];
  [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [render endEncoding];
  id<MTLBlitCommandEncoder> copy = [command blitCommandEncoder];
  [copy copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(32, 32, 1) toBuffer:buffer destinationOffset:0
   destinationBytesPerRow:256 destinationBytesPerImage:32 * 256];
  [copy endEncoding];
  [command commit];
  [command waitUntilCompleted]; // Explicit synchronization belongs only in this standalone readback test.
  require(command.status == MTLCommandBufferStatusCompleted, [NSString stringWithFormat:@"GPU command: %@", command.error]);
  NSMutableArray *pixels = [NSMutableArray array];
  for (unsigned sample = 0; sample < 3; ++sample) {
    unsigned x = sample == 0 ? 1 : sample == 1 ? 16 : 30;
    unsigned y = sample == 0 ? 1 : sample == 1 ? 16 : 30;
    const uint8_t *pixel = (const uint8_t *)buffer.contents + y * 256 + x * 4;
    require(abs((int)pixel[0] - (int)red) <= 1 && abs((int)pixel[1] - (int)green) <= 1 &&
            abs((int)pixel[2] - 191) <= 1 && pixel[3] == 255,
            [NSString stringWithFormat:@"pixel mismatch at %u,%u: %u,%u,%u,%u expected %u,%u,191,255",
             x, y, pixel[0], pixel[1], pixel[2], pixel[3], red, green]);
    [pixels addObject:@[@(pixel[0]), @(pixel[1]), @(pixel[2]), @(pixel[3])]];
  }
  return pixels;
}

static id<MTLRenderPipelineState> create(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor,
                                        MTLPipelineOption options, NSError **error, double *elapsed) {
  const double begin = milliseconds();
  id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor
                                                                       options:options reflection:nil error:error];
  *elapsed = milliseconds() - begin;
  return state;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 4, @"usage: probe capture|archive|default|miss|errors directory nonce");
    NSString *mode = @(argv[1]);
    NSString *directory = @(argv[2]);
    NSString *nonce = @(argv[3]);
    unsigned red = 32 + strtoul(argv[3], NULL, 16) % 160;
    NSString *vertexName = [@"vertex_" stringByAppendingString:nonce];
    NSString *fragmentName = [@"fragment_" stringByAppendingString:nonce];
    NSString *alternateName = [@"unseen_" stringByAppendingString:nonce];
    NSString *unlinkedName = [@"unlinked_" stringByAppendingString:nonce];
    NSString *source = [NSString stringWithFormat:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "vertex float4 %@(uint id [[vertex_id]]) { const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[id],0,1); }\n"
         "fragment float4 %@() { return float4(%.10f,0.25,0.75,1.0); }\n"
         "fragment float4 %@() { return float4(%.10f,0.60,0.75,1.0); }\n"
         "struct UnlinkedInput { float4 position [[position]]; float4 missing [[user(locn7)]]; };\n"
         "fragment float4 %@(UnlinkedInput input [[stage_in]]) { return input.missing; }\n",
        vertexName, fragmentName, red / 255.0, alternateName, red / 255.0, unlinkedName];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, @"No Metal device");
    NSError *error = nil;
    double began = milliseconds();
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    double libraryMs = milliseconds() - began;
    require(library != nil && error == nil, [NSString stringWithFormat:@"MSL library compilation: %@", error]);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:vertexName];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentName];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSURL *archiveURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"known.binary.metallib"]];
    NSMutableDictionary *result = [@{@"mode":mode, @"nonce":nonce, @"device":device.name,
                                    @"library_compile_ms":@(libraryMs), @"framework_cache":@"default; not disabled or cleared"} mutableCopy];
    MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    id<MTLBinaryArchive> archive = nil;
    id<MTLRenderPipelineState> state = nil;
    double createMs = 0;
    if ([mode isEqualToString:@"capture"]) {
      archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
      require(archive != nil && error == nil, [NSString stringWithFormat:@"new empty archive: %@", error]);
      state = create(device, descriptor, MTLPipelineOptionNone, &error, &createMs);
      require(state != nil && error == nil, [NSString stringWithFormat:@"initial PSO: %@", error]);
      began = milliseconds();
      BOOL added = [archive addRenderPipelineFunctionsWithDescriptor:descriptor error:&error];
      result[@"archive_add_ms"] = @(milliseconds() - began);
      require(added && error == nil, [NSString stringWithFormat:@"archive capture: %@", error]);
      began = milliseconds();
      BOOL serialized = [archive serializeToURL:archiveURL error:&error];
      result[@"serialize_ms"] = @(milliseconds() - began);
      require(serialized && error == nil, [NSString stringWithFormat:@"archive serialization: %@", error]);
      result[@"archive_add_success"] = @(added);
      result[@"serialize_success"] = @(serialized);
    } else if ([mode isEqualToString:@"archive"] || [mode isEqualToString:@"miss"]) {
      archiveDescriptor.url = archiveURL;
      began = milliseconds();
      archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
      result[@"archive_load_ms"] = @(milliseconds() - began);
      require(archive != nil && error == nil, [NSString stringWithFormat:@"load persisted archive: %@", error]);
      descriptor.binaryArchives = @[archive];
      if ([mode isEqualToString:@"miss"]) descriptor.fragmentFunction = [library newFunctionWithName:alternateName];
      state = create(device, descriptor, MTLPipelineOptionFailOnBinaryArchiveMiss, &error, &createMs);
      if ([mode isEqualToString:@"archive"]) {
        require(state != nil && error == nil, [NSString stringWithFormat:@"expected strict archive hit: %@", error]);
        result[@"strict_archive_hit"] = @YES;
      } else {
        require(state == nil && error != nil, @"unseen descriptor unexpectedly satisfied strict archive lookup");
        result[@"strict_miss_error_code"] = @(error.code);
        result[@"strict_miss_error_domain"] = error.domain;
        result[@"strict_miss_ms"] = @(createMs);
        error = nil;
        state = create(device, descriptor, MTLPipelineOptionNone, &error, &createMs);
        require(state != nil && error == nil, [NSString stringWithFormat:@"miss fallback creation: %@", error]);
        result[@"fallback_success"] = @YES;
      }
    } else if ([mode isEqualToString:@"errors"]) {
      NSMutableArray *failures = [NSMutableArray array];
      for (NSString *filename in @[@"missing.binary.metallib", @"corrupt.binary.metallib"]) {
        archiveDescriptor.url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:filename]];
        error = nil;
        archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
        require(archive == nil && error != nil, @"invalid archive load was not reported");
        [failures addObject:@{@"operation":filename, @"domain":error.domain, @"code":@(error.code)}];
      }
      archiveDescriptor.url = nil;
      error = nil;
      archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
      require(archive != nil && error == nil, @"new archive for negative cases");
      // Structurally valid API descriptor, but deliberately unlinked stage
      // interfaces. A null vertex function instead triggers Metal validation's
      // process assertion, which would not test recoverable cache errors.
      MTLRenderPipelineDescriptor *invalid = [descriptor copy];
      invalid.fragmentFunction = [library newFunctionWithName:unlinkedName];
      BOOL added = [archive addRenderPipelineFunctionsWithDescriptor:invalid error:&error];
      require(!added && error != nil, @"invalid descriptor capture was not reported");
      [failures addObject:@{@"operation":@"invalid_descriptor_capture", @"domain":error.domain, @"code":@(error.code)}];
      error = nil;
      BOOL serialized = [archive serializeToURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"absent-parent/archive.binary.metallib"]] error:&error];
      require(!serialized && error != nil, @"invalid archive serialization was not reported");
      [failures addObject:@{@"operation":@"invalid_serialization_path", @"domain":error.domain, @"code":@(error.code)}];
      result[@"accounted_cache_failures"] = failures;
      error = nil;
      descriptor.binaryArchives = nil;
      state = create(device, descriptor, MTLPipelineOptionNone, &error, &createMs);
      require(state != nil && error == nil, [NSString stringWithFormat:@"uncached fallback after cache errors: %@", error]);
      result[@"fallback_success"] = @YES;
    } else {
      require([mode isEqualToString:@"default"], @"unknown mode");
      state = create(device, descriptor, MTLPipelineOptionNone, &error, &createMs);
      require(state != nil && error == nil, [NSString stringWithFormat:@"default cache creation: %@", error]);
    }
    result[@"pipeline_create_ms"] = @(createMs);
    result[@"pixels"] = checkPixels(device, state, red, [mode isEqualToString:@"miss"] ? 153 : 64);
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
    require(json != nil, @"JSON report");
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
