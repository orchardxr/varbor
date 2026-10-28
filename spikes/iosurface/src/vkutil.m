#import <Metal/Metal.h>
#include "vkutil.h"
#include <mach/mach_time.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

static const uint32_t store_spv[] = {
#include "store.spv.inc"
};
static const uint32_t fetch_spv[] = {
#include "fetch.spv.inc"
};

static mach_timebase_info_data_t tb;

uint64_t now_ticks(void) { return mach_absolute_time(); }

double ticks_to_us(uint64_t t)
{
	if (!tb.denom)
		mach_timebase_info(&tb);
	return (double)t * tb.numer / tb.denom / 1000.0;
}

double now_us(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000.0; }

uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static bool has_ext(const VkExtensionProperties *e, uint32_t n, const char *name)
{
	for (uint32_t i = 0; i < n; i++)
		if (!strcmp(e[i].extensionName, name))
			return true;
	return false;
}

static VkResult make_pipeline(vkctx *c, const uint32_t *code, size_t size, VkPipelineLayout layout,
                              VkPipeline *out)
{
	VkShaderModuleCreateInfo smci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = size, .pCode = code};
	VkShaderModule sm;
	CHECK_VK(vkCreateShaderModule(c->dev, &smci, NULL, &sm));
	VkComputePipelineCreateInfo ci = {
	    VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
	    .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
	              .module = sm, .pName = "main"},
	    .layout = layout,
	};
	VkResult r = vkCreateComputePipelines(c->dev, VK_NULL_HANDLE, 1, &ci, NULL, out);
	vkDestroyShaderModule(c->dev, sm, NULL);
	return r;
}

VkResult vk_init(vkctx *c, bool quiet)
{
	memset(c, 0, sizeof(*c));
	const char *iexts[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
	                       VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME};
	VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "iosurface-spike",
	                        .apiVersion = VK_API_VERSION_1_2};
	VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
	                            .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
	                            .pApplicationInfo = &ai,
	                            .enabledExtensionCount = 2,
	                            .ppEnabledExtensionNames = iexts};
	CHECK_VK(vkCreateInstance(&ici, NULL, &c->inst));
	uint32_t n = 1;
	VkResult r = vkEnumeratePhysicalDevices(c->inst, &n, &c->pd);
	if (r < 0 || n == 0) {
		fprintf(stderr, "no physical device\n");
		return VK_ERROR_INITIALIZATION_FAILED;
	}

	VkPhysicalDeviceDriverProperties drv = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
	VkPhysicalDeviceProperties2 p2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv};
	vkGetPhysicalDeviceProperties2(c->pd, &p2);
	snprintf(c->driver, sizeof(c->driver), "%s %s (%s)", drv.driverName, drv.driverInfo,
	         p2.properties.deviceName);
	vkGetPhysicalDeviceMemoryProperties(c->pd, &c->memprops);

	uint32_t ne = 0;
	vkEnumerateDeviceExtensionProperties(c->pd, NULL, &ne, NULL);
	VkExtensionProperties *ep = calloc(ne, sizeof(*ep));
	vkEnumerateDeviceExtensionProperties(c->pd, NULL, &ne, ep);
	const char *dexts[8];
	uint32_t nd = 0;
	const char *want[] = {"VK_KHR_portability_subset", VK_EXT_METAL_OBJECTS_EXTENSION_NAME,
	                      VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME, VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
	                      VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME};
	for (size_t i = 0; i < sizeof(want) / sizeof(*want); i++) {
		if (has_ext(ep, ne, want[i]))
			dexts[nd++] = want[i];
		else if (i == 1) {
			fprintf(stderr, "VK_EXT_metal_objects missing\n");
			return VK_ERROR_EXTENSION_NOT_PRESENT;
		}
	}
	free(ep);

	VkPhysicalDeviceDynamicRenderingFeaturesKHR dr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR};
	VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &dr};
	VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12};
	VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11};
	vkGetPhysicalDeviceFeatures2(c->pd, &f2);
	c->storage_without_format = f2.features.shaderStorageImageWriteWithoutFormat;
	c->timeline = f12.timelineSemaphore;

	VkPhysicalDeviceDynamicRenderingFeaturesKHR dr_e = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
	                                                     .dynamicRendering = dr.dynamicRendering};
	VkPhysicalDeviceVulkan12Features f12_e = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &dr_e,
	                                          .timelineSemaphore = f12.timelineSemaphore};
	VkPhysicalDeviceVulkan11Features f11_e = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12_e,
	                                          .samplerYcbcrConversion = f11.samplerYcbcrConversion};
	VkPhysicalDeviceFeatures2 f2_e = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11_e};
	f2_e.features.shaderStorageImageWriteWithoutFormat = c->storage_without_format;

	uint32_t nq = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &nq, NULL);
	VkQueueFamilyProperties qp[8];
	nq = nq > 8 ? 8 : nq;
	vkGetPhysicalDeviceQueueFamilyProperties(c->pd, &nq, qp);
	for (c->qfam = 0; c->qfam < nq; c->qfam++)
		if (qp[c->qfam].queueFlags & VK_QUEUE_GRAPHICS_BIT)
			break;
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = c->qfam,
	                               .queueCount = 1, .pQueuePriorities = &prio};
	VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
	                          .pNext = &f2_e,
	                          .queueCreateInfoCount = 1,
	                          .pQueueCreateInfos = &qci,
	                          .enabledExtensionCount = nd,
	                          .ppEnabledExtensionNames = dexts};
	CHECK_VK(vkCreateDevice(c->pd, &dci, NULL, &c->dev));
	vkGetDeviceQueue(c->dev, c->qfam, 0, &c->q);
	c->exportMetal = (PFN_vkExportMetalObjectsEXT)vkGetDeviceProcAddr(c->dev, "vkExportMetalObjectsEXT");

	VkExportMetalDeviceInfoEXT mdev = {VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
	VkExportMetalObjectsInfoEXT moi = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &mdev};
	c->exportMetal(c->dev, &moi);
	c->mtl_device = (void *)mdev.mtlDevice;

	VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	                                .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	                                .queueFamilyIndex = c->qfam};
	CHECK_VK(vkCreateCommandPool(c->dev, &cpci, NULL, &c->pool));

	VkDescriptorSetLayoutBinding b_store = {0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT};
	VkDescriptorSetLayoutCreateInfo dslci = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1,
	                                         .pBindings = &b_store};
	CHECK_VK(vkCreateDescriptorSetLayout(c->dev, &dslci, NULL, &c->dsl_store));
	VkDescriptorSetLayoutBinding b_fetch[2] = {
	    {0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_COMPUTE_BIT},
	    {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT},
	};
	dslci.bindingCount = 2;
	dslci.pBindings = b_fetch;
	CHECK_VK(vkCreateDescriptorSetLayout(c->dev, &dslci, NULL, &c->dsl_fetch));

	VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 12};
	VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
	                                   .pSetLayouts = &c->dsl_store, .pushConstantRangeCount = 1,
	                                   .pPushConstantRanges = &pcr};
	CHECK_VK(vkCreatePipelineLayout(c->dev, &plci, NULL, &c->layout_store));
	plci.pSetLayouts = &c->dsl_fetch;
	CHECK_VK(vkCreatePipelineLayout(c->dev, &plci, NULL, &c->layout_fetch));
	if (c->storage_without_format)
		CHECK_VK(make_pipeline(c, store_spv, sizeof(store_spv), c->layout_store, &c->pipe_store));
	CHECK_VK(make_pipeline(c, fetch_spv, sizeof(fetch_spv), c->layout_fetch, &c->pipe_fetch));

	VkDescriptorPoolSize ps[3] = {{VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 256},
	                              {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 256},
	                              {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 256}};
	VkDescriptorPoolCreateInfo dpci = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
	                                   .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
	                                   .maxSets = 256, .poolSizeCount = 3, .pPoolSizes = ps};
	CHECK_VK(vkCreateDescriptorPool(c->dev, &dpci, NULL, &c->dpool));
	VkSamplerCreateInfo sci = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST,
	                           .minFilter = VK_FILTER_NEAREST};
	CHECK_VK(vkCreateSampler(c->dev, &sci, NULL, &c->sampler));
	if (!quiet)
		printf("# driver: %s, storageWithoutFormat=%d timeline=%d\n", c->driver, c->storage_without_format,
		       c->timeline);
	return VK_SUCCESS;
}

void vk_fini(vkctx *c)
{
	if (!c->dev)
		return;
	vkDeviceWaitIdle(c->dev);
	vkDestroySampler(c->dev, c->sampler, NULL);
	vkDestroyDescriptorPool(c->dev, c->dpool, NULL);
	vkDestroyPipeline(c->dev, c->pipe_store, NULL);
	vkDestroyPipeline(c->dev, c->pipe_fetch, NULL);
	vkDestroyPipelineLayout(c->dev, c->layout_store, NULL);
	vkDestroyPipelineLayout(c->dev, c->layout_fetch, NULL);
	vkDestroyDescriptorSetLayout(c->dev, c->dsl_store, NULL);
	vkDestroyDescriptorSetLayout(c->dev, c->dsl_fetch, NULL);
	vkDestroyCommandPool(c->dev, c->pool, NULL);
	vkDestroyDevice(c->dev, NULL);
	vkDestroyInstance(c->inst, NULL);
	memset(c, 0, sizeof(*c));
}

static int find_mem(vkctx *c, uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < c->memprops.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (c->memprops.memoryTypes[i].propertyFlags & want) == want)
			return (int)i;
	return -1;
}

VkResult shimg_create(vkctx *c, VkFormat fmt, uint32_t w, uint32_t h, VkImageUsageFlags usage,
                      VkImageCreateFlags flags, enum shimg_mode mode, IOSurfaceRef in_surf, void *in_mtltex,
                      const VkFormat *view_fmts, uint32_t n_view_fmts, shimg *out)
{
	memset(out, 0, sizeof(*out));
	out->fmt = fmt;
	out->w = w;
	out->h = h;
	VkExportMetalObjectCreateInfoEXT exp = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
	                                        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_IOSURFACE_BIT_EXT};
	VkImportMetalIOSurfaceInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT, .ioSurface = in_surf};
	VkImportMetalTextureInfoEXT impt = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
	                                    .plane = VK_IMAGE_ASPECT_PLANE_0_BIT, .mtlTexture = (id<MTLTexture>)in_mtltex};
	VkImageFormatListCreateInfo fl = {VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
	                                  .viewFormatCount = n_view_fmts, .pViewFormats = view_fmts};
	const void *chain = NULL;
	if (mode == SHIMG_EXPORT)
		chain = &exp;
	else if (mode == SHIMG_IMPORT)
		chain = &imp;
	else if (mode == SHIMG_MTLTEX)
		chain = &impt;
	if (n_view_fmts) {
		fl.pNext = chain;
		chain = &fl;
	}
	VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
	                         .pNext = chain,
	                         .flags = flags,
	                         .imageType = VK_IMAGE_TYPE_2D,
	                         .format = fmt,
	                         .extent = {w, h, 1},
	                         .mipLevels = 1,
	                         .arrayLayers = 1,
	                         .samples = VK_SAMPLE_COUNT_1_BIT,
	                         .tiling = VK_IMAGE_TILING_OPTIMAL,
	                         .usage = usage,
	                         .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
	CHECK_VK(vkCreateImage(c->dev, &ici, NULL, &out->img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(c->dev, out->img, &mr);
	int mt = find_mem(c, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (mt < 0)
		mt = find_mem(c, mr.memoryTypeBits, 0);
	VkMemoryDedicatedAllocateInfo ded = {VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = out->img};
	VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &ded, .allocationSize = mr.size,
	                            .memoryTypeIndex = (uint32_t)mt};
	CHECK_VK(vkAllocateMemory(c->dev, &mai, NULL, &out->mem));
	CHECK_VK(vkBindImageMemory(c->dev, out->img, out->mem, 0));
	if (mode == SHIMG_EXPORT) {
		VkExportMetalIOSurfaceInfoEXT ex = {VK_STRUCTURE_TYPE_EXPORT_METAL_IO_SURFACE_INFO_EXT, .image = out->img};
		VkExportMetalObjectsInfoEXT moi = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &ex};
		c->exportMetal(c->dev, &moi);
		if (!ex.ioSurface) {
			fprintf(stderr, "vkExportMetalObjectsEXT returned no IOSurface\n");
			return VK_ERROR_INITIALIZATION_FAILED;
		}
		out->surf = (IOSurfaceRef)CFRetain(ex.ioSurface);
	} else if (mode == SHIMG_IMPORT) {
		out->surf = (IOSurfaceRef)CFRetain(in_surf);
	}
	return VK_SUCCESS;
}

void shimg_destroy(vkctx *c, shimg *s)
{
	if (s->img)
		vkDestroyImage(c->dev, s->img, NULL);
	if (s->mem)
		vkFreeMemory(c->dev, s->mem, NULL);
	if (s->surf)
		CFRelease(s->surf);
	memset(s, 0, sizeof(*s));
}

VkResult buf_create(vkctx *c, VkDeviceSize size, VkBufferUsageFlags usage, buf *out)
{
	memset(out, 0, sizeof(*out));
	out->size = size;
	VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage};
	CHECK_VK(vkCreateBuffer(c->dev, &bci, NULL, &out->b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(c->dev, out->b, &mr);
	int mt = find_mem(c, mr.memoryTypeBits,
	                  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
	                            .memoryTypeIndex = (uint32_t)mt};
	CHECK_VK(vkAllocateMemory(c->dev, &mai, NULL, &out->mem));
	CHECK_VK(vkBindBufferMemory(c->dev, out->b, out->mem, 0));
	CHECK_VK(vkMapMemory(c->dev, out->mem, 0, VK_WHOLE_SIZE, 0, &out->map));
	return VK_SUCCESS;
}

void buf_destroy(vkctx *c, buf *b)
{
	if (b->b)
		vkDestroyBuffer(c->dev, b->b, NULL);
	if (b->mem)
		vkFreeMemory(c->dev, b->mem, NULL);
	memset(b, 0, sizeof(*b));
}

VkResult cmd_begin(vkctx *c, VkCommandBuffer *cb)
{
	VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = c->pool,
	                                  .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
	CHECK_VK(vkAllocateCommandBuffers(c->dev, &ai, cb));
	VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
	                               .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	CHECK_VK(vkBeginCommandBuffer(*cb, &bi));
	return VK_SUCCESS;
}

VkResult cmd_submit_wait(vkctx *c, VkCommandBuffer cb)
{
	CHECK_VK(vkEndCommandBuffer(cb));
	VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence f;
	CHECK_VK(vkCreateFence(c->dev, &fci, NULL, &f));
	VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	CHECK_VK(vkQueueSubmit(c->q, 1, &si, f));
	VkResult r = vkWaitForFences(c->dev, 1, &f, VK_TRUE, 5000000000ull);
	vkDestroyFence(c->dev, f, NULL);
	vkFreeCommandBuffers(c->dev, c->pool, 1, &cb);
	return r;
}

void cmd_barrier_all(VkCommandBuffer cb)
{
	VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER,
	                      .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT,
	                      .dstAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0,
	                     NULL, 0, NULL);
}

void cmd_to_general(VkCommandBuffer cb, VkImage img, VkImageAspectFlags aspect)
{
	VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	                           .srcAccessMask = 0,
	                           .dstAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT,
	                           .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	                           .newLayout = VK_IMAGE_LAYOUT_GENERAL,
	                           .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	                           .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	                           .image = img,
	                           .subresourceRange = {aspect, 0, 1, 0, 1}};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
	                     NULL, 1, &ib);
}

VkResult view_create(vkctx *c, VkImage img, VkFormat fmt, VkImageAspectFlags aspect, VkImageUsageFlags view_usage,
                     VkImageView *out)
{
	VkImageViewUsageCreateInfo uci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO, .usage = view_usage};
	VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
	                             .pNext = view_usage ? &uci : NULL,
	                             .image = img,
	                             .viewType = VK_IMAGE_VIEW_TYPE_2D,
	                             .format = fmt,
	                             .subresourceRange = {aspect, 0, 1, 0, 1}};
	return vkCreateImageView(c->dev, &vci, NULL, out);
}

VkResult cmd_store_pattern(vkctx *c, VkCommandBuffer cb, VkImageView view, uint32_t w, uint32_t h, uint32_t frame,
                           VkDescriptorSet *set_out)
{
	if (!c->pipe_store)
		return VK_ERROR_FEATURE_NOT_PRESENT;
	VkDescriptorSetAllocateInfo ai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c->dpool,
	                                  .descriptorSetCount = 1, .pSetLayouts = &c->dsl_store};
	CHECK_VK(vkAllocateDescriptorSets(c->dev, &ai, set_out));
	VkDescriptorImageInfo ii = {.imageView = view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL};
	VkWriteDescriptorSet wds = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = *set_out, .descriptorCount = 1,
	                            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &ii};
	vkUpdateDescriptorSets(c->dev, 1, &wds, 0, NULL);
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe_store);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->layout_store, 0, 1, set_out, 0, NULL);
	uint32_t pc[3] = {w, h, frame};
	vkCmdPushConstants(cb, c->layout_store, VK_SHADER_STAGE_COMPUTE_BIT, 0, 12, pc);
	vkCmdDispatch(cb, (w + 7) / 8, (h + 7) / 8, 1);
	return VK_SUCCESS;
}

VkResult cmd_fetch(vkctx *c, VkCommandBuffer cb, VkImageView view, buf *out, uint32_t w, uint32_t h,
                   VkDescriptorSet *set_out)
{
	VkDescriptorSetAllocateInfo ai = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = c->dpool,
	                                  .descriptorSetCount = 1, .pSetLayouts = &c->dsl_fetch};
	CHECK_VK(vkAllocateDescriptorSets(c->dev, &ai, set_out));
	VkDescriptorImageInfo ii = {.sampler = c->sampler, .imageView = view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL};
	VkDescriptorBufferInfo bi = {.buffer = out->b, .offset = 0, .range = VK_WHOLE_SIZE};
	VkWriteDescriptorSet wds[2] = {
	    {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = *set_out, .dstBinding = 0, .descriptorCount = 1,
	     .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &ii},
	    {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = *set_out, .dstBinding = 1, .descriptorCount = 1,
	     .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi},
	};
	vkUpdateDescriptorSets(c->dev, 2, wds, 0, NULL);
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->pipe_fetch);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, c->layout_fetch, 0, 1, set_out, 0, NULL);
	uint32_t pc[3] = {w, h, 0};
	vkCmdPushConstants(cb, c->layout_fetch, VK_SHADER_STAGE_COMPUTE_BIT, 0, 12, pc);
	vkCmdDispatch(cb, (w + 7) / 8, (h + 7) / 8, 1);
	return VK_SUCCESS;
}

static void dict_set_int(CFMutableDictionaryRef d, CFStringRef k, int64_t v)
{
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
	CFDictionarySetValue(d, k, n);
	CFRelease(n);
}

IOSurfaceRef surf_create(uint32_t w, uint32_t h, uint32_t bpe, uint32_t pixfmt)
{
	CFMutableDictionaryRef d =
	    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	dict_set_int(d, kIOSurfaceWidth, w);
	dict_set_int(d, kIOSurfaceHeight, h);
	dict_set_int(d, kIOSurfaceBytesPerElement, bpe);
	if (pixfmt)
		dict_set_int(d, kIOSurfacePixelFormat, pixfmt);
	IOSurfaceRef s = IOSurfaceCreate(d);
	CFRelease(d);
	return s;
}

IOSurfaceRef surf_create_nv12(uint32_t w, uint32_t h, uint32_t pixfmt, bool mvk_compat)
{
	CFMutableDictionaryRef d =
	    CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	dict_set_int(d, kIOSurfaceWidth, w);
	dict_set_int(d, kIOSurfaceHeight, h);
	dict_set_int(d, kIOSurfacePixelFormat, pixfmt);
	if (mvk_compat) {
		/* MoltenVK's useIOSurface() compares these against the 2x2/6-byte block of G8_B8R8_2PLANE_420 */
		dict_set_int(d, kIOSurfaceBytesPerElement, 6);
		dict_set_int(d, kIOSurfaceElementWidth, 2);
		dict_set_int(d, kIOSurfaceElementHeight, 2);
	}
	CFMutableArrayRef planes = CFArrayCreateMutable(NULL, 2, &kCFTypeArrayCallBacks);
	size_t offset = 0;
	for (int p = 0; p < 2; p++) {
		CFMutableDictionaryRef pd = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
		                                                      &kCFTypeDictionaryValueCallBacks);
		uint32_t pw = p ? w / 2 : w, ph = p ? h / 2 : h, pbpe = p ? 2 : 1;
		size_t bpr = IOSurfaceAlignProperty(kIOSurfacePlaneBytesPerRow, pw * pbpe);
		dict_set_int(pd, kIOSurfacePlaneWidth, pw);
		dict_set_int(pd, kIOSurfacePlaneHeight, ph);
		dict_set_int(pd, kIOSurfacePlaneBytesPerElement, pbpe);
		/* MoltenVK reports the chroma plane's block as 2x2 and rejects element size 1 */
		uint32_t el = (mvk_compat && p) ? 2 : 1;
		dict_set_int(pd, kIOSurfacePlaneElementWidth, el);
		dict_set_int(pd, kIOSurfacePlaneElementHeight, el);
		dict_set_int(pd, kIOSurfacePlaneBytesPerRow, bpr);
		if (mvk_compat) {
			size_t sz = IOSurfaceAlignProperty(kIOSurfacePlaneSize, bpr * ph);
			dict_set_int(pd, kIOSurfacePlaneOffset, offset);
			dict_set_int(pd, kIOSurfacePlaneSize, sz);
			offset += sz;
		}
		CFArrayAppendValue(planes, pd);
		CFRelease(pd);
	}
	CFDictionarySetValue(d, kIOSurfacePlaneInfo, planes);
	if (mvk_compat)
		dict_set_int(d, kIOSurfaceAllocSize, offset);
	CFRelease(planes);
	IOSurfaceRef s = IOSurfaceCreate(d);
	CFRelease(d);
	return s;
}

void surf_describe(IOSurfaceRef s, char *out, size_t n)
{
	uint32_t pf = IOSurfaceGetPixelFormat(s);
	char fcc[5] = {0};
	for (int i = 0; i < 4; i++) {
		char ch = (char)((pf >> (24 - 8 * i)) & 0xff);
		fcc[i] = (ch >= 32 && ch < 127) ? ch : '.';
	}
	int k = snprintf(out, n, "%zux%zu bpe=%zu bpr=%zu pf='%s'(0x%x) planes=%zu alloc=%zu", IOSurfaceGetWidth(s),
	                 IOSurfaceGetHeight(s), IOSurfaceGetBytesPerElement(s), IOSurfaceGetBytesPerRow(s), fcc, pf,
	                 IOSurfaceGetPlaneCount(s), IOSurfaceGetAllocSize(s));
	for (size_t p = 0; p < IOSurfaceGetPlaneCount(s) && k > 0 && (size_t)k < n; p++)
		k += snprintf(out + k, n - k, " [p%zu %zux%zu bpe=%zu bpr=%zu]", p, IOSurfaceGetWidthOfPlane(s, p),
		              IOSurfaceGetHeightOfPlane(s, p), IOSurfaceGetBytesPerElementOfPlane(s, p),
		              IOSurfaceGetBytesPerRowOfPlane(s, p));
}

void *mtl_texture_from_surface(void *mtl_device, IOSurfaceRef s, int plane, int mtl_pixfmt, uint32_t w, uint32_t h)
{
	id<MTLDevice> dev = (id<MTLDevice>)mtl_device;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)mtl_pixfmt
	                                                                             width:w
	                                                                            height:h
	                                                                         mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	d.storageMode = MTLStorageModeShared;
	return [dev newTextureWithDescriptor:d iosurface:s plane:(NSUInteger)plane];
}

void objc_release_obj(void *o)
{
	if (o)
		[(id)o release];
}

@interface MTLSharedTextureHandle ()
- (instancetype)initWithMachPort:(mach_port_t)port;
- (mach_port_t)createMachPort;
@end

void *mtl_shared_texture_new(void *mtl_device, int mtl_pixfmt, uint32_t w, uint32_t h, uint32_t layers, mach_port_t *port)
{
	id<MTLDevice> dev = (id<MTLDevice>)mtl_device;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)mtl_pixfmt
	                                                                             width:w
	                                                                            height:h
	                                                                         mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	d.storageMode = MTLStorageModePrivate;
	if (layers > 1) {
		d.textureType = MTLTextureType2DArray;
		d.arrayLength = layers;
	}
	id<MTLTexture> t = [dev newSharedTextureWithDescriptor:d];
	if (!t)
		return NULL;
	MTLSharedTextureHandle *h_ = [t newSharedTextureHandle];
	*port = [h_ createMachPort];
	[h_ release];
	return t;
}

void *mtl_shared_texture_from_port(void *mtl_device, mach_port_t port)
{
	MTLSharedTextureHandle *h = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
	id<MTLTexture> t = [(id<MTLDevice>)mtl_device newSharedTextureWithHandle:h];
	[h release];
	return t;
}

VkResult image_from_mtltex(vkctx *c, void *tex, VkFormat fmt, uint32_t w, uint32_t h, uint32_t layers,
                           VkImageUsageFlags usage, VkImage *img, VkDeviceMemory *mem)
{
	VkImportMetalTextureInfoEXT it = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
	                                  .plane = VK_IMAGE_ASPECT_PLANE_0_BIT, .mtlTexture = (id<MTLTexture>)tex};
	VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &it, .imageType = VK_IMAGE_TYPE_2D,
	                         .format = fmt, .extent = {w, h, 1}, .mipLevels = 1, .arrayLayers = layers,
	                         .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage};
	CHECK_VK(vkCreateImage(c->dev, &ici, NULL, img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(c->dev, *img, &mr);
	int mt = find_mem(c, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
	                            .memoryTypeIndex = (uint32_t)(mt < 0 ? 0 : mt)};
	CHECK_VK(vkAllocateMemory(c->dev, &mai, NULL, mem));
	return vkBindImageMemory(c->dev, *img, *mem, 0);
}
