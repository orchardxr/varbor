// xr_refresh [hz] : print the WiVRn view size and refresh rates; with hz, request that display refresh rate
// (XR_FB_display_refresh_rate) from a short overlay session, so the running app keeps focus.
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

int
main(int argc, char **argv)
{
	float want = argc > 1 ? atof(argv[1]) : 0;
	const char *exts[] = {XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME, XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME,
	                      XR_EXTX_OVERLAY_EXTENSION_NAME};
	XrInstanceCreateInfo ici = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	    .applicationInfo = {.applicationName = "xr_refresh", .apiVersion = XR_API_VERSION_1_0},
	    .enabledExtensionCount = 3,
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
	XrViewConfigurationView views[2] = {{.type = XR_TYPE_VIEW_CONFIGURATION_VIEW}, {.type = XR_TYPE_VIEW_CONFIGURATION_VIEW}};
	uint32_t nv;
	XR_CHECK(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, views));
	printf("recommended view %ux%u (max %ux%u)\n", views[0].recommendedImageRectWidth, views[0].recommendedImageRectHeight,
	       views[0].maxImageRectWidth, views[0].maxImageRectHeight);

	XrSessionCreateInfoOverlayEXTX overlay = {.type = XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX, .next = &binding, .sessionLayersPlacement = 1};
	XrSessionCreateInfo sci = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &overlay, .systemId = system};
	XrSession session;
	XR_CHECK(xrCreateSession(instance, &sci, &session));

	PFN_xrEnumerateDisplayRefreshRatesFB enumRates;
	PFN_xrGetDisplayRefreshRateFB getRate;
	PFN_xrRequestDisplayRefreshRateFB requestRate;
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrEnumerateDisplayRefreshRatesFB", (PFN_xrVoidFunction *)&enumRates));
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrGetDisplayRefreshRateFB", (PFN_xrVoidFunction *)&getRate));
	XR_CHECK(xrGetInstanceProcAddr(instance, "xrRequestDisplayRefreshRateFB", (PFN_xrVoidFunction *)&requestRate));
	float rates[16], cur = 0;
	uint32_t nr = 0;
	XR_CHECK(enumRates(session, 16, &nr, rates));
	printf("rates:");
	for (uint32_t i = 0; i < nr; i++)
		printf(" %.0f", rates[i]);
	XR_CHECK(getRate(session, &cur));
	printf("\ncurrent %.1f Hz\n", cur);

	if (want > 0) {
		XR_CHECK(requestRate(session, want));
		double start = now_s();
		while (now_s() - start < 4) {
			XrEventDataBuffer ev = {.type = XR_TYPE_EVENT_DATA_BUFFER};
			while (xrPollEvent(instance, &ev) == XR_SUCCESS) {
				if (ev.type == XR_TYPE_EVENT_DATA_DISPLAY_REFRESH_RATE_CHANGED_FB) {
					XrEventDataDisplayRefreshRateChangedFB *e = (XrEventDataDisplayRefreshRateChangedFB *)&ev;
					printf("changed %.1f -> %.1f Hz\n", e->fromDisplayRefreshRate, e->toDisplayRefreshRate);
				}
				ev = (XrEventDataBuffer){.type = XR_TYPE_EVENT_DATA_BUFFER};
			}
			struct timespec ts = {0, 50000000};
			nanosleep(&ts, NULL);
		}
		XR_CHECK(getRate(session, &cur));
		printf("now %.1f Hz\n", cur);
	}
	xrDestroySession(session);
	xrDestroyInstance(instance);
	return 0;
}
