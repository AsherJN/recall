#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "pipeline_cache.h"

int main(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || !dxmt_pipeline_cache_enabled()) return 2;
    double began = CACurrentMediaTime();
    // Test-only join: the cache still runs the production game budget/policy,
    // unlike the offline preparation helper. Never invoked by gameplay.
    dxmt_pipeline_cache_test_drain(device);
    printf("{\"startup_ms\":%.3f}\n", (CACurrentMediaTime()-began)*1000);
    dxmt_pipeline_cache_shutdown();
    return 0;
  }
}
