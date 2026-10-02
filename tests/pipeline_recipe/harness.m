#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "pipeline_recipe.h"
#define WINEMETAL_API
#include "winemetal.h"
#include <assert.h>
#include <pthread.h>

static void check(BOOL value, const char *message) {
  if (!value) { fprintf(stderr, "FAIL %s\n", message); abort(); }
}

@interface RecipeFunction : NSObject {
  NSString *_name;
  MTLFunctionType _type;
}
- (id)initName:(NSString *)name type:(MTLFunctionType)type;
- (NSString *)name;
- (MTLFunctionType)functionType;
@end
@implementation RecipeFunction
- (id)initName:(NSString *)name type:(MTLFunctionType)type { self=[super init]; if(self){_name=[name copy];_type=type;}return self; }
- (NSString *)name { return _name; }
- (MTLFunctionType)functionType { return _type; }
- (void)dealloc { [_name release]; [super dealloc]; }
@end

@interface RecipeLibrary : NSObject
- (id)newFunctionWithName:(NSString *)name;
@end
@implementation RecipeLibrary
- (id)newFunctionWithName:(NSString *)name {
  if ([name isEqualToString:@"vertex_main"] || [name isEqualToString:@"vertex_other"])
    return [[RecipeFunction alloc] initName:name type:MTLFunctionTypeVertex];
  if ([name isEqualToString:@"fragment_main"])
    return [[RecipeFunction alloc] initName:name type:MTLFunctionTypeFragment];
  return nil;
}
@end
@interface RecipeDevice : NSObject { @public unsigned loads; }
- (id)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error;
@end
@implementation RecipeDevice
- (id)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
  (void)data; (void)error; ++loads; return [[RecipeLibrary alloc] init];
}
@end

static NSDictionary *recapture(MTLRenderPipelineDescriptor *descriptor, NSDictionary *original) {
  struct WMTRenderPipelineInfo info={0};
  info.vertex_function=(obj_handle_t)descriptor.vertexFunction;
  info.fragment_function=(obj_handle_t)descriptor.fragmentFunction;
  info.logic_operation_enabled=[original[@"logic_enabled"] unsignedIntValue];
  info.logic_operation=[original[@"logic_op"] unsignedIntValue];
  return dxmt_recipe_capture(&info, descriptor);
}

static NSUInteger roundtrip(id<MTLDevice> device, NSDictionary *recipe, NSMutableDictionary *libraries) {
  NSError *error=nil;
  NSData *data=dxmt_recipe_encode(recipe);
  check(data!=nil,"encode");
  NSDictionary *decoded=dxmt_recipe_decode(data);
  check(decoded!=nil,"decode");
  NSString *key=dxmt_recipe_key(recipe);
  check([key isEqualToString:dxmt_recipe_key(decoded)],"JSON changed canonical key");
  MTLRenderPipelineDescriptor *restored=dxmt_recipe_restore(device,decoded,^NSData *(NSString *digest){ return libraries[digest]; },&error);
  check(restored!=nil && error==nil,"restore");
  NSDictionary *again=recapture(restored,recipe);
  check(again!=nil,"recapture");
  check([key isEqualToString:dxmt_recipe_key(again)],"restored descriptor changed semantic recipe");
  [restored release];
  return data.length;
}

struct RaceContext { id library, function; dispatch_data_t data; MTLRenderPipelineDescriptor *descriptor; struct WMTRenderPipelineInfo info; };
static void *register_race(void *raw) {
  struct RaceContext *context=raw;
  for(unsigned i=0;i<2000;++i) @autoreleasepool {
    dxmt_recipe_forget_library(context->library);
    dxmt_recipe_register_library(context->library,context->data,^BOOL(NSString *digest,NSData *bytes){(void)digest;(void)bytes;return YES;});
    dxmt_recipe_forget_function(context->function);
    dxmt_recipe_register_function(context->function,context->library,@"vertex_main");
  }
  return NULL;
}
static void *capture_race(void *raw) {
  struct RaceContext *context=raw;
  for(unsigned i=0;i<2000;++i) @autoreleasepool {
    NSDictionary *recipe=dxmt_recipe_capture(&context->info,context->descriptor);
    if(recipe)check(dxmt_recipe_decode(dxmt_recipe_encode(recipe))!=nil,"concurrent metadata produced invalid recipe");
  }
  return NULL;
}

int main(void) { @autoreleasepool {
  NSMutableDictionary *libraries=[NSMutableDictionary dictionary];
  RecipeLibrary *library=[[[RecipeLibrary alloc] init] autorelease];
  NSData *bytes=[@"binary library with all bytes included 0123456789" dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_data_t input=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  __block NSUInteger store_calls=0;
  DXMTRecipeLibraryStore store=^BOOL(NSString *digest,NSData *data){ ++store_calls; libraries[digest]=data; return YES; };
  check(dxmt_recipe_register_library((id)library,input,store),"register binary library");
  RecipeFunction *vertex=[library newFunctionWithName:@"vertex_main"],*fragment=[library newFunctionWithName:@"fragment_main"];
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"vertex metadata");
  check(dxmt_recipe_register_function((id)fragment,(id)library,@"fragment_main"),"fragment metadata");
  MTLRenderPipelineDescriptor *descriptor=[[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  descriptor.vertexFunction=(id)vertex;descriptor.fragmentFunction=(id)fragment;
  descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
  descriptor.vertexBuffers[29].mutability=MTLMutabilityImmutable;
  descriptor.fragmentBuffers[30].mutability=MTLMutabilityImmutable;
  struct WMTRenderPipelineInfo info={0};info.vertex_function=(obj_handle_t)vertex;info.fragment_function=(obj_handle_t)fragment;
  NSDictionary *base=dxmt_recipe_capture(&info,descriptor);
  check(base!=nil,"capture standard pipeline");
  RecipeDevice *device=[[[RecipeDevice alloc] init] autorelease];
  NSUInteger size=roundtrip((id)device,base,libraries);
  check(size<DXMT_RECIPE_ENCODED_MAX_BYTES,"recipe size bound");
  NSString *basekey=dxmt_recipe_key(base);
  memset(info.padding,0xff,sizeof(info.padding));
  check([basekey isEqualToString:dxmt_recipe_key(dxmt_recipe_capture(&info,descriptor))],"padding changed identity");
  NSMutableDictionary *reordered=[NSMutableDictionary dictionary];
  for(NSString *key in [[[base allKeys] sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) reordered[key]=base[key];
  check([basekey isEqualToString:dxmt_recipe_key(reordered)],"dictionary insertion order changed identity");

  NSDictionary *alternatives=@{@"logic_enabled":@1,@"logic_op":@10,@"alpha_to_coverage":@1,@"alpha_to_one":@1,
    @"rasterization":@0,@"sample_count":@4,@"depth_format":@(MTLPixelFormatDepth32Float),@"stencil_format":@(MTLPixelFormatStencil8),
    @"primitive_topology":@3,@"tess_partition":@2,@"tess_factor_step":@3,@"tess_winding":@1,@"tess_max_factor":@32,
    @"tess_factor_scale":@1,@"tess_control_point_index":@2,@"indirect_commands":@1,@"vertex_amplification":@2,
    @"add_vertex_binary":@1,@"add_fragment_binary":@1,@"vertex_call_stack":@2,@"fragment_call_stack":@2,@"shader_validation":@1};
  unsigned mutations=0;
  for(NSString *key in alternatives) {
    NSMutableDictionary *changed=[[base mutableCopy] autorelease];changed[key]=alternatives[key];
    if([changed[key] isEqual:base[key]])continue;
    check(![basekey isEqualToString:dxmt_recipe_key(changed)],"scalar collision");
    roundtrip((id)device,changed,libraries);++mutations;
  }
  for(unsigned slot=0;slot<8;++slot) for(NSString *key in base[@"colors"][slot]) {
    NSMutableDictionary *changed=[[base mutableCopy] autorelease];
    NSMutableArray *colors=[[base[@"colors"] mutableCopy] autorelease];
    NSMutableDictionary *color=[[colors[slot] mutableCopy] autorelease];
    color[key]=[key isEqualToString:@"format"] ? @((unsigned)([color[key] unsignedIntValue]==MTLPixelFormatRGBA8Unorm ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm)) : @(([color[key] unsignedIntValue]+1)%([key isEqualToString:@"blend"] ? 2:([key isEqualToString:@"write_mask"]?16:([key hasSuffix:@"op"]?5:19))));
    colors[slot]=color;changed[@"colors"]=colors;
    check(![basekey isEqualToString:dxmt_recipe_key(changed)],"color collision");
    roundtrip((id)device,changed,libraries);++mutations;
  }
  for(NSString *stage in @[@"vertex_buffers",@"fragment_buffers"])for(unsigned slot=0;slot<31;++slot){
    NSMutableDictionary *changed=[[base mutableCopy] autorelease];NSMutableArray *buffers=[[base[stage] mutableCopy] autorelease];
    buffers[slot]=@(([buffers[slot] unsignedIntValue]+1)%3);changed[stage]=buffers;
    check(![basekey isEqualToString:dxmt_recipe_key(changed)],"buffer collision");roundtrip((id)device,changed,libraries);++mutations;
  }
  printf("PASS %u semantic mutations, exact descriptor round trips; canonical JSON %lu bytes\n",mutations,(unsigned long)size);

  RecipeFunction *other_vertex=[library newFunctionWithName:@"vertex_other"];
  check(dxmt_recipe_register_function((id)other_vertex,(id)library,@"vertex_other"),"alternate function registration");
  descriptor.vertexFunction=(id)other_vertex; info.vertex_function=(obj_handle_t)other_vertex;
  NSDictionary *renamed=dxmt_recipe_capture(&info,descriptor);
  check(renamed && ![basekey isEqualToString:dxmt_recipe_key(renamed)],"function name not part of identity");
  roundtrip((id)device,renamed,libraries);
  descriptor.vertexFunction=(id)vertex;info.vertex_function=(obj_handle_t)vertex;[other_vertex release];
  NSData *changed_bytes=[@"binary library with all bytes included 012345678X" dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_data_t changed_data=dispatch_data_create(changed_bytes.bytes,changed_bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  check(dxmt_recipe_register_library((id)library,changed_data,store),"changed library registration");
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"changed library function registration");
  NSDictionary *changed_library=dxmt_recipe_capture(&info,descriptor);
  check(changed_library && ![basekey isEqualToString:dxmt_recipe_key(changed_library)],"late library bytes not part of identity");
  roundtrip((id)device,changed_library,libraries);
  dispatch_release(changed_data);
  check(dxmt_recipe_register_library((id)library,input,store),"reset library registration");
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"reset function registration");
  descriptor.fragmentFunction=nil;info.fragment_function=0;
  NSDictionary *depth_only=dxmt_recipe_capture(&info,descriptor);check(depth_only && depth_only[@"fragment"]==[NSNull null],"fragment-less pipeline rejected");
  roundtrip((id)device,depth_only,libraries);
  descriptor.fragmentFunction=(id)fragment;info.fragment_function=(obj_handle_t)fragment;
  puts("PASS full library content/name identity and fragment-less round trip");

  for(NSString *key in base) {
    NSMutableDictionary *bad=[[base mutableCopy] autorelease];[bad removeObjectForKey:key];check(dxmt_recipe_encode(bad)==nil,"missing field accepted");
    bad=[[base mutableCopy] autorelease];bad[key]=@"wrong type";check(dxmt_recipe_encode(bad)==nil,"wrong type accepted");
  }
  NSMutableDictionary *bad=[[base mutableCopy] autorelease];bad[@"unknown"]=@1;check(dxmt_recipe_encode(bad)==nil,"extra field accepted");
  for(id value in @[@0,@(-1),@1.5,@(INFINITY),@YES,@9]) {bad=[[base mutableCopy] autorelease];bad[@"sample_count"]=value;check(dxmt_recipe_encode(bad)==nil,"invalid number accepted");}
  check(dxmt_recipe_decode([@"{incomplete" dataUsingEncoding:NSUTF8StringEncoding])==nil,"invalid JSON accepted");
  check(dxmt_recipe_decode([NSMutableData dataWithLength:DXMT_RECIPE_ENCODED_MAX_BYTES+1])==nil,"oversize JSON accepted");
  bad=[[base mutableCopy] autorelease];NSMutableDictionary *fn=[[base[@"vertex"] mutableCopy] autorelease];fn[@"sha256"]=base[@"fragment"][@"sha256"];bad[@"vertex"]=fn;check(dxmt_recipe_encode(bad)==nil,"function identity mismatch accepted");
  unsigned prior_loads=device->loads;NSError *error=nil;
  check(dxmt_recipe_restore((id)device,base,^NSData *(NSString *digest){(void)digest;return [@"corrupt" dataUsingEncoding:NSUTF8StringEncoding];},&error)==nil && error!=nil,"corrupt library restored");
  check(device->loads==prior_loads,"corrupt library reached Metal loader");
  check(dxmt_recipe_restore((id)device,base,^NSData *(NSString *digest){(void)digest;return nil;},&error)==nil,"missing library restored");
  puts("PASS strict schema, corrupt identity/library, missing and oversized data rejection");

  info.binary_archive_for_serialization=1;check(dxmt_recipe_capture(&info,descriptor)==nil,"archive side effect accepted");info.binary_archive_for_serialization=0;
  info.fail_on_binary_archive_miss=true;check(dxmt_recipe_capture(&info,descriptor)==nil,"archive failure contract accepted");info.fail_on_binary_archive_miss=false;
  info.num_binary_archives_for_lookup=1;check(dxmt_recipe_capture(&info,descriptor)==nil,"lookup archive accepted");info.num_binary_archives_for_lookup=0;
  descriptor.vertexDescriptor=[MTLVertexDescriptor vertexDescriptor];descriptor.vertexDescriptor.attributes[0].format=MTLVertexFormatFloat3;check(dxmt_recipe_capture(&info,descriptor)==nil,"unsupported vertex descriptor accepted");descriptor.vertexDescriptor=nil;
  dxmt_recipe_forget_function((id)vertex);check(dxmt_recipe_capture(&info,descriptor)==nil,"specialized function accepted");
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"restore function metadata");
  dxmt_recipe_forget_library((id)library);check(!dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"source-only library accepted");
  check(dxmt_recipe_capture(&info,descriptor)==nil,"unknown metadata accepted");
  check(dxmt_recipe_register_library((id)library,input,^BOOL(NSString *digest,NSData *data){(void)digest;(void)data;return NO;}),"rejected persistence disabled valid identity");
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"rejected persistence lost valid function metadata");
  check(dxmt_recipe_capture(&info,descriptor)!=nil,"rejected persistence prevented runtime recipe reuse");
  NSMutableData *oversize=[NSMutableData dataWithLength:DXMT_RECIPE_LIBRARY_MAX_BYTES+1];dispatch_data_t too_large=dispatch_data_create(oversize.bytes,oversize.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  NSUInteger before_calls=store_calls;check(!dxmt_recipe_register_library((id)library,too_large,store),"oversized library accepted");check(store_calls==before_calls,"oversized library queued bytes");dispatch_release(too_large);
  puts("PASS caller archive contracts, unsupported/cleared metadata and bounded persistence bypass");
  check(dxmt_recipe_register_library((id)library,input,store),"race library metadata");
  check(dxmt_recipe_register_function((id)vertex,(id)library,@"vertex_main"),"race function metadata");
  struct RaceContext race={(id)library,(id)vertex,input,descriptor,info};pthread_t writer,reader;
  check(pthread_create(&writer,NULL,register_race,&race)==0,"race writer creation");
  check(pthread_create(&reader,NULL,capture_race,&race)==0,"race reader creation");
  pthread_join(writer,NULL);pthread_join(reader,NULL);
  puts("PASS concurrent metadata revocation/re-registration and capture lifetime");
  [vertex release];[fragment release];dispatch_release(input);
  puts("PASS pipeline recipe codec");
}return 0;}
