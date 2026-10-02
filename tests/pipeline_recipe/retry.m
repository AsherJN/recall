#define main codec_original_main
#include "harness.m"
#undef main
#include <stdatomic.h>
#include <unistd.h>

struct RetryRace { struct RaceContext capture; atomic_uint calls, active, overlapping; atomic_bool accept; };
static void *retry_capture_thread(void *raw) {
  struct RetryRace *r = raw;
  for (unsigned i=0;i<100;++i) @autoreleasepool {
    check(dxmt_recipe_capture(&r->capture.info,r->capture.descriptor)!=nil,"retry changed capture eligibility");
  }
  return NULL;
}
int main(void) { @autoreleasepool {
  NSData *bytes=[@"retry binary fixture" dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_data_t input=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  struct RetryRace race={0}; struct RetryRace *r=&race;
  atomic_init(&r->calls,0);atomic_init(&r->active,0);atomic_init(&r->overlapping,0);atomic_init(&r->accept,false);
  RecipeLibrary *library=[RecipeLibrary new];
  check(dxmt_recipe_register_library((id)library,input,^BOOL(NSString *key,NSData *data){
    check(key.length==64 && [data isEqualToData:bytes],"retry identity/content changed");
    atomic_fetch_add(&r->calls,1);
    if(atomic_fetch_add(&r->active,1))atomic_fetch_add(&r->overlapping,1);
    BOOL accepted=atomic_load(&r->accept);if(accepted)usleep(3000);
    atomic_fetch_sub(&r->active,1);return accepted;
  }),"initial rejected identity");
  id vertex=[library newFunctionWithName:@"vertex_main"],fragment=[library newFunctionWithName:@"fragment_main"];
  check(dxmt_recipe_register_function(vertex,(id)library,@"vertex_main"),"retry vertex");
  check(dxmt_recipe_register_function(fragment,(id)library,@"fragment_main"),"retry fragment");
  MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction=vertex;descriptor.fragmentFunction=fragment;descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
  r->capture.descriptor=descriptor;r->capture.info.vertex_function=(obj_handle_t)vertex;r->capture.info.fragment_function=(obj_handle_t)fragment;
  NSString *before=[dxmt_recipe_key(dxmt_recipe_capture(&r->capture.info,descriptor)) copy];
  [library release]; // The functions must keep the bounded retry payload alive.
  check([dxmt_recipe_retry_stats()[@"packets"] unsignedIntValue]==1,"shared packet/lifetime reservation");
  atomic_store(&r->accept,true);
  pthread_t threads[4];for(unsigned i=0;i<4;++i)check(!pthread_create(&threads[i],NULL,retry_capture_thread,r),"thread start");
  for(unsigned i=0;i<4;++i)pthread_join(threads[i],NULL);
  check(atomic_load(&r->overlapping)==0,"retry callbacks overlapped");
  check([dxmt_recipe_retry_stats()[@"reserved_bytes"] unsignedLongLongValue]==0,"accepted retry retained AIR");
  check([before isEqualToString:dxmt_recipe_key(dxmt_recipe_capture(&r->capture.info,descriptor))],"retry changed canonical key");
  [before release];[descriptor release];[vertex release];[fragment release];
  puts("PASS concurrent retry, shared function lifetime and immediate payload release");

  NSMutableArray *held=[NSMutableArray new];
  for(unsigned i=0;i<1025;++i) @autoreleasepool {
    RecipeLibrary *item=[RecipeLibrary new];
    check(dxmt_recipe_register_library((id)item,input,^BOOL(NSString *key,NSData *data){(void)key;(void)data;return NO;}),"bounded packet identity");
    [held addObject:item];[item release];
  }
  NSDictionary *stats=dxmt_recipe_retry_stats();
  check([stats[@"packets"] unsignedIntValue]==1024 && [stats[@"rejected_packets"] unsignedIntValue]>0,"packet cap not enforced");
  [held removeAllObjects];
  check([dxmt_recipe_retry_stats()[@"reserved_bytes"] unsignedLongLongValue]==0,"abandoned packet reservation leak");
  NSData *large=[NSMutableData dataWithLength:DXMT_RECIPE_LIBRARY_MAX_BYTES];
  dispatch_data_t largeInput=dispatch_data_create(large.bytes,large.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  for(unsigned i=0;i<5;++i) @autoreleasepool {
    RecipeLibrary *item=[RecipeLibrary new];
    check(dxmt_recipe_register_library((id)item,largeInput,^BOOL(NSString *key,NSData *data){(void)key;(void)data;return NO;}),"bounded bytes identity");
    [held addObject:item];[item release];
  }
  stats=dxmt_recipe_retry_stats();
  check([stats[@"reserved_bytes"] unsignedLongLongValue]==32u*1024u*1024u && [stats[@"rejected_bytes"] unsignedIntValue]>0,"byte cap not enforced");
  [held removeAllObjects];[held release];dispatch_release(largeInput);dispatch_release(input);
  check([dxmt_recipe_retry_stats()[@"reserved_bytes"] unsignedLongLongValue]==0,"byte reservation leak");
  puts("PASS independent32MiB/1024-packet caps and teardown reclamation");
  return 0;
}}
