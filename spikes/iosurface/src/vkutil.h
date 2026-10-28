#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <IOSurface/IOSurfaceRef.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>

#define CHECK_VK(x)                                                                    \
	do {                                                                           \
		VkResult r_ = (x);                                                     \
		if (r_ != VK_SUCCESS) {                                                \
			fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #x, r_); \
			return r_;                                                     \
		}                                                                      \
	} while (0)

typedef struct vkctx
{
	VkInstance inst;
	VkPhysicalDevice pd;
	VkDevice dev;
	VkQueue q;
	uint32_t qfam;
	VkCommandPool pool;
	VkPhysicalDeviceMemoryProperties memprops;
	PFN_vkExportMetalObjectsEXT exportMetal;
	char driver[VK_MAX_DRIVER_INFO_SIZE];
	bool storage_without_format;
	bool timeline;
	void *mtl_device; /* id<MTLDevice>, borrowed */
	VkPipelineLayout layout_store, layout_fetch;
	VkDescriptorSetLayout dsl_store, dsl_fetch;
	VkPipeline pipe_store, pipe_fetch;
	VkDescriptorPool dpool;
	VkSampler sampler;
} vkctx;

enum shimg_mode
{
	SHIMG_PLAIN = 0,
	SHIMG_EXPORT,  /* VkExportMetalObjectCreateInfoEXT(IOSURFACE) + vkExportMetalObjectsEXT */
	SHIMG_IMPORT,  /* VkImportMetalIOSurfaceInfoEXT */
	SHIMG_MTLTEX,  /* VkImportMetalTextureInfoEXT */
};

typedef struct shimg
{
	VkImage img;
	VkDeviceMemory mem;
	IOSurfaceRef surf; /* retained */
	VkFormat fmt;
	uint32_t w, h;
} shimg;

typedef struct buf
{
	VkBuffer b;
	VkDeviceMemory mem;
	void *map;
	VkDeviceSize size;
} buf;

double now_us(void);
uint64_t now_ns(void); /* CLOCK_UPTIME_RAW: same value in arm64 and Rosetta processes */
uint64_t now_ticks(void);
double ticks_to_us(uint64_t t);

VkResult vk_init(vkctx *c, bool quiet);
void vk_fini(vkctx *c);

VkResult shimg_create(vkctx *c, VkFormat fmt, uint32_t w, uint32_t h, VkImageUsageFlags usage,
                      VkImageCreateFlags flags, enum shimg_mode mode, IOSurfaceRef in_surf,
                      void *in_mtltex, const VkFormat *view_fmts, uint32_t n_view_fmts, shimg *out);
void shimg_destroy(vkctx *c, shimg *s);

VkResult buf_create(vkctx *c, VkDeviceSize size, VkBufferUsageFlags usage, buf *out);
void buf_destroy(vkctx *c, buf *b);

VkResult cmd_begin(vkctx *c, VkCommandBuffer *cb);
VkResult cmd_submit_wait(vkctx *c, VkCommandBuffer cb);
void cmd_barrier_all(VkCommandBuffer cb);
void cmd_to_general(VkCommandBuffer cb, VkImage img, VkImageAspectFlags aspect);

VkResult view_create(vkctx *c, VkImage img, VkFormat fmt, VkImageAspectFlags aspect,
                     VkImageUsageFlags view_usage, VkImageView *out);

/* store.comp: writes the test pattern into a storage image view */
VkResult cmd_store_pattern(vkctx *c, VkCommandBuffer cb, VkImageView view, uint32_t w, uint32_t h,
                           uint32_t frame, VkDescriptorSet *set_out);
/* fetch.comp: texelFetch every texel into a vec4 SSBO */
VkResult cmd_fetch(vkctx *c, VkCommandBuffer cb, VkImageView view, buf *out, uint32_t w, uint32_t h,
                   VkDescriptorSet *set_out);

static inline void pattern(uint32_t x, uint32_t y, uint32_t frame, uint8_t out[4])
{
	out[0] = (uint8_t)((x * 7u + frame * 13u) & 255u);
	out[1] = (uint8_t)((y * 5u + frame * 3u) & 255u);
	out[2] = (uint8_t)((x ^ y) & 255u);
	out[3] = 255;
}

/* IOSurface helpers */
IOSurfaceRef surf_create(uint32_t w, uint32_t h, uint32_t bpe, uint32_t pixfmt);
IOSurfaceRef surf_create_nv12(uint32_t w, uint32_t h, uint32_t pixfmt, bool mvk_compat);
void surf_describe(IOSurfaceRef s, char *out, size_t n);

/* Metal helpers (vkutil.m) */
void *mtl_texture_from_surface(void *mtl_device, IOSurfaceRef s, int plane, int mtl_pixfmt, uint32_t w,
                               uint32_t h); /* retained id<MTLTexture> */
void objc_release_obj(void *o);
/* MTLSharedTextureHandle route (private createMachPort/initWithMachPort, as used by DXMT) */
void *mtl_shared_texture_new(void *mtl_device, int mtl_pixfmt, uint32_t w, uint32_t h, uint32_t layers,
                             mach_port_t *port);
void *mtl_shared_texture_from_port(void *mtl_device, mach_port_t port);
VkResult image_from_mtltex(vkctx *c, void *tex, VkFormat fmt, uint32_t w, uint32_t h, uint32_t layers,
                           VkImageUsageFlags usage, VkImage *img, VkDeviceMemory *mem);
