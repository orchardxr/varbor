// M2 step 5 check: can a MoltenVK device import an MTLSharedTextureHandle texture (array and depth) through
// VkImportMetalTextureInfoEXT, without VK_EXT_metal_objects enabled (as on DXVK's device)?
//   metal_texture_import <libMoltenVK.dylib>   (native), or mti_run_cases() from vkprobe.so on DXVK's device in Wine
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

@interface MTLSharedTextureHandle (SPI)
- (instancetype)initWithMachPort:(mach_port_t)port;
- (mach_port_t)createMachPort;
@end

static int g_fail;
#define CHECK(c, ...) do { printf("%s: ", (c) ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!(c)) g_fail++; } while (0)

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance inst;
static VkPhysicalDevice pd __attribute__((unused));
static VkDevice dev;
static VkQueue queue;
#define F(name) PFN_##name name = (PFN_##name)gipa(inst, #name)

static uint32_t readback(id<MTLDevice> mdev, id<MTLTexture> tex, NSUInteger slice, uint32_t bpp)
{
	id<MTLBuffer> buf = [mdev newBufferWithLength:tex.width * tex.height * bpp options:MTLResourceStorageModeShared];
	id<MTLCommandQueue> q = [mdev newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
	[b copyFromTexture:tex sourceSlice:slice sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
	        sourceSize:MTLSizeMake(tex.width, tex.height, 1) toBuffer:buf destinationOffset:0
	        destinationBytesPerRow:tex.width * bpp destinationBytesPerImage:tex.width * tex.height * bpp];
	[b endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	return ((uint32_t *)buf.contents)[tex.width * (tex.height / 2) + tex.width / 2];
}

static void run_case(id<MTLDevice> mdev, const char *name, MTLPixelFormat mfmt, VkFormat vfmt, NSUInteger layers, BOOL depth)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor new];
	d.textureType = layers > 1 ? MTLTextureType2DArray : MTLTextureType2D;
	d.pixelFormat = mfmt;
	d.width = 64;
	d.height = 32;
	d.arrayLength = layers;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	d.storageMode = MTLStorageModePrivate;
	id<MTLTexture> tex = [mdev newSharedTextureWithDescriptor:d];
	MTLSharedTextureHandle *h = [tex newSharedTextureHandle];
	mach_port_t port = [h createMachPort];
	MTLSharedTextureHandle *h2 = [[MTLSharedTextureHandle alloc] initWithMachPort:port];
	id<MTLTexture> imported = h2 ? [mdev newSharedTextureWithHandle:h2] : nil;
	if (!imported)
	{
		CHECK(0, "%s: Metal shared texture round trip through a Mach port", name);
		return;
	}

	F(vkCreateImage); F(vkGetImageMemoryRequirements); F(vkAllocateMemory); F(vkBindImageMemory);
	F(vkCreateCommandPool); F(vkAllocateCommandBuffers); F(vkBeginCommandBuffer); F(vkEndCommandBuffer);
	F(vkCmdClearColorImage); F(vkCmdClearDepthStencilImage); F(vkQueueSubmit); F(vkQueueWaitIdle);
	F(vkCmdPipelineBarrier);
	VkImportMetalTextureInfoEXT import = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT, NULL,
	                                      VK_IMAGE_ASPECT_PLANE_0_BIT, imported};
	VkImageCreateInfo ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &import};
	ci.imageType = VK_IMAGE_TYPE_2D;
	ci.format = vfmt;
	ci.extent = (VkExtent3D){64, 32, 1};
	ci.mipLevels = 1;
	ci.arrayLayers = (uint32_t)layers;
	ci.samples = VK_SAMPLE_COUNT_1_BIT;
	ci.tiling = VK_IMAGE_TILING_OPTIMAL;
	ci.usage = (depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) |
	           VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	VkImage img;
	VkResult r = vkCreateImage(dev, &ci, NULL, &img);
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements(dev, img, &req);
	VkMemoryAllocateInfo ai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, req.size, __builtin_ctz(req.memoryTypeBits)};
	VkDeviceMemory mem;
	if (!r) r = vkAllocateMemory(dev, &ai, NULL, &mem);
	if (!r) r = vkBindImageMemory(dev, img, mem, 0);
	if (r)
	{
		CHECK(0, "%s: vkCreateImage/bind with VkImportMetalTextureInfoEXT: %d", name, r);
		return;
	}

	VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
	VkCommandPool pool;
	vkCreateCommandPool(dev, &pci, NULL, &pool);
	VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
	VkCommandBuffer cb;
	vkAllocateCommandBuffers(dev, &cai, &cb);
	VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	vkBeginCommandBuffer(cb, &bi);
	VkImageAspectFlags aspect = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
	VkImageMemoryBarrier bar = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
	                            VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_QUEUE_FAMILY_IGNORED,
	                            VK_QUEUE_FAMILY_IGNORED, img, {aspect, 0, 1, 0, (uint32_t)layers}};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &bar);
	VkImageSubresourceRange last = {aspect, 0, 1, (uint32_t)layers - 1, 1};
	if (depth)
	{
		VkClearDepthStencilValue v = {0.25f, 0};
		vkCmdClearDepthStencilImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &v, 1, &last);
	}
	else
	{
		VkClearColorValue v = {{1.0f, 0.5f, 0.0f, 1.0f}};
		vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &v, 1, &last);
	}
	vkEndCommandBuffer(cb);
	VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &cb};
	vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
	vkQueueWaitIdle(queue);

	uint32_t px = readback(mdev, tex, layers - 1, 4);
	uint32_t want = depth ? 0x3e800000 /* 0.25f */ : vfmt == VK_FORMAT_B8G8R8A8_UNORM ? 0xffff8000 : 0xff00bcff /* sRGB */;
	CHECK(px == want, "%s: Vulkan clear of layer %lu lands in the exporter's MTLTexture (read %#x, want %#x)", name,
	      (unsigned long)layers - 1, px, want);
}

int mti_run_cases(PFN_vkGetInstanceProcAddr g, VkInstance i, VkDevice d, VkQueue q)
{
	gipa = g;
	inst = i;
	dev = d;
	queue = q;
	id<MTLDevice> mdev = MTLCreateSystemDefaultDevice();
	run_case(mdev, "BGRA8 2-layer array", MTLPixelFormatBGRA8Unorm, VK_FORMAT_B8G8R8A8_UNORM, 2, NO);
	run_case(mdev, "RGBA8 sRGB 2-layer array", MTLPixelFormatRGBA8Unorm_sRGB, VK_FORMAT_R8G8B8A8_SRGB, 2, NO);
	run_case(mdev, "D32 float", MTLPixelFormatDepth32Float, VK_FORMAT_D32_SFLOAT, 1, YES);
	run_case(mdev, "D32 float 2-layer array", MTLPixelFormatDepth32Float, VK_FORMAT_D32_SFLOAT, 2, YES);
	return g_fail;
}

#ifndef MTI_NO_MAIN
int main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IONBF, 0);
		void *lib = dlopen(argc > 1 ? argv[1] : "libMoltenVK.dylib", RTLD_NOW | RTLD_LOCAL);
		gipa = lib ? (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr") : NULL;
		if (!gipa)
		{
			printf("FAIL: dlopen %s: %s\n", argc > 1 ? argv[1] : "", dlerror());
			return 1;
		}
		PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
		VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "mti", 0, NULL, 0, VK_API_VERSION_1_2};
		VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app};
		if (vkCreateInstance(&ici, NULL, &inst)) return 1;
		F(vkEnumeratePhysicalDevices); F(vkCreateDevice); F(vkGetDeviceQueue); F(vkGetPhysicalDeviceProperties);
		uint32_t n = 1;
		vkEnumeratePhysicalDevices(inst, &n, &pd);
		VkPhysicalDeviceProperties props;
		vkGetPhysicalDeviceProperties(pd, &props);
		printf("  %s: %s, driver %#x (MoltenVK %u.%u.%u), no VK_EXT_metal_objects on the device\n", argv[1], props.deviceName,
		       props.driverVersion, props.driverVersion / 10000, props.driverVersion / 100 % 100, props.driverVersion % 100);
		float prio = 1;
		VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
		VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci};
		if (vkCreateDevice(pd, &dci, NULL, &dev)) return 1;
		vkGetDeviceQueue(dev, 0, 0, &queue);

		mti_run_cases(gipa, inst, dev, queue);
		printf("%s\n", g_fail ? "SOME FAILED" : "ALL PASS");
		return g_fail != 0;
	}
}
#endif
