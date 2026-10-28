// gpustress [secs] [threads log2] [sleep us] : compute dispatches, back to back or with a CPU sleep between them
// (does the GPU leave low P-states / does a light extra load change another app's GPU time)
#import <Metal/Metal.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	@autoreleasepool {
		id<MTLDevice> d = MTLCreateSystemDefaultDevice();
		NSString *src = @"kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
		                 " float x = i; for (int j = 0; j < 4000; j++) x = metal::fma(x, 1.0001f, 0.5f); o[i & 1023] = x; }";
		NSError *err = nil; id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err]; if (!lib) { NSLog(@"%@", err); return 1; }
		id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:nil];
		id<MTLBuffer> b = [d newBufferWithLength:4096 options:0];
		id<MTLCommandQueue> q = [d newCommandQueue];
		NSDate *end = [NSDate dateWithTimeIntervalSinceNow:argc > 1 ? atof(argv[1]) : 3];
		id<MTLCommandBuffer> last = nil;
		while ([end timeIntervalSinceNow] > 0) {
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
			[e setComputePipelineState:p];
			[e setBuffer:b offset:0 atIndex:0];
			[e dispatchThreads:MTLSizeMake(1 << (argc > 2 ? atoi(argv[2]) : 20), 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
			[e endEncoding];
			[cb commit];
			if (last) [last waitUntilCompleted];
			last = cb;
			if (argc > 3) usleep(atoi(argv[3]));
		}
		[last waitUntilCompleted];
		printf("gpu ms last cb %.2f\n", (last.GPUEndTime - last.GPUStartTime) * 1000);
	}
	return 0;
}
