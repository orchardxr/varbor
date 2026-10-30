// Native macOS OpenVR scene app submitting Metal textures (vr::TextureType_Metal), the way a native macOS OpenVR game
// does. Loads <runtime>/bin/osx64/vrclient.dylib like openvr_api: dlopen, VRClientCoreFactory("IVRClientCore_003").
//   ovr_metal <runtime dir> [seconds] [mode]     (default 30 s, mode separate)
// Modes: separate  one RGBA8Unorm texture per eye, ColorSpace_Gamma (sRGB swapchain: blit through a format view)
//        sbs       one side-by-side BGRA8Unorm_sRGB texture, per-eye bounds, ColorSpace_Auto (blit of the bounds only)
//        array     one 2-slice RGBA8Unorm_sRGB array texture (slice = eye), ColorSpace_Linear (UNORM swapchain)
//        msaa      one 4x MSAA RGBA8Unorm texture per eye, ColorSpace_Gamma (resolved by OpenComposite's render pass)
// Per eye: a base colour (left red, right blue), a grid, a bar moving right (left) or left (right eye) and an
// eye-specific number of white squares in the top left (1 left, 2 right). Prints per-second stats and all errors;
// exit status 1 on any error.
#import <Metal/Metal.h>
#include <openvr.h>

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <string>

class IVRClientCore {
public:
	virtual vr::EVRInitError Init(vr::EVRApplicationType eApplicationType, const char* pStartupInfo) = 0;
	virtual void Cleanup() = 0;
	virtual vr::EVRInitError IsInterfaceVersionValid(const char* pchInterfaceVersion) = 0;
	virtual void* GetGenericInterface(const char* pchNameAndVersion, vr::EVRInitError* peError) = 0;
	virtual bool BIsHmdPresent() = 0;
	virtual const char* GetEnglishStringForHmdError(vr::EVRInitError eError) = 0;
	virtual const char* GetIDForVRInitError(vr::EVRInitError eError) = 0;
};
typedef void* (*VRClientCoreFactoryFn)(const char* pInterfaceName, int* pReturnCode);

static const char* const kShader = R"(
#include <metal_stdlib>
using namespace metal;

struct Params {
	uint eye;
	uint frame;
	float2 size;
	float2 offset;
};

vertex float4 vs(uint vid [[vertex_id]])
{
	float2 t = float2((vid << 1) & 2, vid & 2);
	return float4(t * float2(2, -2) + float2(-1, 1), 0, 1);
}

fragment float4 fs(float4 pos [[position]], constant Params& p [[buffer(0)]])
{
	float2 uv = (pos.xy - p.offset) / p.size;
	float3 c = p.eye == 0 ? float3(0.8, 0.1, 0.1) : float3(0.1, 0.2, 0.8);
	float2 g = fract(uv * 16);
	if (g.x < 0.04 || g.y < 0.04)
		c *= 0.5;
	float bar = fract(p.frame / 120.0);
	if (p.eye == 1)
		bar = 1 - bar;
	if (abs(uv.x - bar) < 0.02)
		c = float3(1, 1, 0);
	for (uint i = 0; i <= p.eye; i++) {
		float2 q = (uv - float2(0.1 + 0.12 * i, 0.1)) / 0.08;
		if (all(q >= 0) && all(q <= 1))
			c = float3(1);
	}
	return float4(c, 1);
}
)";

struct Params {
	uint32_t eye;
	uint32_t frame;
	float size[2];
	float offset[2];
};

static int errors = 0;

static double now()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <runtime dir> [seconds] [separate|sbs|array|msaa]\n", argv[0]);
		return 2;
	}
	std::string runtime = argv[1];
	double seconds = argc > 2 ? atof(argv[2]) : 30;
	std::string mode = argc > 3 ? argv[3] : "separate";

	std::string lib = runtime + "/bin/osx64/vrclient.dylib";
	void* dl = dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (!dl) {
		fprintf(stderr, "dlopen %s: %s\n", lib.c_str(), dlerror());
		return 1;
	}
	auto factory = (VRClientCoreFactoryFn)dlsym(dl, "VRClientCoreFactory");
	if (!factory) {
		fprintf(stderr, "no VRClientCoreFactory in %s\n", lib.c_str());
		return 1;
	}
	int rc = 0;
	auto core = (IVRClientCore*)factory("IVRClientCore_003", &rc);
	if (!core) {
		fprintf(stderr, "VRClientCoreFactory(IVRClientCore_003) failed: %d\n", rc);
		return 1;
	}
	vr::EVRInitError err = core->Init(vr::VRApplication_Scene, nullptr);
	if (err != vr::VRInitError_None) {
		fprintf(stderr, "Init failed: %s\n", core->GetEnglishStringForHmdError(err));
		return 1;
	}
	auto system = (vr::IVRSystem*)core->GetGenericInterface(vr::IVRSystem_Version, &err);
	if (!system) {
		fprintf(stderr, "%s: %d\n", vr::IVRSystem_Version, err);
		return 1;
	}
	auto compositor = (vr::IVRCompositor*)core->GetGenericInterface(vr::IVRCompositor_Version, &err);
	if (!compositor) {
		fprintf(stderr, "%s: %d\n", vr::IVRCompositor_Version, err);
		return 1;
	}

	uint32_t w = 0, h = 0;
	system->GetRecommendedRenderTargetSize(&w, &h);
	uint64_t outputDevice = 0;
	system->GetOutputDevice(&outputDevice, vr::TextureType_Metal);
	id<MTLDevice> device = outputDevice ? (__bridge id<MTLDevice>)(void*)outputDevice : MTLCreateSystemDefaultDevice();
	printf("runtime %s, mode %s, %ux%u per eye, device %s (output device %s)\n", lib.c_str(), mode.c_str(), w, h,
	    device.name.UTF8String, outputDevice ? "from GetOutputDevice" : "none");

	MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
	vr::EColorSpace colourSpace = vr::ColorSpace_Gamma;
	bool sbs = mode == "sbs", array = mode == "array", msaa = mode == "msaa";
	if (sbs) {
		format = MTLPixelFormatBGRA8Unorm_sRGB;
		colourSpace = vr::ColorSpace_Auto;
	} else if (array) {
		format = MTLPixelFormatRGBA8Unorm_sRGB;
		colourSpace = vr::ColorSpace_Linear;
	} else if (mode != "separate" && !msaa) {
		fprintf(stderr, "unknown mode %s\n", mode.c_str());
		return 2;
	}

	MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:sbs ? 2 * w : w height:h mipmapped:NO];
	desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModePrivate;
	if (array) {
		desc.textureType = MTLTextureType2DArray;
		desc.arrayLength = 2;
	} else if (msaa) {
		desc.textureType = MTLTextureType2DMultisample;
		desc.sampleCount = 4;
	}
	id<MTLTexture> textures[2];
	textures[0] = [device newTextureWithDescriptor:desc];
	textures[1] = (sbs || array) ? textures[0] : [device newTextureWithDescriptor:desc];

	NSError* error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:@(kShader) options:nil error:&error];
	if (!library) {
		fprintf(stderr, "shader: %s\n", error.localizedDescription.UTF8String);
		return 1;
	}
	MTLRenderPipelineDescriptor* pdesc = [MTLRenderPipelineDescriptor new];
	pdesc.vertexFunction = [library newFunctionWithName:@"vs"];
	pdesc.fragmentFunction = [library newFunctionWithName:@"fs"];
	pdesc.colorAttachments[0].pixelFormat = format;
	pdesc.rasterSampleCount = desc.sampleCount;
	id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pdesc error:&error];
	if (!pipeline) {
		fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String);
		return 1;
	}
	id<MTLCommandQueue> queue = [device newCommandQueue];

	vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
	uint32_t frames = 0, secFrames = 0, validPoses = 0;
	double start = now(), lastReport = start, waitTotal = 0;
	while (now() - start < seconds) {
		@autoreleasepool {
			double t0 = now();
			vr::EVRCompositorError cerr = compositor->WaitGetPoses(poses, vr::k_unMaxTrackedDeviceCount, nullptr, 0);
			waitTotal += now() - t0;
			if (cerr != vr::VRCompositorError_None) {
				fprintf(stderr, "frame %u: WaitGetPoses: %d\n", frames, cerr);
				errors++;
			}
			if (poses[vr::k_unTrackedDeviceIndex_Hmd].bPoseIsValid)
				validPoses++;

			id<MTLCommandBuffer> cmd = [queue commandBuffer];
			for (uint32_t eye = 0; eye < 2; eye++) {
				MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = textures[eye];
				pass.colorAttachments[0].slice = array ? eye : 0;
				pass.colorAttachments[0].loadAction = (sbs && eye == 1) ? MTLLoadActionLoad : MTLLoadActionClear;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
				Params p = { eye, frames, { (float)w, (float)h }, { sbs ? (float)(eye * w) : 0.0f, 0 } };
				if (sbs) {
					[enc setViewport:(MTLViewport){ (double)eye * w, 0, (double)w, (double)h, 0, 1 }];
					[enc setScissorRect:(MTLScissorRect){ eye * w, 0, w, h }];
				}
				[enc setRenderPipelineState:pipeline];
				[enc setFragmentBytes:&p length:sizeof(p) atIndex:0];
				[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				[enc endEncoding];
			}
			[cmd commit];

			for (uint32_t eye = 0; eye < 2; eye++) {
				vr::Texture_t tex = { (__bridge void*)textures[eye], vr::TextureType_Metal, colourSpace };
				vr::VRTextureBounds_t bounds = { 0, 0, 1, 1 };
				if (sbs) {
					bounds.uMin = eye * 0.5f;
					bounds.uMax = bounds.uMin + 0.5f;
				}
				cerr = compositor->Submit((vr::EVREye)eye, &tex, &bounds, vr::Submit_Default);
				if (cerr != vr::VRCompositorError_None) {
					fprintf(stderr, "frame %u: Submit(eye %u): %d\n", frames, eye, cerr);
					errors++;
				}
			}
			compositor->PostPresentHandoff();
			frames++;
			secFrames++;

			double t = now();
			if (t - lastReport >= 1) {
				printf("t=%.0fs frames %u (%.1f fps), hmd pose valid %u/%u, WaitGetPoses avg %.1f ms, errors %d\n", t - start,
				    frames, secFrames / (t - lastReport), validPoses, frames, 1000 * waitTotal / frames, errors);
				fflush(stdout);
				secFrames = 0;
				lastReport = t;
			}
		}
	}
	double total = now() - start;
	printf("done: %u frames in %.1f s (%.1f fps), hmd pose valid %u, errors %d\n", frames, total, frames / total, validPoses, errors);
	core->Cleanup();
	return errors ? 1 : 0;
}
