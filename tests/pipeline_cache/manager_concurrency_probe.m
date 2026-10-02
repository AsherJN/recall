#define main unused_archive_probe_entry
#include "metal_archive_probe.m"
#undef main
#include "pipeline_recipe.h"
#include "pipeline_cache.h"
#include "../winemetal.h"
#include <pthread.h>
#include <stdatomic.h>

struct Shared {
  id<MTLDevice> device;
  id<MTLFunction> vertex, fragments[2];
  id<MTLRenderPipelineState> cached[2];
  unsigned red;
  atomic_uint identical, other, completed;
};
static id<MTLRenderPipelineState> pipeline(struct Shared *shared, unsigned which) {
  MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction=shared->vertex;descriptor.fragmentFunction=shared->fragments[which];
  descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
  struct WMTRenderPipelineInfo info={0};info.vertex_function=(obj_handle_t)shared->vertex;info.fragment_function=(obj_handle_t)shared->fragments[which];
  NSError *error=nil;
  id<MTLRenderPipelineState> state=dxmt_pipeline_cache_new_render_pipeline(shared->device,descriptor,&info,MTLPipelineOptionNone,&error);
  [descriptor release];
  require(state!=nil && error==nil,[NSString stringWithFormat:@"managed pipeline failure: %@",error]);
  return state; // Production API promises +1; every caller must release it.
}
static void *lookupThread(void *raw) {
  struct Shared *shared=raw;
  for(unsigned i=0;i<100;++i) @autoreleasepool {
    unsigned which=i%2;
    id<MTLRenderPipelineState> state=pipeline(shared,which);
    atomic_fetch_add(state==shared->cached[which] ? &shared->identical : &shared->other,1);
    if(i%25==0) checkPixels(shared->device,state,shared->red,which?153:64);
    [state release]; // Detect missing retained-return ownership during concurrent reuse.
    atomic_fetch_add(&shared->completed,1);
  }
  return NULL;
}
static void *shutdownThread(void *unused) {
  (void)unused;
  for(unsigned i=0;i<1000;++i)dxmt_pipeline_cache_shutdown();
  return NULL;
}
int main(int argc,const char **argv) { @autoreleasepool {
  require(argc==4,@"usage: concurrency fixture.metallib nonce mode");
  NSString *nonce=@(argv[2]),*mode=@(argv[3]);
  struct Shared shared={0};shared.red=32+strtoul(argv[2],NULL,16)%160;
  atomic_init(&shared.identical,0);atomic_init(&shared.other,0);atomic_init(&shared.completed,0);
  shared.device=MTLCreateSystemDefaultDevice();require(shared.device!=nil,@"Metal device");
  NSData *bytes=[NSData dataWithContentsOfFile:@(argv[1])];require(bytes!=nil,@"metallib fixture");
  dispatch_data_t data=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  NSError *error=nil;id<MTLLibrary> library=[shared.device newLibraryWithData:data error:&error];
  require(library!=nil && !error,@"fixture Metal library");
  require(dxmt_pipeline_cache_enabled(),@"cache enabled");
  id<MTLDevice> device=shared.device;
  require(dxmt_recipe_register_library(library,data,^BOOL(NSString *key,NSData *content){return dxmt_pipeline_cache_store_library(device,key,content);}),@"register library");
  NSString *vertexName=[@"vertex_" stringByAppendingString:nonce];
  shared.vertex=[library newFunctionWithName:vertexName];
  require(dxmt_recipe_register_function(shared.vertex,library,vertexName),@"register vertex");
  for(unsigned i=0;i<2;++i){
    NSString *name=[[i?@"alternate_":@"fragment_" stringByAppendingString:nonce] copy];
    shared.fragments[i]=[library newFunctionWithName:name];
    require(dxmt_recipe_register_function(shared.fragments[i],library,name),@"register fragment");[name release];
    shared.cached[i]=pipeline(&shared,i);checkPixels(shared.device,shared.cached[i],shared.red,i?153:64);
  }
  if([mode isEqualToString:@"owner"]){
    [NSThread sleepForTimeInterval:2.2];puts("READY");fflush(stdout);getchar();dxmt_pipeline_cache_shutdown();
    puts("{\"mode\":\"owner\",\"completed\":true}");return 0;
  }
  if([mode isEqualToString:@"lease"]){
    [NSThread sleepForTimeInterval:1.5];
    puts("{\"mode\":\"lease\",\"pixels_correct\":true}");dxmt_pipeline_cache_shutdown();return 0;
  }
  require([mode isEqualToString:@"concurrent"],@"unknown mode");
  pthread_t workers[4];
  for(unsigned i=0;i<4;++i)require(!pthread_create(&workers[i],NULL,lookupThread,&shared),@"lookup thread start");
  for(unsigned i=0;i<4;++i)pthread_join(workers[i],NULL);
  require(atomic_load(&shared.completed)==400 && atomic_load(&shared.identical)>0,@"concurrent cached lookups missing");
  unsigned before=atomic_load(&shared.completed);
  pthread_t stoppers[2];
  for(unsigned i=0;i<2;++i)require(!pthread_create(&stoppers[i],NULL,shutdownThread,NULL),@"shutdown thread start");
  dxmt_pipeline_cache_shutdown(); // Happens before thread creation: all following calls are definitely late.
  require(!dxmt_pipeline_cache_enabled(),@"admission remained active before late calls");
  for(unsigned i=0;i<4;++i)require(!pthread_create(&workers[i],NULL,lookupThread,&shared),@"late lookup start");
  for(unsigned i=0;i<2;++i)pthread_join(stoppers[i],NULL);
  for(unsigned i=0;i<4;++i)pthread_join(workers[i],NULL);
  require(!dxmt_pipeline_cache_enabled(),@"shutdown did not disable admission");
  require(atomic_load(&shared.completed)-before==400,@"late calls failed");
  // Retained references remain usable after all concurrent callers release theirs.
  checkPixels(shared.device,shared.cached[0],shared.red,64);checkPixels(shared.device,shared.cached[1],shared.red,153);
  [NSThread sleepForTimeInterval:1.2];
  NSDictionary *report=@{@"mode":mode,@"completed_lookups":@(atomic_load(&shared.completed)),
    @"same_cached_identity":@(atomic_load(&shared.identical)),@"different_pso_identity":@(atomic_load(&shared.other)),
    @"concurrent_shutdown_calls":@2000,@"post_shutdown_lookups":@400,@"two_recipes_pixel_correct":@YES};
  NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
  puts([[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding]autorelease].UTF8String);
  for(unsigned i=0;i<2;++i){[shared.cached[i]release];[shared.fragments[i]release];}
  [shared.vertex release];[library release];[shared.device release];dispatch_release(data);
  return 0;
}}
