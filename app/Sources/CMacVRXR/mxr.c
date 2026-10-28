#define XR_USE_GRAPHICS_API_VULKAN
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>

#include "mxr.h"

#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_QUADS 32
#define MAX_IMAGES 8

struct mxr
{
	char runtime[1024];
	uint32_t pw, ph;
	uint32_t linger_ms;
	mxr_log_fn logfn;

	pthread_t thread;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	bool quit;

	// shared, under lock
	uint8_t *page;      // pw*ph*4, swapchain byte order, linear-premultiplied sRGB
	bool bgr;           // page byte order is BGRA (else RGBA)
	bool dirty;
	mxr_quad quads[MAX_QUADS];
	uint32_t nquads;
	double last_quads_s;
	mxr_stats stats;

	// XR thread only
	void *lib;
	PFN_xrGetInstanceProcAddr gipa;
	XrInstance instance;
	XrSystemId system;
	XrSession session;
	XrSessionState state;
	bool running;
	bool exit_requested;
	bool has_color_scale;
	XrSpace space;
	XrSwapchain swapchain;
	int64_t sc_format;
	uint32_t nimages;
	VkImage images[MAX_IMAGES];
	bool have_image;
	double next_try_s;

	VkInstance vk_instance;
	VkPhysicalDevice phys;
	VkDevice device;
	VkQueue queue;
	uint32_t family;
	VkCommandPool pool;
	VkCommandBuffer cmd;
	VkFence fence;
	VkBuffer staging;
	VkDeviceMemory staging_mem;
	uint8_t *staging_ptr;
};

static uint8_t lut[256 * 256];
static pthread_once_t lut_once = PTHREAD_ONCE_INIT;

static void
lut_init(void)
{
	for (int a = 0; a < 256; a++) {
		for (int c = 0; c < 256; c++) {
			if (a == 0) {
				lut[c] = 0;
				continue;
			}
			double s = c > a ? 1.0 : (double)c / a;
			double l = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
			l *= a / 255.0;
			double e = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055;
			int v = (int)lround(e * 255);
			lut[a * 256 + c] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
		}
	}
}

static double
now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void
logf_(mxr *m, const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (m->logfn)
		m->logfn(buf);
	else
		fprintf(stderr, "mxr: %s\n", buf);
}

#define XRF(name) PFN_##name name = NULL; m->gipa(m->instance, #name, (PFN_xrVoidFunction *)&name)

static XrResult
xr_check(mxr *m, XrResult r, const char *what)
{
	if (XR_FAILED(r))
		logf_(m, "%s failed: %d", what, r);
	return r;
}

static bool
load_runtime(mxr *m)
{
	if (m->gipa)
		return true;
	m->lib = dlopen(m->runtime, RTLD_NOW | RTLD_LOCAL);
	if (!m->lib) {
		logf_(m, "dlopen %s: %s", m->runtime, dlerror());
		return false;
	}
	PFN_xrNegotiateLoaderRuntimeInterface negotiate =
	    (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(m->lib, "xrNegotiateLoaderRuntimeInterface");
	XrNegotiateLoaderInfo li = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof(li),
	                            1, XR_CURRENT_LOADER_RUNTIME_VERSION, XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 1, 0x3ff)};
	XrNegotiateRuntimeRequest rr = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof(rr)};
	XrResult r = negotiate ? negotiate(&li, &rr) : XR_ERROR_RUNTIME_UNAVAILABLE;
	if (XR_FAILED(r) || !rr.getInstanceProcAddr) {
		logf_(m, "%s: negotiation failed (%d)", m->runtime, r);
		return false;
	}
	m->gipa = rr.getInstanceProcAddr;
	return true;
}

static uint32_t
find_memory(VkPhysicalDevice phys, uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(phys, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	return UINT32_MAX;
}

static void
destroy_vulkan(mxr *m)
{
	if (m->device) {
		vkDeviceWaitIdle(m->device);
		if (m->staging_ptr)
			vkUnmapMemory(m->device, m->staging_mem);
		if (m->staging)
			vkDestroyBuffer(m->device, m->staging, NULL);
		if (m->staging_mem)
			vkFreeMemory(m->device, m->staging_mem, NULL);
		if (m->fence)
			vkDestroyFence(m->device, m->fence, NULL);
		if (m->pool)
			vkDestroyCommandPool(m->device, m->pool, NULL);
		vkDestroyDevice(m->device, NULL);
	}
	if (m->vk_instance)
		vkDestroyInstance(m->vk_instance, NULL);
	m->staging_ptr = NULL;
	m->staging = VK_NULL_HANDLE;
	m->staging_mem = VK_NULL_HANDLE;
	m->fence = VK_NULL_HANDLE;
	m->pool = VK_NULL_HANDLE;
	m->cmd = VK_NULL_HANDLE;
	m->device = VK_NULL_HANDLE;
	m->vk_instance = VK_NULL_HANDLE;
}

static void
destroy_session(mxr *m)
{
	if (m->swapchain) {
		XRF(xrDestroySwapchain);
		xrDestroySwapchain(m->swapchain);
	}
	if (m->space) {
		XRF(xrDestroySpace);
		xrDestroySpace(m->space);
	}
	if (m->session) {
		XRF(xrDestroySession);
		xrDestroySession(m->session);
	}
	m->swapchain = XR_NULL_HANDLE;
	m->space = XR_NULL_HANDLE;
	m->session = XR_NULL_HANDLE;
	m->running = false;
	m->exit_requested = false;
	m->have_image = false;
	m->nimages = 0;
	m->state = XR_SESSION_STATE_UNKNOWN;
}

static void
destroy_all(mxr *m)
{
	destroy_session(m);
	destroy_vulkan(m);
	if (m->instance) {
		XRF(xrDestroyInstance);
		xrDestroyInstance(m->instance);
		logf_(m, "instance destroyed");
	}
	m->instance = XR_NULL_HANDLE;
	pthread_mutex_lock(&m->lock);
	m->stats.session_running = 0;
	pthread_mutex_unlock(&m->lock);
}

static bool
create_instance(mxr *m)
{
	m->instance = XR_NULL_HANDLE;
	XRF(xrEnumerateInstanceExtensionProperties);
	XRF(xrCreateInstance);
	if (!xrEnumerateInstanceExtensionProperties || !xrCreateInstance)
		return false;
	uint32_t n = 0;
	if (XR_FAILED(xrEnumerateInstanceExtensionProperties(NULL, 0, &n, NULL)))
		return false;
	XrExtensionProperties *props = calloc(n, sizeof(*props));
	for (uint32_t i = 0; i < n; i++)
		props[i].type = XR_TYPE_EXTENSION_PROPERTIES;
	xrEnumerateInstanceExtensionProperties(NULL, n, &n, props);
	bool overlay = false, vk2 = false;
	m->has_color_scale = false;
	for (uint32_t i = 0; i < n; i++) {
		overlay |= strcmp(props[i].extensionName, XR_EXTX_OVERLAY_EXTENSION_NAME) == 0;
		vk2 |= strcmp(props[i].extensionName, XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME) == 0;
		m->has_color_scale |= strcmp(props[i].extensionName, XR_KHR_COMPOSITION_LAYER_COLOR_SCALE_BIAS_EXTENSION_NAME) == 0;
	}
	free(props);
	if (!overlay || !vk2) {
		logf_(m, "runtime lacks %s", !overlay ? "XR_EXTX_overlay" : "XR_KHR_vulkan_enable2");
		return false;
	}
	const char *exts[3] = {XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME, XR_EXTX_OVERLAY_EXTENSION_NAME,
	                       XR_KHR_COMPOSITION_LAYER_COLOR_SCALE_BIAS_EXTENSION_NAME};
	XrInstanceCreateInfo ici = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	    .applicationInfo = {.applicationName = "MacVR web overlays", .apiVersion = XR_API_VERSION_1_0},
	    .enabledExtensionCount = m->has_color_scale ? 3 : 2,
	    .enabledExtensionNames = exts,
	};
	strcpy(ici.applicationInfo.engineName, "macvr-webhelper");
	XrResult r = xrCreateInstance(&ici, &m->instance);
	if (XR_FAILED(r)) {
		m->instance = XR_NULL_HANDLE;
		return false;
	}
	XRF(xrGetSystem);
	XrSystemGetInfo sgi = {.type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
	if (XR_FAILED(xr_check(m, xrGetSystem(m->instance, &sgi, &m->system), "xrGetSystem"))) {
		destroy_all(m);
		return false;
	}
	logf_(m, "instance created (color_scale_bias %d)", m->has_color_scale);
	return true;
}

static bool
create_vulkan(mxr *m)
{
	XRF(xrGetVulkanGraphicsRequirements2KHR);
	XRF(xrCreateVulkanInstanceKHR);
	XRF(xrGetVulkanGraphicsDevice2KHR);
	XRF(xrCreateVulkanDeviceKHR);
	XrGraphicsRequirementsVulkan2KHR req = {.type = XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR};
	if (XR_FAILED(xr_check(m, xrGetVulkanGraphicsRequirements2KHR(m->instance, m->system, &req), "graphics requirements")))
		return false;

	const char *inst_exts[] = {"VK_KHR_portability_enumeration", "VK_KHR_get_physical_device_properties2"};
	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
	VkInstanceCreateInfo vici = {
	    .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
	    .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
	    .pApplicationInfo = &app,
	    .enabledExtensionCount = 2,
	    .ppEnabledExtensionNames = inst_exts,
	};
	XrVulkanInstanceCreateInfoKHR xvici = {
	    .type = XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR,
	    .systemId = m->system,
	    .pfnGetInstanceProcAddr = vkGetInstanceProcAddr,
	    .vulkanCreateInfo = &vici,
	};
	VkResult vr;
	if (XR_FAILED(xr_check(m, xrCreateVulkanInstanceKHR(m->instance, &xvici, &m->vk_instance, &vr), "vk instance")) ||
	    vr != VK_SUCCESS) {
		logf_(m, "vkCreateInstance %d", vr);
		m->vk_instance = VK_NULL_HANDLE;
		return false;
	}
	XrVulkanGraphicsDeviceGetInfoKHR gdi = {
	    .type = XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR, .systemId = m->system, .vulkanInstance = m->vk_instance};
	if (XR_FAILED(xr_check(m, xrGetVulkanGraphicsDevice2KHR(m->instance, &gdi, &m->phys), "vk physical device")))
		return false;

	uint32_t nq = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(m->phys, &nq, NULL);
	VkQueueFamilyProperties qp[16];
	nq = nq > 16 ? 16 : nq;
	vkGetPhysicalDeviceQueueFamilyProperties(m->phys, &nq, qp);
	m->family = 0;
	for (uint32_t i = 0; i < nq; i++) {
		if (qp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
			m->family = i;
			break;
		}
	}
	float prio = 1;
	VkDeviceQueueCreateInfo dqci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
	                                .queueFamilyIndex = m->family,
	                                .queueCount = 1,
	                                .pQueuePriorities = &prio};
	VkPhysicalDeviceTimelineSemaphoreFeatures tsf = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
	                                                 .timelineSemaphore = VK_TRUE};
	const char *dev_exts[] = {"VK_KHR_portability_subset", "VK_KHR_timeline_semaphore"};
	VkDeviceCreateInfo dci = {
	    .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
	    .pNext = &tsf,
	    .queueCreateInfoCount = 1,
	    .pQueueCreateInfos = &dqci,
	    .enabledExtensionCount = 2,
	    .ppEnabledExtensionNames = dev_exts,
	};
	XrVulkanDeviceCreateInfoKHR xvdci = {
	    .type = XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR,
	    .systemId = m->system,
	    .pfnGetInstanceProcAddr = vkGetInstanceProcAddr,
	    .vulkanPhysicalDevice = m->phys,
	    .vulkanCreateInfo = &dci,
	};
	if (XR_FAILED(xr_check(m, xrCreateVulkanDeviceKHR(m->instance, &xvdci, &m->device, &vr), "vk device")) ||
	    vr != VK_SUCCESS) {
		logf_(m, "vkCreateDevice %d", vr);
		m->device = VK_NULL_HANDLE;
		return false;
	}
	vkGetDeviceQueue(m->device, m->family, 0, &m->queue);

	VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	                                .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	                                .queueFamilyIndex = m->family};
	vkCreateCommandPool(m->device, &cpci, NULL, &m->pool);
	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
	                                    .commandPool = m->pool,
	                                    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
	                                    .commandBufferCount = 1};
	vkAllocateCommandBuffers(m->device, &cbai, &m->cmd);
	VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	vkCreateFence(m->device, &fci, NULL, &m->fence);

	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
	                          .size = (VkDeviceSize)m->pw * m->ph * 4,
	                          .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
	vkCreateBuffer(m->device, &bci, NULL, &m->staging);
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(m->device, m->staging, &mr);
	VkMemoryAllocateInfo mai = {
	    .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
	    .allocationSize = mr.size,
	    .memoryTypeIndex = find_memory(m->phys, mr.memoryTypeBits,
	                                   VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
	if (mai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(m->device, &mai, NULL, &m->staging_mem) != VK_SUCCESS)
		return false;
	vkBindBufferMemory(m->device, m->staging, m->staging_mem, 0);
	vkMapMemory(m->device, m->staging_mem, 0, bci.size, 0, (void **)&m->staging_ptr);
	return true;
}

static bool
create_session(mxr *m)
{
	if (!m->device && !create_vulkan(m))
		return false;
	XRF(xrCreateSession);
	XRF(xrCreateReferenceSpace);
	XRF(xrEnumerateSwapchainFormats);
	XRF(xrCreateSwapchain);
	XRF(xrEnumerateSwapchainImages);

	XrGraphicsBindingVulkan2KHR binding = {
	    .type = XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR,
	    .instance = m->vk_instance,
	    .physicalDevice = m->phys,
	    .device = m->device,
	    .queueFamilyIndex = m->family,
	    .queueIndex = 0,
	};
	XrSessionCreateInfoOverlayEXTX ov = {
	    .type = XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX,
	    .next = &binding,
	    .sessionLayersPlacement = 1,
	};
	XrSessionCreateInfo sci = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &ov, .systemId = m->system};
	if (XR_FAILED(xr_check(m, xrCreateSession(m->instance, &sci, &m->session), "xrCreateSession"))) {
		m->session = XR_NULL_HANDLE;
		return false;
	}
	XrReferenceSpaceCreateInfo rsci = {
	    .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
	    .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE,
	    .poseInReferenceSpace = {.orientation = {.w = 1}},
	};
	if (XR_FAILED(xr_check(m, xrCreateReferenceSpace(m->session, &rsci, &m->space), "STAGE space")))
		return false;

	int64_t formats[64];
	uint32_t nf = 0;
	xrEnumerateSwapchainFormats(m->session, 64, &nf, formats);
	m->sc_format = 0;
	for (uint32_t i = 0; i < nf && !m->sc_format; i++)
		if (formats[i] == VK_FORMAT_R8G8B8A8_SRGB || formats[i] == VK_FORMAT_B8G8R8A8_SRGB)
			m->sc_format = formats[i];
	if (!m->sc_format) {
		logf_(m, "no sRGB swapchain format");
		return false;
	}
	XrSwapchainCreateInfo swci = {
	    .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
	    .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT |
	                  XR_SWAPCHAIN_USAGE_SAMPLED_BIT,
	    .format = m->sc_format,
	    .sampleCount = 1,
	    .width = m->pw,
	    .height = m->ph,
	    .faceCount = 1,
	    .arraySize = 1,
	    .mipCount = 1,
	};
	if (XR_FAILED(xr_check(m, xrCreateSwapchain(m->session, &swci, &m->swapchain), "xrCreateSwapchain")))
		return false;
	XrSwapchainImageVulkan2KHR imgs[MAX_IMAGES];
	for (int i = 0; i < MAX_IMAGES; i++)
		imgs[i] = (XrSwapchainImageVulkan2KHR){.type = XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR};
	xrEnumerateSwapchainImages(m->swapchain, MAX_IMAGES, &m->nimages, (XrSwapchainImageBaseHeader *)imgs);
	for (uint32_t i = 0; i < m->nimages; i++)
		m->images[i] = imgs[i].image;

	bool bgr = m->sc_format == VK_FORMAT_B8G8R8A8_SRGB;
	pthread_mutex_lock(&m->lock);
	if (bgr != m->bgr) {
		for (size_t i = 0; i < (size_t)m->pw * m->ph; i++) {
			uint8_t t = m->page[i * 4];
			m->page[i * 4] = m->page[i * 4 + 2];
			m->page[i * 4 + 2] = t;
		}
		m->bgr = bgr;
	}
	m->dirty = true;
	m->stats.color_scale_bias = m->has_color_scale;
	pthread_mutex_unlock(&m->lock);
	logf_(m, "overlay session created: %ux%u swapchain format %lld, %u images", m->pw, m->ph,
	      (long long)m->sc_format, m->nimages);
	return true;
}

static void
barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to)
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

// Copies every quad's rect (plus a 1 px border for filtering) from the page into a new swapchain image.
static bool
produce_image(mxr *m, const mxr_quad *q, uint32_t n)
{
	XRF(xrAcquireSwapchainImage);
	XRF(xrWaitSwapchainImage);
	XRF(xrReleaseSwapchainImage);
	uint32_t idx;
	if (XR_FAILED(xr_check(m, xrAcquireSwapchainImage(m->swapchain, NULL, &idx), "acquire")))
		return false;
	XrSwapchainImageWaitInfo wi = {.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, .timeout = XR_INFINITE_DURATION};
	if (XR_FAILED(xr_check(m, xrWaitSwapchainImage(m->swapchain, &wi), "wait image")))
		return false;

	VkBufferImageCopy regions[MAX_QUADS];
	uint32_t nr = 0;
	pthread_mutex_lock(&m->lock);
	for (uint32_t i = 0; i < n; i++) {
		int32_t x0 = q[i].rect[0] - 1, y0 = q[i].rect[1] - 1;
		int32_t x1 = q[i].rect[0] + q[i].rect[2] + 1, y1 = q[i].rect[1] + q[i].rect[3] + 1;
		x0 = x0 < 0 ? 0 : x0;
		y0 = y0 < 0 ? 0 : y0;
		x1 = x1 > (int32_t)m->pw ? (int32_t)m->pw : x1;
		y1 = y1 > (int32_t)m->ph ? (int32_t)m->ph : y1;
		if (x1 <= x0 || y1 <= y0)
			continue;
		for (int32_t y = y0; y < y1; y++) {
			size_t o = ((size_t)y * m->pw + x0) * 4;
			memcpy(m->staging_ptr + o, m->page + o, (size_t)(x1 - x0) * 4);
		}
		regions[nr++] = (VkBufferImageCopy){
		    .bufferOffset = ((VkDeviceSize)y0 * m->pw + x0) * 4,
		    .bufferRowLength = m->pw,
		    .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
		    .imageOffset = {x0, y0, 0},
		    .imageExtent = {(uint32_t)(x1 - x0), (uint32_t)(y1 - y0), 1},
		};
	}
	m->dirty = false;
	pthread_mutex_unlock(&m->lock);

	VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	                                 .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	vkResetCommandBuffer(m->cmd, 0);
	vkBeginCommandBuffer(m->cmd, &cbbi);
	VkImage img = m->images[idx];
	barrier(m->cmd, img, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
	if (nr)
		vkCmdCopyBufferToImage(m->cmd, m->staging, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, nr, regions);
	barrier(m->cmd, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
	vkEndCommandBuffer(m->cmd);
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &m->cmd};
	vkQueueSubmit(m->queue, 1, &si, m->fence);
	double t0 = now_s();
	vkWaitForFences(m->device, 1, &m->fence, VK_TRUE, UINT64_MAX);
	vkResetFences(m->device, 1, &m->fence);
	double waited = (now_s() - t0) * 1e3;

	xr_check(m, xrReleaseSwapchainImage(m->swapchain, NULL), "release");
	m->have_image = true;
	pthread_mutex_lock(&m->lock);
	m->stats.images++;
	m->stats.copy_gpu_wait_ms += waited;
	pthread_mutex_unlock(&m->lock);
	return true;
}

static void
poll_events(mxr *m)
{
	XRF(xrPollEvent);
	XRF(xrBeginSession);
	XRF(xrEndSession);
	XrEventDataBuffer ev = {.type = XR_TYPE_EVENT_DATA_BUFFER};
	while (xrPollEvent(m->instance, &ev) == XR_SUCCESS) {
		if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
			XrEventDataSessionStateChanged *sc = (XrEventDataSessionStateChanged *)&ev;
			m->state = sc->state;
			if (sc->state == XR_SESSION_STATE_READY) {
				XrSessionBeginInfo sbi = {.type = XR_TYPE_SESSION_BEGIN_INFO,
				                          .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
				if (XR_SUCCEEDED(xr_check(m, xrBeginSession(m->session, &sbi), "xrBeginSession"))) {
					m->running = true;
					pthread_mutex_lock(&m->lock);
					m->stats.session_running = 1;
					pthread_mutex_unlock(&m->lock);
					logf_(m, "overlay session running");
				}
			} else if (sc->state == XR_SESSION_STATE_STOPPING) {
				xrEndSession(m->session);
				m->running = false;
			} else if (sc->state == XR_SESSION_STATE_EXITING || sc->state == XR_SESSION_STATE_LOSS_PENDING) {
				logf_(m, "session state %d: closing", sc->state);
				destroy_all(m);
				return;
			}
		} else if (ev.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
			logf_(m, "instance loss pending");
			destroy_all(m);
			return;
		}
		ev = (XrEventDataBuffer){.type = XR_TYPE_EVENT_DATA_BUFFER};
	}
}

static void
run_frame(mxr *m)
{
	XRF(xrWaitFrame);
	XRF(xrBeginFrame);
	XRF(xrEndFrame);
	XrFrameState fs = {.type = XR_TYPE_FRAME_STATE};
	XrResult r = xrWaitFrame(m->session, NULL, &fs);
	if (XR_FAILED(r)) {
		logf_(m, "xrWaitFrame %d: closing", r);
		destroy_all(m);
		return;
	}
	xrBeginFrame(m->session, NULL);

	mxr_quad q[MAX_QUADS];
	pthread_mutex_lock(&m->lock);
	uint32_t n = m->nquads;
	memcpy(q, m->quads, n * sizeof(*q));
	bool dirty = m->dirty;
	pthread_mutex_unlock(&m->lock);

	if (fs.shouldRender && n && (dirty || !m->have_image))
		produce_image(m, q, n);

	XrCompositionLayerQuad layers[MAX_QUADS];
	XrCompositionLayerColorScaleBiasKHR csb[MAX_QUADS];
	const XrCompositionLayerBaseHeader *lp[MAX_QUADS];
	uint32_t nl = 0;
	if (fs.shouldRender && m->have_image) {
		for (uint32_t i = 0; i < n; i++) {
			if (q[i].rect[2] <= 0 || q[i].rect[3] <= 0 || q[i].width <= 0 || q[i].height <= 0 ||
			    q[i].color_scale[3] <= 0)
				continue;
			layers[nl] = (XrCompositionLayerQuad){
			    .type = XR_TYPE_COMPOSITION_LAYER_QUAD,
			    .layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT,
			    .space = m->space,
			    .eyeVisibility = XR_EYE_VISIBILITY_BOTH,
			    .subImage = {.swapchain = m->swapchain,
			                 .imageRect = {{q[i].rect[0], q[i].rect[1]}, {q[i].rect[2], q[i].rect[3]}}},
			    .pose = {.orientation = {q[i].orientation[0], q[i].orientation[1], q[i].orientation[2],
			                             q[i].orientation[3]},
			             .position = {q[i].position[0], q[i].position[1], q[i].position[2]}},
			    .size = {q[i].width, q[i].height},
			};
			const float *s = q[i].color_scale;
			if (m->has_color_scale && (s[0] != 1 || s[1] != 1 || s[2] != 1 || s[3] != 1)) {
				csb[nl] = (XrCompositionLayerColorScaleBiasKHR){
				    .type = XR_TYPE_COMPOSITION_LAYER_COLOR_SCALE_BIAS_KHR,
				    .colorScale = {s[0], s[1], s[2], s[3]},
				};
				layers[nl].next = &csb[nl];
			}
			lp[nl] = (const XrCompositionLayerBaseHeader *)&layers[nl];
			nl++;
		}
	}
	XrFrameEndInfo fei = {
	    .type = XR_TYPE_FRAME_END_INFO,
	    .displayTime = fs.predictedDisplayTime,
	    .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
	    .layerCount = nl,
	    .layers = lp,
	};
	r = xrEndFrame(m->session, &fei);
	if (XR_FAILED(r))
		logf_(m, "xrEndFrame %d", r);
	pthread_mutex_lock(&m->lock);
	m->stats.frames++;
	pthread_mutex_unlock(&m->lock);
}

static void *
xr_thread(void *arg)
{
	mxr *m = arg;
	pthread_setname_np("mxr");
	for (;;) {
		pthread_mutex_lock(&m->lock);
		bool quit = m->quit;
		bool want = m->nquads > 0 || now_s() - m->last_quads_s < m->linger_ms / 1e3;
		if (!quit && !m->instance && !want) {
			pthread_cond_wait(&m->cond, &m->lock);
			pthread_mutex_unlock(&m->lock);
			continue;
		}
		pthread_mutex_unlock(&m->lock);
		if (quit)
			break;

		if (!m->instance) {
			if (now_s() < m->next_try_s || !load_runtime(m) || !create_instance(m)) {
				if (now_s() >= m->next_try_s)
					m->next_try_s = now_s() + 2;
				struct timespec ts = {0, 100 * 1000 * 1000};
				nanosleep(&ts, NULL);
				continue;
			}
		}
		if (!m->session) {
			if (!want) {
				destroy_all(m);
				continue;
			}
			if (!create_session(m)) {
				destroy_all(m);
				m->next_try_s = now_s() + 2;
				continue;
			}
		}
		poll_events(m);
		if (!m->instance)
			continue;
		if (!want && m->running && !m->exit_requested) {
			XRF(xrRequestExitSession);
			xrRequestExitSession(m->session);
			m->exit_requested = true;
		}
		if (m->running) {
			run_frame(m);
		} else if (m->state == XR_SESSION_STATE_IDLE && m->exit_requested) {
			logf_(m, "overlay session ended");
			destroy_all(m);
		} else {
			struct timespec ts = {0, 10 * 1000 * 1000};
			nanosleep(&ts, NULL);
		}
	}
	destroy_all(m);
	return NULL;
}

mxr *
mxr_create(const char *runtime, uint32_t page_width, uint32_t page_height, uint32_t linger_ms, mxr_log_fn log)
{
	pthread_once(&lut_once, lut_init);
	mxr *m = calloc(1, sizeof(*m));
	snprintf(m->runtime, sizeof(m->runtime), "%s", runtime);
	m->pw = page_width;
	m->ph = page_height;
	m->linger_ms = linger_ms;
	m->logfn = log;
	m->page = calloc((size_t)page_width * page_height, 4);
	m->bgr = false;
	pthread_mutex_init(&m->lock, NULL);
	pthread_cond_init(&m->cond, NULL);
	pthread_create(&m->thread, NULL, xr_thread, m);
	return m;
}

void
mxr_upload(mxr *m, int32_t x, int32_t y, int32_t w, int32_t h, const void *bgra, size_t stride)
{
	if (x < 0) {
		w += x;
		bgra = (const uint8_t *)bgra - x * 4;
		x = 0;
	}
	if (y < 0) {
		h += y;
		bgra = (const uint8_t *)bgra - (ptrdiff_t)y * stride;
		y = 0;
	}
	if (x + w > (int32_t)m->pw)
		w = (int32_t)m->pw - x;
	if (y + h > (int32_t)m->ph)
		h = (int32_t)m->ph - y;
	if (w <= 0 || h <= 0)
		return;
	double t0 = now_s();
	pthread_mutex_lock(&m->lock);
	int ri = m->bgr ? 2 : 0, bi = m->bgr ? 0 : 2;
	for (int32_t row = 0; row < h; row++) {
		const uint8_t *s = (const uint8_t *)bgra + (size_t)row * stride;
		uint8_t *d = m->page + ((size_t)(y + row) * m->pw + x) * 4;
		for (int32_t i = 0; i < w; i++, s += 4, d += 4) {
			const uint8_t *l = lut + s[3] * 256;
			d[bi] = l[s[0]];
			d[1] = l[s[1]];
			d[ri] = l[s[2]];
			d[3] = s[3];
		}
	}
	m->dirty = true;
	m->stats.uploads++;
	m->stats.upload_pixels += (uint64_t)w * h;
	m->stats.upload_cpu_ms += (now_s() - t0) * 1e3;
	pthread_mutex_unlock(&m->lock);
}

void
mxr_set_quads(mxr *m, const mxr_quad *quads, uint32_t n)
{
	if (n > MAX_QUADS)
		n = MAX_QUADS;
	pthread_mutex_lock(&m->lock);
	bool changed = n != m->nquads;
	for (uint32_t i = 0; i < n && !changed; i++)
		changed = memcmp(m->quads[i].rect, quads[i].rect, sizeof(quads[i].rect)) != 0;
	memcpy(m->quads, quads, n * sizeof(*quads));
	m->nquads = n;
	if (changed)
		m->dirty = true;
	if (n)
		m->last_quads_s = now_s();
	else if (changed)
		m->last_quads_s = now_s();
	pthread_cond_signal(&m->cond);
	pthread_mutex_unlock(&m->lock);
}

void
mxr_get_stats(mxr *m, mxr_stats *out)
{
	pthread_mutex_lock(&m->lock);
	*out = m->stats;
	pthread_mutex_unlock(&m->lock);
}

void
mxr_destroy(mxr *m)
{
	pthread_mutex_lock(&m->lock);
	m->quit = true;
	pthread_cond_signal(&m->cond);
	pthread_mutex_unlock(&m->lock);
	pthread_join(m->thread, NULL);
	if (m->lib)
		dlclose(m->lib);
	free(m->page);
	pthread_mutex_destroy(&m->lock);
	pthread_cond_destroy(&m->cond);
	free(m);
}
