// Minimal OpenXR Vulkan app that runs a session and submits frames with no layers (or one
// untouched projection layer with --swapchain). Used to drive WiVRn's compositor and encoders.
// --pattern [px]: a projection layer with a high-detail pattern that pans px (default 2) per frame,
// different per eye; the content of frame n only depends on n. With 0 it is static, so streams of
// two runs can be compared frame by frame (tests/wivrn/compare_streams.py).
//   xr_empty_frames [seconds] [--swapchain|--pattern [px]]
// Env XR_EMPTY_WORK_MS: sleep between xrBeginFrame and xrEndFrame (an app's frame work, OpenComposite-style),
// XR_EMPTY_GAP_MS: sleep after xrEndFrame. Prints the xrWaitFrame block and frame-interval distribution at exit.
#define XR_USE_GRAPHICS_API_VULKAN
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define XR_CHECK(call)                                                                  \
	do {                                                                            \
		XrResult r_ = (call);                                                   \
		if (XR_FAILED(r_)) {                                                    \
			char s_[XR_MAX_RESULT_STRING_SIZE];                             \
			xrResultToString(instance, r_, s_);                             \
			fprintf(stderr, "%s failed: %s (%d)\n", #call, s_, r_);         \
			exit(1);                                                        \
		}                                                                       \
	} while (0)

#define VK_CHECK(call)                                                                  \
	do {                                                                            \
		VkResult r_ = (call);                                                   \
		if (r_ != VK_SUCCESS) {                                                 \
			fprintf(stderr, "%s failed: %d\n", #call, r_);                  \
			exit(1);                                                        \
		}                                                                       \
	} while (0)

static XrInstance instance = XR_NULL_HANDLE;

static double
now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

#define PAN_RANGE 1024
#define EYE_SHIFT 24

struct pattern {
	VkDevice device;
	VkQueue queue;
	VkCommandPool pool;
	VkImage src;
	VkDeviceMemory src_mem;
	uint32_t width, height, n;
	VkImage images[8];
	VkCommandBuffer cmd[8];
	VkFence fence[8];
};

static uint32_t
find_memory(VkPhysicalDevice phys, uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(phys, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	fprintf(stderr, "no memory type\n");
	exit(1);
}

static uint8_t
noise(uint32_t x, uint32_t y)
{
	uint32_t h = x * 374761393u + y * 668265263u;
	h = (h ^ (h >> 13)) * 1274126177u;
	return (uint8_t)(h >> 24);
}

static void
cmd_barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to)
{
	VkImageMemoryBarrier b = {
	    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	    .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
	    .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
	    .oldLayout = from,
	    .newLayout = to,
	    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	    .image = img,
	    .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
	};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
	                     NULL, 1, &b);
}

// Source image (eye width + pan range + eye shift) x height, filled once on the CPU: sine plaid,
// a 3 px checkerboard, diagonal stripes and per-pixel noise.
static void
pattern_init(struct pattern *p, VkPhysicalDevice phys, VkDevice device, uint32_t family, XrSwapchain swapchain,
             uint32_t width, uint32_t height)
{
	p->device = device;
	p->width = width;
	p->height = height;
	vkGetDeviceQueue(device, family, 0, &p->queue);
	VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	                                .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	                                .queueFamilyIndex = family};
	VK_CHECK(vkCreateCommandPool(device, &cpci, NULL, &p->pool));

	XrSwapchainImageVulkan2KHR imgs[8];
	for (int i = 0; i < 8; i++)
		imgs[i] = (XrSwapchainImageVulkan2KHR){.type = XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR};
	XR_CHECK(xrEnumerateSwapchainImages(swapchain, 8, &p->n, (XrSwapchainImageBaseHeader *)imgs));
	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
	                                    .commandPool = p->pool,
	                                    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
	                                    .commandBufferCount = p->n};
	VK_CHECK(vkAllocateCommandBuffers(device, &cbai, p->cmd));
	for (uint32_t i = 0; i < p->n; i++) {
		p->images[i] = imgs[i].image;
		VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
		VK_CHECK(vkCreateFence(device, &fci, NULL, &p->fence[i]));
	}

	uint32_t sw = width + PAN_RANGE + EYE_SHIFT;
	VkImageCreateInfo ici = {
	    .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
	    .imageType = VK_IMAGE_TYPE_2D,
	    .format = VK_FORMAT_R8G8B8A8_SRGB,
	    .extent = {sw, height, 1},
	    .mipLevels = 1,
	    .arrayLayers = 1,
	    .samples = VK_SAMPLE_COUNT_1_BIT,
	    .tiling = VK_IMAGE_TILING_OPTIMAL,
	    .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
	};
	VK_CHECK(vkCreateImage(device, &ici, NULL, &p->src));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(device, p->src, &mr);
	VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
	                            .allocationSize = mr.size,
	                            .memoryTypeIndex = find_memory(phys, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
	VK_CHECK(vkAllocateMemory(device, &mai, NULL, &p->src_mem));
	VK_CHECK(vkBindImageMemory(device, p->src, p->src_mem, 0));

	VkDeviceSize size = (VkDeviceSize)sw * height * 4;
	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
	VkBuffer staging;
	VK_CHECK(vkCreateBuffer(device, &bci, NULL, &staging));
	vkGetBufferMemoryRequirements(device, staging, &mr);
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = find_memory(phys, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory staging_mem;
	VK_CHECK(vkAllocateMemory(device, &mai, NULL, &staging_mem));
	VK_CHECK(vkBindBufferMemory(device, staging, staging_mem, 0));
	uint8_t *px;
	VK_CHECK(vkMapMemory(device, staging_mem, 0, size, 0, (void **)&px));
	for (uint32_t y = 0; y < height; y++) {
		for (uint32_t x = 0; x < sw; x++) {
			uint8_t *o = px + ((size_t)y * sw + x) * 4;
			int n = noise(x, y) - 128;
			int checker = ((x / 3) ^ (y / 3)) & 1;
			int r = 128 + (int)(70 * sin(x * 0.07) * cos(y * 0.05)) + n / 3;
			int g = 50 + checker * 140 + n / 6;
			int b = ((x + 2 * y) / 5) % 2 ? 210 : 40;
			if ((x / 64 + y / 64) % 5 == 0)
				b = 128 + n / 2;
			o[0] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
			o[1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
			o[2] = (uint8_t)b;
			o[3] = 255;
		}
	}
	vkUnmapMemory(device, staging_mem);

	VkCommandBuffer cb = p->cmd[0];
	VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	                                 .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	VK_CHECK(vkBeginCommandBuffer(cb, &cbbi));
	cmd_barrier(cb, p->src, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
	VkBufferImageCopy bic = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {sw, height, 1}};
	vkCmdCopyBufferToImage(cb, staging, p->src, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bic);
	cmd_barrier(cb, p->src, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
	VK_CHECK(vkEndCommandBuffer(cb));
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	VK_CHECK(vkQueueSubmit(p->queue, 1, &si, VK_NULL_HANDLE));
	VK_CHECK(vkQueueWaitIdle(p->queue));
	vkDestroyBuffer(device, staging, NULL);
	vkFreeMemory(device, staging_mem, NULL);
	fprintf(stderr, "pattern %ux%u ready\n", sw, height);
}

static void
pattern_draw(struct pattern *p, uint32_t idx, uint64_t pan_px)
{
	VK_CHECK(vkWaitForFences(p->device, 1, &p->fence[idx], VK_TRUE, UINT64_MAX));
	VK_CHECK(vkResetFences(p->device, 1, &p->fence[idx]));
	VkCommandBuffer cb = p->cmd[idx];
	VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	                                 .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	VK_CHECK(vkBeginCommandBuffer(cb, &cbbi));
	cmd_barrier(cb, p->images[idx], VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
	int32_t pan = (int32_t)(pan_px % PAN_RANGE);
	VkImageCopy regions[2];
	for (int eye = 0; eye < 2; eye++)
		regions[eye] = (VkImageCopy){
		    .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
		    .srcOffset = {pan + (eye ? 0 : EYE_SHIFT), 0, 0},
		    .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
		    .dstOffset = {eye * (int32_t)p->width, 0, 0},
		    .extent = {p->width, p->height, 1},
		};
	vkCmdCopyImage(cb, p->src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, p->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, regions);
	cmd_barrier(cb, p->images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
	VK_CHECK(vkEndCommandBuffer(cb));
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	VK_CHECK(vkQueueSubmit(p->queue, 1, &si, p->fence[idx]));
}

static void
pattern_fini(struct pattern *p)
{
	vkDeviceWaitIdle(p->device);
	for (uint32_t i = 0; i < p->n; i++)
		vkDestroyFence(p->device, p->fence[i], NULL);
	vkDestroyCommandPool(p->device, p->pool, NULL);
	vkDestroyImage(p->device, p->src, NULL);
	vkFreeMemory(p->device, p->src_mem, NULL);
}

static int
cmp_float(const void *a, const void *b)
{
	float x = *(const float *)a, y = *(const float *)b;
	return (x > y) - (x < y);
}

int
main(int argc, char **argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 10;
	bool use_pattern = argc > 2 && strcmp(argv[2], "--pattern") == 0;
	bool use_swapchain = use_pattern || (argc > 2 && strcmp(argv[2], "--swapchain") == 0);
	int pan_speed = use_pattern && argc > 3 ? atoi(argv[3]) : 2;

	const char *exts[] = {XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME};
	XrInstanceCreateInfo ici = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	    .applicationInfo = {.applicationName = "xr_empty_frames", .apiVersion = XR_API_VERSION_1_0},
	    .enabledExtensionCount = 1,
	    .enabledExtensionNames = exts,
	};
	XR_CHECK(xrCreateInstance(&ici, &instance));

	XrSystemGetInfo sgi = {.type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
	XrSystemId system;
	XR_CHECK(xrGetSystem(instance, &sgi, &system));

	PFN_xrGetVulkanGraphicsRequirements2KHR getReq;
	PFN_xrCreateVulkanInstanceKHR createVkInstance;
	PFN_xrGetVulkanGraphicsDevice2KHR getVkDevice;
	PFN_xrCreateVulkanDeviceKHR createVkDevice;
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrGetVulkanGraphicsRequirements2KHR", (PFN_xrVoidFunction *)&getReq));
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrCreateVulkanInstanceKHR", (PFN_xrVoidFunction *)&createVkInstance));
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrGetVulkanGraphicsDevice2KHR", (PFN_xrVoidFunction *)&getVkDevice));
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrCreateVulkanDeviceKHR", (PFN_xrVoidFunction *)&createVkDevice));

	XrGraphicsRequirementsVulkan2KHR req = {.type = XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR};
	XR_CHECK(getReq(instance, system, &req));

	const char *vk_inst_exts[] = {"VK_KHR_portability_enumeration", "VK_KHR_get_physical_device_properties2"};
	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
	VkInstanceCreateInfo vici = {
	    .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
	    .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
	    .pApplicationInfo = &app,
	    .enabledExtensionCount = 2,
	    .ppEnabledExtensionNames = vk_inst_exts,
	};
	XrVulkanInstanceCreateInfoKHR xvici = {
	    .type = XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR,
	    .systemId = system,
	    .pfnGetInstanceProcAddr = vkGetInstanceProcAddr,
	    .vulkanCreateInfo = &vici,
	};
	VkInstance vk_instance;
	VkResult vr;
	XR_CHECK(createVkInstance(instance, &xvici, &vk_instance, &vr));
	VK_CHECK(vr);

	XrVulkanGraphicsDeviceGetInfoKHR gdi = {
	    .type = XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR, .systemId = system, .vulkanInstance = vk_instance};
	VkPhysicalDevice phys;
	XR_CHECK(getVkDevice(instance, &gdi, &phys));

	uint32_t nq = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, NULL);
	VkQueueFamilyProperties qp[16];
	nq = nq > 16 ? 16 : nq;
	vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qp);
	uint32_t family = 0;
	for (uint32_t i = 0; i < nq; i++) {
		if (qp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
			family = i;
			break;
		}
	}
	float prio = 1;
	VkDeviceQueueCreateInfo dqci = {
	    .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &prio};
	const char *vk_dev_exts[] = {"VK_KHR_portability_subset"};
	VkDeviceCreateInfo dci = {
	    .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
	    .queueCreateInfoCount = 1,
	    .pQueueCreateInfos = &dqci,
	    .enabledExtensionCount = 1,
	    .ppEnabledExtensionNames = vk_dev_exts,
	};
	XrVulkanDeviceCreateInfoKHR xvdci = {
	    .type = XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR,
	    .systemId = system,
	    .pfnGetInstanceProcAddr = vkGetInstanceProcAddr,
	    .vulkanPhysicalDevice = phys,
	    .vulkanCreateInfo = &dci,
	};
	VkDevice device;
	XR_CHECK(createVkDevice(instance, &xvdci, &device, &vr));
	VK_CHECK(vr);

	XrGraphicsBindingVulkan2KHR binding = {
	    .type = XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR,
	    .instance = vk_instance,
	    .physicalDevice = phys,
	    .device = device,
	    .queueFamilyIndex = family,
	    .queueIndex = 0,
	};
	XrSessionCreateInfo sci = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &binding, .systemId = system};
	XrSession session;
	XR_CHECK(xrCreateSession(instance, &sci, &session));

	XrReferenceSpaceCreateInfo rsci = {
	    .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
	    .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL,
	    .poseInReferenceSpace = {.orientation = {.w = 1}},
	};
	XrSpace space;
	XR_CHECK(xrCreateReferenceSpace(session, &rsci, &space));

	XrSwapchain swapchain = XR_NULL_HANDLE;
	uint32_t width = 0, height = 0;
	struct pattern pat = {0};
	if (use_swapchain) {
		XrViewConfigurationView views[2] = {{.type = XR_TYPE_VIEW_CONFIGURATION_VIEW}, {.type = XR_TYPE_VIEW_CONFIGURATION_VIEW}};
		uint32_t nv;
		XR_CHECK(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, views));
		width = views[0].recommendedImageRectWidth;
		height = views[0].recommendedImageRectHeight;
		// --pattern: one double-width swapchain, left eye in the left half
		uint32_t sc_width = use_pattern ? 2 * width : width;
		XrSwapchainCreateInfo swci = {
		    .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
		    .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT,
		    .format = VK_FORMAT_R8G8B8A8_SRGB,
		    .sampleCount = 1,
		    .width = sc_width,
		    .height = height,
		    .faceCount = 1,
		    .arraySize = 1,
		    .mipCount = 1,
		};
		XR_CHECK(xrCreateSwapchain(session, &swci, &swapchain));
		fprintf(stderr, "swapchain %ux%u created\n", sc_width, height);
		if (use_pattern)
			pattern_init(&pat, phys, device, family, swapchain, width, height);
	}

	double work_ms = getenv("XR_EMPTY_WORK_MS") ? atof(getenv("XR_EMPTY_WORK_MS")) : 0;
	double gap_ms = getenv("XR_EMPTY_GAP_MS") ? atof(getenv("XR_EMPTY_GAP_MS")) : 0;
	enum { MAXF = 20000 };
	static float waits[MAXF], intervals[MAXF];
	uint32_t nstat = 0;
	double last_wake = 0;

	bool running = false, quit = false;
	double start = now_s();
	uint64_t frames = 0;
	while (!quit) {
		XrEventDataBuffer ev = {.type = XR_TYPE_EVENT_DATA_BUFFER};
		while (xrPollEvent(instance, &ev) == XR_SUCCESS) {
			if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
				XrSessionState st = ((XrEventDataSessionStateChanged *)&ev)->state;
				fprintf(stderr, "session state %d\n", st);
				if (st == XR_SESSION_STATE_READY) {
					XrSessionBeginInfo sbi = {
					    .type = XR_TYPE_SESSION_BEGIN_INFO,
					    .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
					XR_CHECK(xrBeginSession(session, &sbi));
					running = true;
				} else if (st == XR_SESSION_STATE_STOPPING) {
					XR_CHECK(xrEndSession(session));
					running = false;
					quit = true;
				} else if (st == XR_SESSION_STATE_EXITING || st == XR_SESSION_STATE_LOSS_PENDING) {
					quit = true;
				}
			}
			ev = (XrEventDataBuffer){.type = XR_TYPE_EVENT_DATA_BUFFER};
		}
		if (now_s() - start > seconds) {
			if (running)
				XR_CHECK(xrRequestExitSession(session));
			else
				quit = true;
			start = 1e30;
		}
		if (!running) {
			struct timespec ts = {0, 10000000};
			nanosleep(&ts, NULL);
			continue;
		}

		XrFrameState fs = {.type = XR_TYPE_FRAME_STATE};
		double t0 = now_s();
		XR_CHECK(xrWaitFrame(session, NULL, &fs));
		double t1 = now_s();
		if (last_wake > 0 && nstat < MAXF && frames > 72) {
			waits[nstat] = (t1 - t0) * 1e3;
			intervals[nstat++] = (t1 - last_wake) * 1e3;
		}
		last_wake = t1;
		XR_CHECK(xrBeginFrame(session, NULL));
		if (work_ms > 0) {
			struct timespec ts = {0, (long)(work_ms * 1e6)};
			nanosleep(&ts, NULL);
		}

		XrCompositionLayerProjectionView pv[2];
		XrCompositionLayerProjection proj;
		const XrCompositionLayerBaseHeader *layers[1];
		uint32_t layer_count = 0;
		if (swapchain != XR_NULL_HANDLE && fs.shouldRender) {
			uint32_t idx;
			XR_CHECK(xrAcquireSwapchainImage(swapchain, NULL, &idx));
			XrSwapchainImageWaitInfo wi = {.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, .timeout = XR_INFINITE_DURATION};
			XR_CHECK(xrWaitSwapchainImage(swapchain, &wi));
			if (use_pattern)
				pattern_draw(&pat, idx, frames * pan_speed);
			XR_CHECK(xrReleaseSwapchainImage(swapchain, NULL));

			XrViewLocateInfo vli = {
			    .type = XR_TYPE_VIEW_LOCATE_INFO,
			    .viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
			    .displayTime = fs.predictedDisplayTime,
			    .space = space};
			XrViewState vs = {.type = XR_TYPE_VIEW_STATE};
			XrView v[2] = {{.type = XR_TYPE_VIEW}, {.type = XR_TYPE_VIEW}};
			uint32_t nv;
			XR_CHECK(xrLocateViews(session, &vli, &vs, 2, &nv, v));
			for (int i = 0; i < 2; i++) {
				pv[i] = (XrCompositionLayerProjectionView){
				    .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW,
				    .pose = v[i].pose,
				    .fov = v[i].fov,
				    .subImage = {.swapchain = swapchain,
				                 .imageRect = {.offset = {use_pattern ? i * (int32_t)width : 0, 0},
				                               .extent = {(int32_t)width, (int32_t)height}}},
				};
			}
			proj = (XrCompositionLayerProjection){
			    .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION, .space = space, .viewCount = 2, .views = pv};
			layers[0] = (const XrCompositionLayerBaseHeader *)&proj;
			layer_count = 1;
		}

		XrFrameEndInfo fei = {
		    .type = XR_TYPE_FRAME_END_INFO,
		    .displayTime = fs.predictedDisplayTime,
		    .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
		    .layerCount = layer_count,
		    .layers = layers,
		};
		XR_CHECK(xrEndFrame(session, &fei));
		frames++;
		if (gap_ms > 0) {
			struct timespec ts = {0, (long)(gap_ms * 1e6)};
			nanosleep(&ts, NULL);
		}
	}
	fprintf(stderr, "frames submitted: %llu\n", (unsigned long long)frames);
	if (nstat > 10) {
		double sum = 0;
		uint32_t over20 = 0, wait_over20 = 0;
		for (uint32_t i = 0; i < nstat; i++) {
			sum += intervals[i];
			over20 += intervals[i] > 20;
			wait_over20 += waits[i] > 20;
		}
		qsort(waits, nstat, sizeof(float), cmp_float);
		qsort(intervals, nstat, sizeof(float), cmp_float);
		fprintf(stderr,
		        "stats: %u frames, fps %.1f, interval p50 %.2f p99 %.2f max %.2f, >20ms %u; "
		        "wait p10 %.2f p50 %.2f p90 %.2f p99 %.2f max %.2f, >20ms %u\n",
		        nstat, nstat / (sum / 1e3), intervals[nstat / 2], intervals[nstat * 99 / 100], intervals[nstat - 1],
		        over20, waits[nstat / 10], waits[nstat / 2], waits[nstat * 9 / 10], waits[nstat * 99 / 100],
		        waits[nstat - 1], wait_over20);
	}

	if (use_pattern)
		pattern_fini(&pat);
	if (swapchain != XR_NULL_HANDLE)
		xrDestroySwapchain(swapchain);
	xrDestroySpace(space);
	xrDestroySession(session);
	xrDestroyInstance(instance);
	vkDestroyDevice(device, NULL);
	vkDestroyInstance(vk_instance, NULL);
	return 0;
}
