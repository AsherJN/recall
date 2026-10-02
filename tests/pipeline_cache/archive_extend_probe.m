#define main standalone_archive_probe_unused_entry
#include "metal_archive_probe.m"
#undef main

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 6, @"usage: extend_probe library.metallib archive.metallib nonce fragment_suffix output.metallib");
    NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, dispatch_get_global_queue(0, 0), ^{ (void)bytes; });
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    require(library != nil && error == nil, @"test library load");
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:[NSString stringWithFormat:@"vertex_%s%s", argv[3], getenv("DXMT_PROBE_VERTEX_SUFFIX") ?: ""]];
    descriptor.fragmentFunction = [library newFunctionWithName:[NSString stringWithFormat:@"fragment_%s%s", argv[3], argv[4]]];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    require(descriptor.vertexFunction && descriptor.fragmentFunction, @"test function names");
    double createMs = 0;
    id<MTLRenderPipelineState> state = create(device, descriptor, MTLPipelineOptionNone, &error, &createMs);
    require(state != nil && error == nil, @"test pipeline creation");
    MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    NSString *mode = @(getenv("DXMT_PROBE_ARCHIVE_MODE") ?: "seeded");
    if (![mode isEqualToString:@"fresh"]) archiveDescriptor.url = [NSURL fileURLWithPath:@(argv[2])];
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
    require(archive != nil && error == nil, @"seed archive load");
    if ([mode isEqualToString:@"verify"]) {
      descriptor.binaryArchives = @[archive];
      error = nil;
      state = create(device, descriptor, MTLPipelineOptionFailOnBinaryArchiveMiss, &error, &createMs);
      require(state != nil && error == nil, [NSString stringWithFormat:@"strict multi-library archive hit: %@", error]);
      unsigned green = !strcmp(argv[4], "_1") ? 115 : !strcmp(argv[4], "_2") ? 153 : 64;
      checkPixels(device, state, 32 + strtoul(argv[3], NULL, 16) % 160, green);
      puts("{\"strict_hit\":true,\"pixels_passed\":true}");
      return 0;
    }
    NSMutableArray *retainedInputs = [NSMutableArray arrayWithObjects:library, descriptor, nil];
    MTLRenderPipelineDescriptor *priorDescriptor = nil;
    if (getenv("DXMT_PROBE_PRIOR_LIBRARY")) {
      NSData *priorBytes = [NSData dataWithContentsOfFile:@(getenv("DXMT_PROBE_PRIOR_LIBRARY"))];
      dispatch_data_t priorData = dispatch_data_create(priorBytes.bytes, priorBytes.length, dispatch_get_global_queue(0, 0), ^{ (void)priorBytes; });
      id<MTLLibrary> priorLibrary = [device newLibraryWithData:priorData error:&error];
      require(priorLibrary != nil && error == nil, @"prior library load");
      [retainedInputs addObject:priorLibrary];
      priorDescriptor = [MTLRenderPipelineDescriptor new];
      priorDescriptor.vertexFunction = [priorLibrary newFunctionWithName:[@"vertex_" stringByAppendingString:@(argv[3])]];
      priorDescriptor.fragmentFunction = [priorLibrary newFunctionWithName:[NSString stringWithFormat:@"fragment_%s_1", argv[3]]];
      priorDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      [retainedInputs addObject:priorDescriptor];
      require(priorDescriptor.vertexFunction && priorDescriptor.fragmentFunction, @"prior functions");
      if ([mode isEqualToString:@"fresh"] || [mode isEqualToString:@"seeded_prior_add"])
        require([archive addRenderPipelineFunctionsWithDescriptor:priorDescriptor error:&error] && error == nil, @"prior archive add");
    }
    BOOL added = [archive addRenderPipelineFunctionsWithDescriptor:descriptor error:&error];
    require(added && error == nil, [NSString stringWithFormat:@"archive add: %@", error]);
    if (getenv("DXMT_PROBE_THIRD_LIBRARY")) {
      NSData *thirdBytes = [NSData dataWithContentsOfFile:@(getenv("DXMT_PROBE_THIRD_LIBRARY"))];
      dispatch_data_t thirdData = dispatch_data_create(thirdBytes.bytes, thirdBytes.length, dispatch_get_global_queue(0, 0), ^{ (void)thirdBytes; });
      id<MTLLibrary> thirdLibrary = [device newLibraryWithData:thirdData error:&error];
      require(thirdLibrary != nil && error == nil, @"third library load");
      [retainedInputs addObject:thirdLibrary];
      MTLRenderPipelineDescriptor *third = [MTLRenderPipelineDescriptor new];
      third.vertexFunction = [thirdLibrary newFunctionWithName:[@"vertex_" stringByAppendingString:@(argv[3])]];
      third.fragmentFunction = [thirdLibrary newFunctionWithName:[@"fragment_" stringByAppendingString:@(argv[3])]];
      third.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
      [retainedInputs addObject:third];
      require(third.vertexFunction && third.fragmentFunction &&
              [archive addRenderPipelineFunctionsWithDescriptor:third error:&error] && error == nil, @"third archive add");
    }
    BOOL serialized = [archive serializeToURL:[NSURL fileURLWithPath:@(argv[5])] error:&error];
    NSDictionary *report = @{@"mode":mode, @"retained_inputs":@(retainedInputs.count), @"prior_descriptor_retained":@(priorDescriptor != nil), @"added":@(added), @"serialized":@(serialized), @"error_domain":error.domain ?: @"",
                              @"error_code":@(error.code), @"error_description":error.localizedDescription ?: @""};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
