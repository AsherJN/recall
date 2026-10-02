#define main standalone_archive_probe_unused_entry
#include "metal_archive_probe.m"
#undef main

#include "pipeline_recipe.h"
#include "pipeline_cache.h"
#include "../winemetal.h"
#include <CommonCrypto/CommonDigest.h>

@interface RRFixture : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong) id<MTLFunction> vertex;
@property(nonatomic, strong) id<MTLFunction> fragment;
@property(nonatomic, strong) NSData *libraryBytes;
@property(nonatomic, strong) NSString *libraryKey;
@property(nonatomic) unsigned red;
@end
@implementation RRFixture
@end

static RRFixture *loadFixture(NSString *path, NSString *nonce) {
  RRFixture *fixture = [RRFixture new];
  fixture.device = MTLCreateSystemDefaultDevice();
  require(fixture.device != nil, @"Metal device missing");
  fixture.libraryBytes = [NSData dataWithContentsOfFile:path];
  require(fixture.libraryBytes != nil, @"real metallib fixture missing");
  NSData *bytes = fixture.libraryBytes;
  dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length,
      dispatch_get_global_queue(0, 0), ^{ (void)bytes; });
  NSError *error = nil;
  fixture.library = [fixture.device newLibraryWithData:data error:&error];
  require(fixture.library != nil && error == nil, @"real metallib load failed");
  __block NSString *libraryKey = nil;
  require(dxmt_recipe_register_library(fixture.library, data, ^BOOL(NSString *key, NSData *content) {
    require([content isEqualToData:bytes], @"registered AIR bytes differ");
    libraryKey = key;
    return YES; // This fixture step records codec identity, not manager admission.
  }), @"real library identity registration failed");
  fixture.libraryKey = libraryKey;
  NSString *vertexName = [@"vertex_" stringByAppendingString:nonce];
  NSString *fragmentName = [@"fragment_" stringByAppendingString:nonce];
  fixture.vertex = [fixture.library newFunctionWithName:vertexName];
  fixture.fragment = [fixture.library newFunctionWithName:fragmentName];
  require(dxmt_recipe_register_function(fixture.vertex, fixture.library, vertexName), @"vertex identity");
  require(dxmt_recipe_register_function(fixture.fragment, fixture.library, fragmentName), @"fragment identity");
  fixture.red = 32 + strtoul(nonce.UTF8String, NULL, 16) % 160;
  return fixture;
}

static MTLRenderPipelineDescriptor *descriptorFor(RRFixture *fixture, unsigned index) {
  require(index < (1u << 14), @"fixture variant bound");
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = fixture.vertex;
  descriptor.fragmentFunction = fixture.fragment;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  // Legal descriptor states; the no-buffer fixture shader renders identically.
  // These exercise distinct production codec records, not 8192 expensive PSOs.
  for (unsigned i = 0; i < 14; ++i)
    descriptor.vertexBuffers[i].mutability = (index & (1u << i)) ? MTLMutabilityImmutable : MTLMutabilityDefault;
  return descriptor;
}

static NSDictionary *recordFor(RRFixture *fixture, unsigned index) {
  struct WMTRenderPipelineInfo info = {0};
  info.vertex_function = (obj_handle_t)(__bridge void *)fixture.vertex;
  info.fragment_function = (obj_handle_t)(__bridge void *)fixture.fragment;
  NSDictionary *recipe = dxmt_recipe_capture(&info, descriptorFor(fixture, index));
  require(recipe != nil, @"actual descriptor capture failed");
  NSData *data = dxmt_recipe_encode(recipe);
  NSDictionary *decoded = dxmt_recipe_decode(data);
  NSString *key = dxmt_recipe_key(recipe);
  require(data != nil && decoded != nil && [dxmt_recipe_key(decoded) isEqualToString:key], @"codec round trip failed");
  return @{@"key":key, @"data":data, @"recipe":recipe};
}

static NSDictionary *fixtureProof(RRFixture *fixture) {
  NSMutableSet *keys = [NSMutableSet setWithCapacity:8192];
  NSUInteger minimumBytes = NSUIntegerMax, maximumBytes = 0;
  double began = milliseconds();
  for (unsigned i = 0; i < 8192; ++i) {
    @autoreleasepool {
      NSDictionary *record = recordFor(fixture, i);
      [keys addObject:record[@"key"]];
      NSUInteger count = [record[@"data"] length];
      minimumBytes = MIN(minimumBytes, count);
      maximumBytes = MAX(maximumBytes, count);
    }
  }
  require(keys.count == 8192, @"fixture did not generate8192 distinct canonical recipes");
  NSMutableArray *pixels = [NSMutableArray array];
  for (NSNumber *variant in @[@0, @4095, @8191]) {
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [fixture.device newRenderPipelineStateWithDescriptor:
        descriptorFor(fixture, variant.unsignedIntValue) error:&error];
    require(pipeline != nil && error == nil, @"sample variant is not a valid Metal pipeline");
    [pixels addObject:checkPixels(fixture.device, pipeline, fixture.red, 64)];
  }
  return @{@"distinct_valid_codec_records":@(keys.count), @"recipe_min_bytes":@(minimumBytes),
    @"recipe_max_bytes":@(maximumBytes), @"duration_ms":@(milliseconds()-began),
    @"sampled_real_pipeline_variants":@[@0,@4095,@8191], @"pixels":pixels};
}

#ifdef DXMT_PIPELINE_CACHE_TESTING
static NSDictionary *settle(RRFixture *fixture) {
  double deadline=milliseconds()+20000;
  NSDictionary *stats=nil;
  do {
    dxmt_pipeline_cache_test_drain(fixture.device);
    stats=dxmt_pipeline_cache_test_stats(fixture.device);
    if([stats[@"pending_records"] unsignedIntValue]==0)return stats;
    [NSThread sleepForTimeInterval:0.015];
  } while(milliseconds()<deadline);
  require(NO, [NSString stringWithFormat:@"recorder failed to drain: %@",stats]);return nil;
}
static void admitLibrary(RRFixture *fixture) {
  require(dxmt_pipeline_cache_store_library(fixture.device,fixture.libraryKey,fixture.libraryBytes),@"fixture library admission");
}
static NSDictionary *stress(RRFixture *fixture,NSString *mode) {
  dxmt_pipeline_cache_test_pause(fixture.device,YES); // Also waits for storage initialization.
  if([mode isEqualToString:@"hit_retry"]){
    admitLibrary(fixture);dxmt_pipeline_cache_test_pause(fixture.device,NO);settle(fixture);
    dxmt_pipeline_cache_test_pause(fixture.device,YES);
    for(unsigned i=1;i<=2304;++i)@autoreleasepool {
      NSDictionary *r=recordFor(fixture,i);
      require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"hit-retry pressure setup");
    }
    struct WMTRenderPipelineInfo info={0};
    info.vertex_function=(obj_handle_t)(__bridge void *)fixture.vertex;info.fragment_function=(obj_handle_t)(__bridge void *)fixture.fragment;
    NSError *error=nil;
    id<MTLRenderPipelineState> first=dxmt_pipeline_cache_new_render_pipeline(fixture.device,descriptorFor(fixture,0),&info,MTLPipelineOptionNone,&error);
    require(first && !error,@"pressure changed real Metal creation");checkPixels(fixture.device,first,fixture.red,64);
    require([dxmt_pipeline_cache_test_stats(fixture.device)[@"queue_full"] unsignedIntValue]>0,@"production recipe did not encounter intended pressure");
    dxmt_pipeline_cache_test_pause(fixture.device,NO);settle(fixture);
    id<MTLRenderPipelineState> second=dxmt_pipeline_cache_new_render_pipeline(fixture.device,descriptorFor(fixture,0),&info,MTLPipelineOptionNone,&error);
    require(second==first && !error,@"memory-hit retry recompiled pipeline");checkPixels(fixture.device,second,fixture.red,64);
    NSDictionary *done=settle(fixture);
    require([done[@"recipe_files"] unsignedIntValue]==2305,@"memory hit did not repair rejected recipe");
    return @{@"final":done,@"same_pso_after_recording_retry":@YES};
  }
  if([mode isEqualToString:@"io_retry"]){
    admitLibrary(fixture);dxmt_pipeline_cache_test_pause(fixture.device,NO);settle(fixture);
    NSDictionary *r=recordFor(fixture,0);
    NSString *root=@(getenv("DXMT_PIPELINE_CACHE_PATH"));
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];require(names.count==1,@"isolated namespace");
    NSString *blocked=[[[root stringByAppendingPathComponent:names[0]] stringByAppendingPathComponent:@"recipes"] stringByAppendingPathComponent:[r[@"key"] stringByAppendingString:@".json"]];
    require([NSFileManager.defaultManager createDirectoryAtPath:blocked withIntermediateDirectories:NO attributes:nil error:nil],@"IO failure fixture");
    require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"IO fixture admission");
    dxmt_pipeline_cache_test_drain(fixture.device);
    NSDictionary *failed=dxmt_pipeline_cache_test_stats(fixture.device);
    require([failed[@"io_failures"] unsignedIntValue]>0 && [failed[@"write_retries"] unsignedIntValue]>0,@"IO retry not classified");
    require([NSFileManager.defaultManager removeItemAtPath:blocked error:nil],@"remove isolated failure fixture");
    NSDictionary *done=settle(fixture);require([done[@"recipe_files"] unsignedIntValue]==1,@"transient IO did not recover");
    return @{@"failed":failed,@"final":done};
  }
  if([mode isEqualToString:@"burst"]){
    admitLibrary(fixture);
    NSDictionary *first=recordFor(fixture,0);
    for(unsigned i=0;i<2303;++i)@autoreleasepool {
      NSDictionary *r=recordFor(fixture,i);
      require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"2048-slot burst rejected early");
    }
    NSDictionary *overflow=recordFor(fixture,2303);
    require(!dxmt_pipeline_cache_test_recipe(fixture.device,overflow[@"key"],overflow[@"data"],1000),@"record bound bypassed");
    require(dxmt_pipeline_cache_test_recipe(fixture.device,first[@"key"],first[@"data"],1000),@"duplicate rejected at full queue");
    for(unsigned i=0;i<5000;++i)dxmt_pipeline_cache_test_trace(fixture.device,first[@"key"]);
    NSDictionary *full=dxmt_pipeline_cache_test_stats(fixture.device);
    require([full[@"pending_records"] unsignedIntValue]==2304 && [full[@"queue_full"] unsignedIntValue]>0,@"queue-full accounting");
    require([full[@"diagnostic_drops"] unsignedIntValue]>0 && [full[@"pending_bytes"] unsignedLongLongValue]<=32u*1024u*1024u,@"diagnostic isolation/budget");
    dxmt_pipeline_cache_test_pause(fixture.device,NO);
    NSDictionary *done=settle(fixture);
    require([done[@"recipe_files"] unsignedIntValue]==2303 && [done[@"library_files"] unsignedIntValue]==1,@"burst lost durable data");
    require(dxmt_pipeline_cache_test_recipe(fixture.device,overflow[@"key"],overflow[@"data"],1000),@"retry after drain failed");
    done=settle(fixture);require([done[@"recipe_files"] unsignedIntValue]==2304,@"rejected recipe did not recover");
    return @{@"full":full,@"final":done};
  }
  if([mode isEqualToString:@"capacity"]){
    admitLibrary(fixture);dxmt_pipeline_cache_test_pause(fixture.device,NO);settle(fixture);
    NSMutableArray *records=[NSMutableArray arrayWithCapacity:8192];
    for(unsigned i=0;i<8192;++i)@autoreleasepool {[records addObject:recordFor(fixture,i)];}
    double began=milliseconds();
    dispatch_apply(4,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t worker){
      for(unsigned i=(unsigned)worker;i<8192;i+=4)@autoreleasepool {
        NSDictionary *r=records[i];
        while(!dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000)) {
          require(milliseconds()-began<40000,@"concurrent admission failed to progress");[NSThread sleepForTimeInterval:0.001];
        }
      }
    });
    NSDictionary *done=settle(fixture);
    require([done[@"recipe_files"] unsignedIntValue]==8192,@"catalog failed beyond old4096 cap");
    require([done[@"pending_records"] unsignedIntValue]==0 && [done[@"pending_bytes"] unsignedIntValue]==0,@"drain leaked budget");
    return @{@"final":done,@"admission_and_drain_ms":@(milliseconds()-began)};
  }
  if([mode isEqualToString:@"dependencies"]){
    NSDictionary *r=recordFor(fixture,0);
    require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"recipe admission");
    dxmt_pipeline_cache_test_pause(fixture.device,NO);dxmt_pipeline_cache_test_drain(fixture.device);
    NSDictionary *waiting=dxmt_pipeline_cache_test_stats(fixture.device);
    require([waiting[@"recipe_files"] unsignedIntValue]==0 && [waiting[@"dependency_retries"] unsignedIntValue]>0,@"published incomplete recipe");
    admitLibrary(fixture);NSDictionary *done=settle(fixture);
    require([done[@"recipe_files"] unsignedIntValue]==1 && [done[@"dependency_failures"] unsignedIntValue]==0,@"late dependency did not repair recording");
    return @{@"waiting":waiting,@"final":done};
  }
  if([mode isEqualToString:@"limits"]){
    admitLibrary(fixture);dxmt_pipeline_cache_test_pause(fixture.device,NO);settle(fixture);
    dxmt_pipeline_cache_test_limits(fixture.device,1,65536,512u*1024u*1024u,-1);
    for(unsigned i=0;i<2;++i){NSDictionary *r=recordFor(fixture,i);require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"cap fixture admission");settle(fixture);}
    NSDictionary *quota=dxmt_pipeline_cache_test_stats(fixture.device);
    require([quota[@"recipe_files"] unsignedIntValue]==1 && [quota[@"recipe_limit_rejections"] unsignedIntValue]==1,@"recipe quota reason");
    NSDictionary *r=recordFor(fixture,2);
    dxmt_pipeline_cache_test_limits(fixture.device,32768,65536,1,-1);
    require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"disk limit fixture");settle(fixture);
    dxmt_pipeline_cache_test_limits(fixture.device,32768,65536,512u*1024u*1024u,0);
    require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"free disk fixture");settle(fixture);
    NSDictionary *done=dxmt_pipeline_cache_test_stats(fixture.device);
    require([done[@"disk_limit_rejections"] unsignedIntValue]==1 && [done[@"disk_space_rejections"] unsignedIntValue]==1 && [done[@"io_failures"] unsignedIntValue]==0,@"quota/space/IO conflated");
    dxmt_pipeline_cache_test_limits(fixture.device,32768,65536,512u*1024u*1024u,-1);
    require(dxmt_pipeline_cache_test_recipe(fixture.device,r[@"key"],r[@"data"],1000),@"post-limit recovery");settle(fixture);
    require([dxmt_pipeline_cache_test_stats(fixture.device)[@"recipe_files"] unsignedIntValue]==2,@"capacity recovery failed");
    return @{@"limited":done,@"final":dxmt_pipeline_cache_test_stats(fixture.device)};
  }
  if([mode isEqualToString:@"byte_budget"]){
    for(unsigned i=0;i<6;++i)@autoreleasepool {
      NSMutableData *bytes=[NSMutableData dataWithLength:8u*1024u*1024u];((unsigned char *)bytes.mutableBytes)[0]=(unsigned char)i;
      unsigned char sha[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,sha);
      NSMutableString *key=[NSMutableString string];for(unsigned j=0;j<sizeof(sha);++j)[key appendFormat:@"%02x",sha[j]];
      BOOL accepted=dxmt_pipeline_cache_store_library(fixture.device,key,bytes);
      require(accepted==(i<5),@"40MiB combined queue bound failed");
    }
    NSDictionary *full=dxmt_pipeline_cache_test_stats(fixture.device);
    require([full[@"pending_bytes"] unsignedLongLongValue]==40u*1024u*1024u && [full[@"queue_bytes_full"] unsignedIntValue]>=1,@"byte accounting");
    dxmt_pipeline_cache_test_pause(fixture.device,NO);return @{@"full":full,@"final":settle(fixture)};
  }
  return nil;
}
#endif

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 4, @"usage: recorder_reliability_probe fixture.metallib nonce mode");
    RRFixture *fixture = loadFixture(@(argv[1]), @(argv[2]));
    NSString *mode = @(argv[3]);
    NSDictionary *result = nil;
    if ([mode isEqualToString:@"fixture"]) result = fixtureProof(fixture);
#ifdef DXMT_PIPELINE_CACHE_TESTING
    else result=stress(fixture,mode);
#endif
    require(result != nil, @"unknown reliability mode");
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    require(json != nil, @"report serialization");
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
  }
}
