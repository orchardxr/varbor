// Minimal native OpenXR app on XR_KHR_metal_enable: an MTLCommandQueue session, one side-by-side stereo swapchain,
// per eye a colour that cycles over time with a moving bar (right eye: hue shifted, bar mirrored), one projection
// layer per frame.
//   xr_metal [seconds]        (default 30)
// Prints the frame count, fps, xrWaitFrame/acquire stats and every error at exit; exit status 1 on any error.
#define XR_USE_GRAPHICS_API_METAL
#import <Metal/Metal.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static XrInstance instance = XR_NULL_HANDLE;
static int errors = 0;

static bool
xr_ok(XrResult r, const char *what)
{
	if (XR_SUCCEEDED(r)) {
		return true;
	}
	char s[XR_MAX_RESULT_STRING_SIZE] = "?";
	if (instance != XR_NULL_HANDLE) {
		xrResultToString(instance, r, s);
	}
	fprintf(stderr, "%s failed: %s (%d)\n", what, s, r);
	errors++;
	return false;
}

#define XR_CHECK(call)                                                                                                 \
	do {                                                                                                           \
		if (!xr_ok((call), #call)) {                                                                           \
			exit(1);                                                                                       \
		}                                                                                                      \
	} while (0)

static double
now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static NSString *const shader_src = @"#include <metal_stdlib>\n"
                                     "using namespace metal;\n"
                                     "struct P { float4 color; float bar; float mirror; };\n"
                                     "struct V { float4 pos [[position]]; float2 uv; };\n"
                                     "vertex V vs(uint id [[vertex_id]]) {\n"
                                     "  float2 p = float2((id << 1) & 2, id & 2);\n"
                                     "  V v; v.pos = float4(p * 2.0 - 1.0, 0, 1); v.uv = float2(p.x, 1.0 - p.y); return v;\n"
                                     "}\n"
                                     "fragment float4 fs(V v [[stage_in]], constant P &p [[buffer(0)]]) {\n"
                                     "  float x = p.mirror > 0.5 ? 1.0 - v.uv.x : v.uv.x;\n"
                                     "  float shade = 0.6 + 0.4 * v.uv.y;\n"
                                     "  if (fabs(x - p.bar) < 0.03) return float4(1, 1, 1, 1);\n"
                                     "  return float4(p.color.rgb * shade, 1);\n"
                                     "}\n";

struct params
{
	float color[4];
	float bar;
	float mirror;
};

static void
hue(float h, float out[4])
{
	for (int i = 0; i < 3; i++) {
		float k = fmodf(h * 6.0f + (float[]){0, 4, 2}[i], 6.0f);
		out[i] = 1.0f - fmaxf(0.0f, fminf(fminf(k, 4.0f - k), 1.0f));
	}
	out[3] = 1.0f;
}

int
main(int argc, char **argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 30.0;

	@autoreleasepool {
		const char *exts[] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME};
		XrInstanceCreateInfo ici = {
		    .type = XR_TYPE_INSTANCE_CREATE_INFO,
		    .applicationInfo = {.applicationName = "xr_metal", .apiVersion = XR_API_VERSION_1_0},
		    .enabledExtensionCount = 1,
		    .enabledExtensionNames = exts,
		};
		XR_CHECK(xrCreateInstance(&ici, &instance));

		XrInstanceProperties ip = {.type = XR_TYPE_INSTANCE_PROPERTIES};
		XR_CHECK(xrGetInstanceProperties(instance, &ip));
		printf("runtime: %s %u.%u.%u\n", ip.runtimeName, XR_VERSION_MAJOR(ip.runtimeVersion),
		       XR_VERSION_MINOR(ip.runtimeVersion), XR_VERSION_PATCH(ip.runtimeVersion));

		XrSystemGetInfo sgi = {.type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
		XrSystemId system;
		XR_CHECK(xrGetSystem(instance, &sgi, &system));

		PFN_xrGetMetalGraphicsRequirementsKHR get_reqs = NULL;
		XR_CHECK(xrGetInstanceProcAddr(instance, "xrGetMetalGraphicsRequirementsKHR",
		                               (PFN_xrVoidFunction *)&get_reqs));
		XrGraphicsRequirementsMetalKHR reqs = {.type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
		XR_CHECK(get_reqs(instance, system, &reqs));
		id<MTLDevice> device = (__bridge id<MTLDevice>)reqs.metalDevice;
		if (device == nil) {
			fprintf(stderr, "no metalDevice\n");
			return 1;
		}
		printf("device: %s\n", device.name.UTF8String);

		id<MTLCommandQueue> queue = [device newCommandQueue];
		NSError *err = nil;
		id<MTLLibrary> lib = [device newLibraryWithSource:shader_src options:nil error:&err];
		if (lib == nil) {
			fprintf(stderr, "shader: %s\n", err.localizedDescription.UTF8String);
			return 1;
		}

		XrGraphicsBindingMetalKHR binding = {
		    .type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR,
		    .commandQueue = (__bridge void *)queue,
		};
		XrSessionCreateInfo sci = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &binding, .systemId = system};
		XrSession session;
		XR_CHECK(xrCreateSession(instance, &sci, &session));

		XrViewConfigurationView vcv[2] = {{.type = XR_TYPE_VIEW_CONFIGURATION_VIEW},
		                                  {.type = XR_TYPE_VIEW_CONFIGURATION_VIEW}};
		uint32_t nviews = 0;
		XR_CHECK(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2,
		                                           &nviews, vcv));
		uint32_t w = vcv[0].recommendedImageRectWidth;
		uint32_t h = vcv[0].recommendedImageRectHeight;

		int64_t formats[64];
		uint32_t nformats = 0;
		XR_CHECK(xrEnumerateSwapchainFormats(session, 64, &nformats, formats));
		int64_t format = 0;
		printf("formats:");
		for (uint32_t i = 0; i < nformats; i++) {
			printf(" %lld", formats[i]);
			if (format == 0 && (formats[i] == MTLPixelFormatBGRA8Unorm_sRGB ||
			                    formats[i] == MTLPixelFormatRGBA8Unorm_sRGB)) {
				format = formats[i];
			}
		}
		printf("\n");
		if (format == 0) {
			fprintf(stderr, "no sRGB 8-bit format\n");
			return 1;
		}

		XrSwapchainCreateInfo swci = {
		    .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
		    .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT,
		    .format = format,
		    .sampleCount = 1,
		    .width = w * 2,
		    .height = h,
		    .faceCount = 1,
		    .arraySize = 1,
		    .mipCount = 1,
		};
		XrSwapchain swapchain;
		XR_CHECK(xrCreateSwapchain(session, &swci, &swapchain));

		uint32_t nimages = 0;
		XR_CHECK(xrEnumerateSwapchainImages(swapchain, 0, &nimages, NULL));
		XrSwapchainImageMetalKHR images[8];
		for (uint32_t i = 0; i < nimages; i++) {
			images[i] = (XrSwapchainImageMetalKHR){.type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
		}
		XR_CHECK(xrEnumerateSwapchainImages(swapchain, nimages, &nimages, (XrSwapchainImageBaseHeader *)images));
		id<MTLTexture> tex0 = (__bridge id<MTLTexture>)images[0].texture;
		printf("swapchain: %ux%u format %lld, %u images, texture %lux%lu iosurface %s\n", w * 2, h, format, nimages,
		       (unsigned long)tex0.width, (unsigned long)tex0.height, tex0.iosurface != NULL ? "yes" : "no");

		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [lib newFunctionWithName:@"vs"];
		pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
		pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)format;
		id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
		if (pipeline == nil) {
			fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String);
			return 1;
		}

		XrReferenceSpaceCreateInfo rsci = {
		    .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
		    .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL,
		    .poseInReferenceSpace = {.orientation = {.w = 1}},
		};
		XrSpace space;
		XR_CHECK(xrCreateReferenceSpace(session, &rsci, &space));

		bool running = false, quit = false;
		uint64_t frames = 0, rendered = 0;
		double start = 0, wait_total = 0, wait_max = 0, acquire_total = 0, acquire_max = 0;
		double t0 = now_s();

		while (!quit) {
			XrEventDataBuffer ev = {.type = XR_TYPE_EVENT_DATA_BUFFER};
			while (xrPollEvent(instance, &ev) == XR_SUCCESS) {
				if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
					XrSessionState st = ((XrEventDataSessionStateChanged *)&ev)->state;
					printf("%.2f s: session state %d\n", now_s() - t0, st);
					if (st == XR_SESSION_STATE_READY) {
						XrSessionBeginInfo sbi = {
						    .type = XR_TYPE_SESSION_BEGIN_INFO,
						    .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
						};
						XR_CHECK(xrBeginSession(session, &sbi));
						running = true;
						start = now_s();
					} else if (st == XR_SESSION_STATE_STOPPING) {
						xr_ok(xrEndSession(session), "xrEndSession");
						running = false;
						quit = true;
					} else if (st == XR_SESSION_STATE_EXITING || st == XR_SESSION_STATE_LOSS_PENDING) {
						running = false;
						quit = true;
					}
				}
				ev = (XrEventDataBuffer){.type = XR_TYPE_EVENT_DATA_BUFFER};
			}

			if (!running) {
				if (!quit && now_s() - t0 > 20) {
					fprintf(stderr, "session never became READY\n");
					errors++;
					quit = true;
				}
				struct timespec ts = {0, 10 * 1000 * 1000};
				nanosleep(&ts, NULL);
				continue;
			}

			if (now_s() - start > seconds) {
				xr_ok(xrRequestExitSession(session), "xrRequestExitSession");
				running = false;
				continue;
			}

			XrFrameState fs = {.type = XR_TYPE_FRAME_STATE};
			double tw = now_s();
			if (!xr_ok(xrWaitFrame(session, NULL, &fs), "xrWaitFrame")) {
				break;
			}
			tw = now_s() - tw;
			wait_total += tw;
			wait_max = fmax(wait_max, tw);
			if (!xr_ok(xrBeginFrame(session, NULL), "xrBeginFrame")) {
				break;
			}

			XrCompositionLayerProjectionView pv[2] = {{.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},
			                                          {.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
			XrCompositionLayerProjection layer = {
			    .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION,
			    .space = space,
			    .viewCount = 2,
			    .views = pv,
			};
			const XrCompositionLayerBaseHeader *layers[1] = {(XrCompositionLayerBaseHeader *)&layer};
			uint32_t nlayers = 0;

			if (fs.shouldRender) {
				XrView views[2] = {{.type = XR_TYPE_VIEW}, {.type = XR_TYPE_VIEW}};
				XrViewState vs = {.type = XR_TYPE_VIEW_STATE};
				XrViewLocateInfo vli = {
				    .type = XR_TYPE_VIEW_LOCATE_INFO,
				    .viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
				    .displayTime = fs.predictedDisplayTime,
				    .space = space,
				};
				uint32_t nv = 0;
				xr_ok(xrLocateViews(session, &vli, &vs, 2, &nv, views), "xrLocateViews");

				uint32_t index = 0;
				double ta = now_s();
				xr_ok(xrAcquireSwapchainImage(swapchain, NULL, &index), "xrAcquireSwapchainImage");
				XrSwapchainImageWaitInfo wi = {.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,
				                               .timeout = XR_INFINITE_DURATION};
				xr_ok(xrWaitSwapchainImage(swapchain, &wi), "xrWaitSwapchainImage");
				ta = now_s() - ta;
				acquire_total += ta;
				acquire_max = fmax(acquire_max, ta);

				id<MTLTexture> tex = (__bridge id<MTLTexture>)images[index].texture;
				MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
				rp.colorAttachments[0].texture = tex;
				rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
				rp.colorAttachments[0].storeAction = MTLStoreActionStore;

				id<MTLCommandBuffer> cb = [queue commandBuffer];
				id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
				[enc setRenderPipelineState:pipeline];
				double t = now_s() - start;
				for (int eye = 0; eye < 2; eye++) {
					struct params p = {.bar = (float)fmod(t * 0.25, 1.0), .mirror = (float)eye};
					hue((float)fmod(t * 0.1 + eye * 0.33, 1.0), p.color);
					[enc setViewport:(MTLViewport){eye * w, 0, w, h, 0, 1}];
					[enc setFragmentBytes:&p length:sizeof(p) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

					pv[eye].pose = views[eye].pose;
					pv[eye].fov = views[eye].fov;
					pv[eye].subImage.swapchain = swapchain;
					pv[eye].subImage.imageRect = (XrRect2Di){{(int32_t)(eye * w), 0}, {(int32_t)w, (int32_t)h}};
				}
				[enc endEncoding];
				[cb commit];

				xr_ok(xrReleaseSwapchainImage(swapchain, NULL), "xrReleaseSwapchainImage");
				nlayers = 1;
				rendered++;
			}

			XrFrameEndInfo fei = {
			    .type = XR_TYPE_FRAME_END_INFO,
			    .displayTime = fs.predictedDisplayTime,
			    .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
			    .layerCount = nlayers,
			    .layers = layers,
			};
			if (!xr_ok(xrEndFrame(session, &fei), "xrEndFrame")) {
				break;
			}
			frames++;
			if (frames % 300 == 0) {
				printf("%.1f s: %llu frames\n", now_s() - start, (unsigned long long)frames);
				fflush(stdout);
			}
		}

		double dur = start > 0 ? now_s() - start : 0;
		printf("frames %llu (rendered %llu) in %.1f s = %.1f fps; xrWaitFrame mean %.2f ms max %.2f ms; "
		       "acquire+wait mean %.3f ms max %.2f ms; errors %d\n",
		       (unsigned long long)frames, (unsigned long long)rendered, dur, dur > 0 ? frames / dur : 0,
		       frames ? wait_total / frames * 1e3 : 0, wait_max * 1e3,
		       rendered ? acquire_total / rendered * 1e3 : 0, acquire_max * 1e3, errors);

		xr_ok(xrDestroySpace(space), "xrDestroySpace");
		xr_ok(xrDestroySwapchain(swapchain), "xrDestroySwapchain");
		xr_ok(xrDestroySession(session), "xrDestroySession");
		xr_ok(xrDestroyInstance(instance), "xrDestroyInstance");
	}

	return errors ? 1 : 0;
}
