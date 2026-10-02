#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "pipeline_cache.h"

int main(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || !dxmt_pipeline_cache_enabled()) return 2;
    NSDictionary *result = dxmt_pipeline_cache_prepare_saved(device);
    if (!result) return 3;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (!data) return 4;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    dxmt_pipeline_cache_shutdown();
    return 0;
  }
}
