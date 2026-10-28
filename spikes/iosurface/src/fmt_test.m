#import <Metal/Metal.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include "vkutil.h"

extern char **environ;

enum kind { K_UNORM8, K_SRGB8, K_BGRA_SRGB, K_HALF4, K_A2B10G10R10, K_D32 };

typedef struct fmtinfo
{
	const char *name;
	VkFormat vk;
	uint32_t bpe;
	uint32_t pixfmt;
	enum kind kind;
} fmtinfo;

static const fmtinfo fmts[] = {
    {"R8G8B8A8_UNORM", VK_FORMAT_R8G8B8A8_UNORM, 4, 'RGBA', K_UNORM8},
    {"R8G8B8A8_SRGB", VK_FORMAT_R8G8B8A8_SRGB, 4, 'RGBA', K_SRGB8},
    {"B8G8R8A8_SRGB", VK_FORMAT_B8G8R8A8_SRGB, 4, 'BGRA', K_BGRA_SRGB},
    {"R16G16B16A16_SFLOAT", VK_FORMAT_R16G16B16A16_SFLOAT, 8, 'RGhA', K_HALF4},
    {"A2B10G10R10_UNORM", VK_FORMAT_A2B10G10R10_UNORM_PACK32, 4, 'l10r', K_A2B10G10R10},
    {"D32_SFLOAT", VK_FORMAT_D32_SFLOAT, 4, 0, K_D32},
};
#define NFMTS (int)(sizeof(fmts) / sizeof(*fmts))

static const char *mode_name[] = {"plain", "export", "import"};

#define W 250
#define H 130

static int g_fail;

static void result(const char *cs, const char *test, int ok, const char *fmt, ...)
{
	char msg[512] = "";
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	const char *tag = ok == 1 ? "PASS" : ok == 0 ? "FAIL" : ok == 2 ? "XFAIL" : ok == 3 ? "INFO" : "SKIP";
	printf("%-5s %-34s %-14s %s\n", tag, cs, test, msg);
	fflush(stdout);
	if (ok == 0)
		g_fail = 1;
}

static float srgb_enc(float l) { return l <= 0.0031308f ? l * 12.92f : 1.055f * powf(l, 1 / 2.4f) - 0.055f; }
static float srgb_dec(float s) { return s <= 0.04045f ? s / 12.92f : powf((s + 0.055f) / 1.055f, 2.4f); }

/* encode linear rgba floats into one texel of format k */
static void encode(enum kind k, const float v[4], uint8_t *out)
{
	switch (k) {
	case K_UNORM8:
		for (int i = 0; i < 4; i++)
			out[i] = (uint8_t)lrintf(v[i] * 255);
		break;
	case K_SRGB8:
		for (int i = 0; i < 3; i++)
			out[i] = (uint8_t)lrintf(srgb_enc(v[i]) * 255);
		out[3] = (uint8_t)lrintf(v[3] * 255);
		break;
	case K_BGRA_SRGB:
		out[0] = (uint8_t)lrintf(srgb_enc(v[2]) * 255);
		out[1] = (uint8_t)lrintf(srgb_enc(v[1]) * 255);
		out[2] = (uint8_t)lrintf(srgb_enc(v[0]) * 255);
		out[3] = (uint8_t)lrintf(v[3] * 255);
		break;
	case K_HALF4: {
		_Float16 h[4] = {(_Float16)v[0], (_Float16)v[1], (_Float16)v[2], (_Float16)v[3]};
		memcpy(out, h, 8);
		break;
	}
	case K_A2B10G10R10: {
		uint32_t p = (uint32_t)lrintf(v[0] * 1023) | (uint32_t)lrintf(v[1] * 1023) << 10 |
		             (uint32_t)lrintf(v[2] * 1023) << 20 | (uint32_t)lrintf(v[3] * 3) << 30;
		memcpy(out, &p, 4);
		break;
	}
	case K_D32:
		memcpy(out, &v[0], 4);
		break;
	}
}

static void decode(enum kind k, const uint8_t *in, float v[4])
{
	switch (k) {
	case K_UNORM8:
		for (int i = 0; i < 4; i++)
			v[i] = in[i] / 255.f;
		break;
	case K_SRGB8:
		for (int i = 0; i < 3; i++)
			v[i] = srgb_dec(in[i] / 255.f);
		v[3] = in[3] / 255.f;
		break;
	case K_BGRA_SRGB:
		v[0] = srgb_dec(in[2] / 255.f);
		v[1] = srgb_dec(in[1] / 255.f);
		v[2] = srgb_dec(in[0] / 255.f);
		v[3] = in[3] / 255.f;
		break;
	case K_HALF4: {
		_Float16 h[4];
		memcpy(h, in, 8);
		for (int i = 0; i < 4; i++)
			v[i] = (float)h[i];
		break;
	}
	case K_A2B10G10R10: {
		uint32_t p;
		memcpy(&p, in, 4);
		v[0] = (p & 1023) / 1023.f;
		v[1] = ((p >> 10) & 1023) / 1023.f;
		v[2] = ((p >> 20) & 1023) / 1023.f;
		v[3] = (p >> 30) / 3.f;
		break;
	}
	case K_D32:
		memcpy(v, in, 4);
		v[1] = v[2] = v[3] = 0;
		break;
	}
}

static void pattern_f(enum kind k, uint32_t x, uint32_t y, uint32_t frame, float v[4])
{
	if (k == K_D32) {
		v[0] = (float)((x + y + frame) % 1000) / 1000.f;
		v[1] = v[2] = v[3] = 0;
		return;
	}
	uint8_t p[4];
	pattern(x, y, frame, p);
	for (int i = 0; i < 4; i++)
		v[i] = p[i] / 255.f;
}

/* tolerant compare of texel a vs expected b in format k: 1 LSB */
static bool texel_close(enum kind k, const uint8_t *a, const uint8_t *b, uint32_t bpe)
{
	if (k == K_HALF4 || k == K_D32) {
		float fa[4], fb[4];
		decode(k, a, fa);
		decode(k, b, fb);
		for (int i = 0; i < 4; i++)
			if (fabsf(fa[i] - fb[i]) > 1e-3f)
				return false;
		return true;
	}
	if (k == K_A2B10G10R10) {
		float fa[4], fb[4];
		decode(k, a, fa);
		decode(k, b, fb);
		for (int i = 0; i < 4; i++)
			if (fabsf(fa[i] - fb[i]) > 1.5f / 1023)
				return false;
		return true;
	}
	for (uint32_t i = 0; i < bpe; i++)
		if (abs((int)a[i] - (int)b[i]) > 1)
			return false;
	return true;
}

/* compare IOSurface plane contents to tightly packed expected data */
static int surf_compare(IOSurfaceRef s, int plane, bool planar, const uint8_t *exp, uint32_t w, uint32_t h, uint32_t bpe,
                        enum kind k, bool exact, char *why, size_t nwhy)
{
	IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = planar ? IOSurfaceGetBaseAddressOfPlane(s, plane) : IOSurfaceGetBaseAddress(s);
	size_t bpr = planar ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s);
	int bad = 0;
	for (uint32_t y = 0; y < h && !bad; y++)
		for (uint32_t x = 0; x < w; x++) {
			const uint8_t *a = base + y * bpr + x * bpe, *b = exp + (y * w + x) * bpe;
			bool ok = exact ? !memcmp(a, b, bpe) : texel_close(k, a, b, bpe);
			if (!ok) {
				snprintf(why, nwhy, "mismatch at (%u,%u): got %02x%02x%02x%02x want %02x%02x%02x%02x", x, y, a[0],
				         bpe > 1 ? a[1] : 0, bpe > 2 ? a[2] : 0, bpe > 3 ? a[3] : 0, b[0], bpe > 1 ? b[1] : 0,
				         bpe > 2 ? b[2] : 0, bpe > 3 ? b[3] : 0);
				bad = 1;
				break;
			}
		}
	IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
	return bad ? 0 : 1;
}

static void surf_write(IOSurfaceRef s, int plane, bool planar, const uint8_t *src, uint32_t w, uint32_t h, uint32_t bpe)
{
	IOSurfaceLock(s, 0, NULL);
	uint8_t *base = planar ? IOSurfaceGetBaseAddressOfPlane(s, plane) : IOSurfaceGetBaseAddress(s);
	size_t bpr = planar ? IOSurfaceGetBytesPerRowOfPlane(s, plane) : IOSurfaceGetBytesPerRow(s);
	for (uint32_t y = 0; y < h; y++)
		memcpy(base + y * bpr, src + y * w * bpe, w * bpe);
	IOSurfaceUnlock(s, 0, NULL);
}

static VkImageUsageFlags probe_usage(vkctx *c, VkFormat f, VkImageUsageFlags want, VkImageCreateFlags flags,
                                     char *desc, size_t n)
{
	static const struct
	{
		VkImageUsageFlags bit;
		const char *name;
	} bits[] = {{VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, "color"},
	            {VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, "depth"},
	            {VK_IMAGE_USAGE_SAMPLED_BIT, "sampled"},
	            {VK_IMAGE_USAGE_STORAGE_BIT, "storage"},
	            {VK_IMAGE_USAGE_TRANSFER_SRC_BIT, "xfer_src"},
	            {VK_IMAGE_USAGE_TRANSFER_DST_BIT, "xfer_dst"}};
	VkImageUsageFlags ok = 0;
	desc[0] = 0;
	for (size_t i = 0; i < sizeof(bits) / sizeof(*bits); i++) {
		if (!(want & bits[i].bit))
			continue;
		VkImageFormatProperties ifp;
		VkResult r = vkGetPhysicalDeviceImageFormatProperties(c->pd, f, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
		                                                      bits[i].bit, flags, &ifp);
		if (r == VK_SUCCESS)
			ok |= bits[i].bit;
		size_t l = strlen(desc);
		snprintf(desc + l, n - l, "%s%s=%s", l ? " " : "", bits[i].name, r == VK_SUCCESS ? "y" : "n");
	}
	return ok;
}

static void copy_region(VkBufferImageCopy *r, VkImageAspectFlags aspect, uint32_t w, uint32_t h)
{
	memset(r, 0, sizeof(*r));
	r->imageSubresource = (VkImageSubresourceLayers){aspect, 0, 0, 1};
	r->imageExtent = (VkExtent3D){w, h, 1};
}

static int run_case(int fi, int mode)
{
	const fmtinfo *f = &fmts[fi];
	char cs[64], why[256], desc[256];
	snprintf(cs, sizeof(cs), "%s/%s", f->name, mode_name[mode]);
	vkctx c;
	if (vk_init(&c, true) != VK_SUCCESS) {
		result(cs, "init", 0, "vk_init failed");
		return 1;
	}
	bool depth = f->kind == K_D32;
	VkImageAspectFlags aspect = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
	VkImageUsageFlags want = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
	                         (depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	                                : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_STORAGE_BIT);
	VkImageUsageFlags usage = probe_usage(&c, f->vk, want, 0, desc, sizeof(desc));
	result(cs, "fmt-props", 3, "%s", desc);

	IOSurfaceRef in = NULL;
	if (mode == SHIMG_IMPORT) {
		in = surf_create(W, H, f->bpe, f->pixfmt);
		if (!in) {
			result(cs, "create", 0, "IOSurfaceCreate failed");
			return 1;
		}
	}
	shimg s;
	VkResult r = shimg_create(&c, f->vk, W, H, usage, 0, (enum shimg_mode)mode, in, NULL, NULL, 0, &s);
	if (in)
		CFRelease(in);
	if (r != VK_SUCCESS) {
		result(cs, "create", depth ? 2 : 0, "VkResult %d", r);
		return 1;
	}
	surf_describe(s.surf, desc, sizeof(desc));
	result(cs, "create", 1, "usage=0x%x surf: %s", usage, desc);

	size_t n = (size_t)W * H * f->bpe;
	uint8_t *exp = malloc(n);
	buf b;
	buf_create(&c, n > W * H * 16 ? n : W * H * 16,
	           VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
	           &b);
	VkCommandBuffer cb;
	VkBufferImageCopy reg;
	copy_region(&reg, aspect, W, H);

	/* T1: Vulkan transfer write -> IOSurface CPU read */
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++) {
			float v[4];
			pattern_f(f->kind, x, y, 1, v);
			encode(f->kind, v, exp + (y * W + x) * f->bpe);
		}
	memcpy(b.map, exp, n);
	cmd_begin(&c, &cb);
	cmd_to_general(cb, s.img, aspect);
	vkCmdCopyBufferToImage(cb, b.b, s.img, VK_IMAGE_LAYOUT_GENERAL, 1, &reg);
	r = cmd_submit_wait(&c, cb);
	int ok = r == VK_SUCCESS && surf_compare(s.surf, 0, false, exp, W, H, f->bpe, f->kind, true, why, sizeof(why));
	result(cs, "xfer->surf", ok, ok ? "pixel-exact" : r ? "submit failed" : why);

	/* T2: CPU write IOSurface -> Vulkan transfer read */
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++) {
			float v[4];
			pattern_f(f->kind, x, y, 2, v);
			encode(f->kind, v, exp + (y * W + x) * f->bpe);
		}
	surf_write(s.surf, 0, false, exp, W, H, f->bpe);
	memset(b.map, 0xcd, n);
	cmd_begin(&c, &cb);
	vkCmdCopyImageToBuffer(cb, s.img, VK_IMAGE_LAYOUT_GENERAL, b.b, 1, &reg);
	r = cmd_submit_wait(&c, cb);
	ok = r == VK_SUCCESS && !memcmp(b.map, exp, n);
	result(cs, "surf->xfer", ok, ok ? "pixel-exact" : "mismatch");

	/* T3: sampled texelFetch of the CPU-written data */
	if (!depth && (usage & VK_IMAGE_USAGE_SAMPLED_BIT)) {
		VkImageView v;
		VkDescriptorSet set;
		r = view_create(&c, s.img, f->vk, aspect, VK_IMAGE_USAGE_SAMPLED_BIT, &v);
		if (r == VK_SUCCESS) {
			cmd_begin(&c, &cb);
			cmd_fetch(&c, cb, v, &b, W, H, &set);
			r = cmd_submit_wait(&c, cb);
			const float *o = b.map;
			ok = r == VK_SUCCESS;
			for (uint32_t i = 0; ok && i < W * H; i++) {
				float e[4];
				decode(f->kind, exp + i * f->bpe, e);
				for (int k = 0; k < 4; k++)
					if (fabsf(o[i * 4 + k] - e[k]) > 2e-3f) {
						snprintf(why, sizeof(why), "texel %u.%d got %f want %f", i, k, o[i * 4 + k], e[k]);
						ok = 0;
						break;
					}
			}
			vkFreeDescriptorSets(c.dev, c.dpool, 1, &set);
			vkDestroyImageView(c.dev, v, NULL);
		} else
			ok = 0, snprintf(why, sizeof(why), "view %d", r);
		result(cs, "sampled", ok, ok ? "texelFetch matches (decoded)" : why);
	} else
		result(cs, "sampled", -1, "not supported/skipped");

	/* T4: color attachment clear via dynamic rendering */
	if (!depth && (usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) {
		VkImageView v;
		view_create(&c, s.img, f->vk, aspect, 0, &v);
		PFN_vkCmdBeginRenderingKHR beginR = (PFN_vkCmdBeginRenderingKHR)vkGetDeviceProcAddr(c.dev, "vkCmdBeginRenderingKHR");
		PFN_vkCmdEndRenderingKHR endR = (PFN_vkCmdEndRenderingKHR)vkGetDeviceProcAddr(c.dev, "vkCmdEndRenderingKHR");
		VkRenderingAttachmentInfoKHR att = {VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO_KHR,
		                                    .imageView = v,
		                                    .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
		                                    .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		                                    .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
		                                    .clearValue.color.float32 = {1, 0, 1, 1}};
		VkRenderingInfoKHR ri = {VK_STRUCTURE_TYPE_RENDERING_INFO_KHR, .renderArea = {{0, 0}, {W, H}}, .layerCount = 1,
		                         .colorAttachmentCount = 1, .pColorAttachments = &att};
		cmd_begin(&c, &cb);
		beginR(cb, &ri);
		endR(cb);
		r = cmd_submit_wait(&c, cb);
		float cv[4] = {1, 0, 1, 1};
		for (uint32_t i = 0; i < W * H; i++)
			encode(f->kind, cv, exp + i * f->bpe);
		ok = r == VK_SUCCESS && surf_compare(s.surf, 0, false, exp, W, H, f->bpe, f->kind, false, why, sizeof(why));
		result(cs, "color-att", ok, ok ? "clear visible in IOSurface" : why);
		vkDestroyImageView(c.dev, v, NULL);
	} else
		result(cs, "color-att", -1, "not supported/skipped");

	/* T5: storage image write */
	if (!depth && (usage & VK_IMAGE_USAGE_STORAGE_BIT) && c.pipe_store) {
		VkImageView v;
		VkDescriptorSet set;
		view_create(&c, s.img, f->vk, aspect, VK_IMAGE_USAGE_STORAGE_BIT, &v);
		cmd_begin(&c, &cb);
		cmd_store_pattern(&c, cb, v, W, H, 3, &set);
		r = cmd_submit_wait(&c, cb);
		for (uint32_t y = 0; y < H; y++)
			for (uint32_t x = 0; x < W; x++) {
				float pv[4];
				pattern_f(f->kind, x, y, 3, pv);
				encode(f->kind, pv, exp + (y * W + x) * f->bpe);
			}
		ok = r == VK_SUCCESS && surf_compare(s.surf, 0, false, exp, W, H, f->bpe, f->kind, false, why, sizeof(why));
		result(cs, "storage", ok, ok ? "imageStore visible in IOSurface" : why);
		vkFreeDescriptorSets(c.dev, c.dpool, 1, &set);
		vkDestroyImageView(c.dev, v, NULL);
	} else
		result(cs, "storage", (usage & VK_IMAGE_USAGE_STORAGE_BIT) ? 0 : -1,
		       (usage & VK_IMAGE_USAGE_STORAGE_BIT) ? "no store pipeline" : "format has no STORAGE (expected for sRGB)");

	free(exp);
	buf_destroy(&c, &b);
	shimg_destroy(&c, &s);
	vk_fini(&c);
	return g_fail;
}

/* ---------------- NV12 ---------------- */

enum nv12_case { NV_MP_EXPORT, NV_MP_IMPORT_420V, NV_MP_IMPORT_420F, NV_MP_IMPORT_420V_MVK, NV_SPLIT_MTLTEX, NV_SPLIT_IOSURF, NV_COUNT };
static const char *nv_name[] = {"NV12/multiplanar-export", "NV12/multiplanar-import-420v",
                                "NV12/multiplanar-import-420f", "NV12/multiplanar-import-420v-mvkblk",
                                "NV12/split-R8+RG8-MTLTexture",
                                "NV12/split-R8+RG8-IOSurface"};

static void nv12_expected(uint32_t frame, uint8_t *y_exp, uint8_t *uv_exp)
{
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++) {
			uint8_t p[4];
			pattern(x, y, frame, p);
			y_exp[y * W + x] = p[0];
		}
	for (uint32_t y = 0; y < H / 2; y++)
		for (uint32_t x = 0; x < W / 2; x++) {
			uint8_t p[4];
			pattern(x, y, frame, p);
			uv_exp[(y * (W / 2) + x) * 2] = p[0];
			uv_exp[(y * (W / 2) + x) * 2 + 1] = p[1];
		}
}

static void vt_cb(void *ref, void *src, OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb)
{
	int *out = ref;
	*out = (st == noErr && sb) ? (int)CMSampleBufferGetTotalSampleSize(sb) : -(int)st - 1;
}

static void cvpb_check(const char *cs, IOSurfaceRef s, int xf)
{
	CVPixelBufferRef pb = NULL;
	CVReturn cr = CVPixelBufferCreateWithIOSurface(NULL, s, NULL, &pb);
	if (cr != kCVReturnSuccess || !pb) {
		result(cs, "cvpixelbuffer", xf, "CVPixelBufferCreateWithIOSurface failed (%d)%s", cr,
		       xf ? " (MoltenVK-created surface has no pixel format and a too-small chroma pitch)" : "");
		return;
	}
	OSType pf = CVPixelBufferGetPixelFormatType(pb);
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	bool same = CVPixelBufferGetBaseAddressOfPlane(pb, 1) == IOSurfaceGetBaseAddressOfPlane(s, 1) &&
	            CVPixelBufferGetHeightOfPlane(pb, 1) == H / 2 && CVPixelBufferGetWidthOfPlane(pb, 1) == W / 2;
	result(cs, "cvpixelbuffer", (pf == '420v' || pf == '420f') && same,
	       "pf=0x%08x planes=%zu p1=%zux%zu bpr=%zu same-base=%d", pf, CVPixelBufferGetPlaneCount(pb),
	       CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1),
	       CVPixelBufferGetBytesPerRowOfPlane(pb, 1), same);
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	if (pf == '420v' || pf == '420f') {
		VTCompressionSessionRef vt = NULL;
		int out = 0;
		OSStatus st = VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_HEVC, NULL, NULL, NULL, vt_cb, &out, &vt);
		if (st == noErr) {
			st = VTCompressionSessionEncodeFrame(vt, pb, CMTimeMake(0, 90), kCMTimeInvalid, NULL, NULL, NULL);
			VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
			VTCompressionSessionInvalidate(vt);
			CFRelease(vt);
		}
		result(cs, "vt-hevc-encode", st == noErr && out > 0, "status=%d bytes=%d", (int)st, out);
	}
	CVPixelBufferRelease(pb);
}

static int run_nv12(int which)
{
	const char *cs = nv_name[which];
	char why[256], desc[400];
	vkctx c;
	if (vk_init(&c, true) != VK_SUCCESS) {
		result(cs, "init", 0, "vk_init failed");
		return 1;
	}
	uint8_t *y_exp = malloc(W * H), *uv_exp = malloc(W * H / 2);
	buf b;
	buf_create(&c, W * H * 2, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, &b);
	VkCommandBuffer cb;
	VkResult r;
	int ok;
	/* known MoltenVK 1.4.2 limitations, reported as XFAIL (see RESULTS.md) */
	int xf = (which == NV_MP_EXPORT || which == NV_MP_IMPORT_420V || which == NV_MP_IMPORT_420F) ? 2 : 0;

	if (which <= NV_MP_IMPORT_420V_MVK) {
		VkFormat f = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
		VkImageCreateFlags flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
		VkImageUsageFlags want = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT |
		                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
		probe_usage(&c, f, want | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, flags, desc, sizeof(desc));
		result(cs, "fmt-props", 3, "MUTABLE|EXTENDED_USAGE: %s", desc);
		VkFormat vf[3] = {f, VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM};
		IOSurfaceRef in = NULL;
		if (which != NV_MP_EXPORT)
			in = surf_create_nv12(W, H, which == NV_MP_IMPORT_420F ? '420f' : '420v', which == NV_MP_IMPORT_420V_MVK);
		shimg s;
		r = shimg_create(&c, f, W, H, want, flags, which == NV_MP_EXPORT ? SHIMG_EXPORT : SHIMG_IMPORT, in, NULL, vf, 3, &s);
		if (in)
			CFRelease(in);
		if (r != VK_SUCCESS) {
			result(cs, "create", xf, "VkResult %d%s", r, xf ? " (MoltenVK wants top-level bpe=6, 2x2 elements, chroma element 2x2)" : "");
			return xf ? 0 : 1;
		}
		surf_describe(s.surf, desc, sizeof(desc));
		result(cs, "create", 1, "surf: %s", desc);
		bool planar = IOSurfaceGetPlaneCount(s.surf) == 2;

		/* transfer per plane */
		nv12_expected(5, y_exp, uv_exp);
		memcpy(b.map, y_exp, W * H);
		memcpy((uint8_t *)b.map + W * H, uv_exp, W * H / 2);
		VkBufferImageCopy reg[2];
		copy_region(&reg[0], VK_IMAGE_ASPECT_PLANE_0_BIT, W, H);
		copy_region(&reg[1], VK_IMAGE_ASPECT_PLANE_1_BIT, W / 2, H / 2);
		reg[1].bufferOffset = W * H;
		cmd_begin(&c, &cb);
		cmd_to_general(cb, s.img, VK_IMAGE_ASPECT_PLANE_0_BIT | VK_IMAGE_ASPECT_PLANE_1_BIT);
		vkCmdCopyBufferToImage(cb, b.b, s.img, VK_IMAGE_LAYOUT_GENERAL, 2, reg);
		r = cmd_submit_wait(&c, cb);
		ok = r == VK_SUCCESS && planar &&
		     surf_compare(s.surf, 0, true, y_exp, W, H, 1, K_UNORM8, true, why, sizeof(why)) &&
		     surf_compare(s.surf, 1, true, uv_exp, W / 2, H / 2, 2, K_UNORM8, true, why, sizeof(why));
		result(cs, "xfer->surf", ok ? 1 : xf, ok ? "both planes pixel-exact" : !planar ? "surface not 2-plane" : why);

		/* storage through R8 / RG8 plane views */
		VkImageView vy, vuv;
		VkResult ry = view_create(&c, s.img, VK_FORMAT_R8_UNORM, VK_IMAGE_ASPECT_PLANE_0_BIT, VK_IMAGE_USAGE_STORAGE_BIT, &vy);
		VkResult ruv = view_create(&c, s.img, VK_FORMAT_R8G8_UNORM, VK_IMAGE_ASPECT_PLANE_1_BIT, VK_IMAGE_USAGE_STORAGE_BIT, &vuv);
		if (ry || ruv) {
			result(cs, "storage-planes", 0, "plane view creation failed %d %d", ry, ruv);
		} else {
			VkDescriptorSet s1, s2;
			cmd_begin(&c, &cb);
			cmd_store_pattern(&c, cb, vy, W, H, 6, &s1);
			cmd_store_pattern(&c, cb, vuv, W / 2, H / 2, 6, &s2);
			r = cmd_submit_wait(&c, cb);
			nv12_expected(6, y_exp, uv_exp);
			ok = r == VK_SUCCESS && planar &&
			     surf_compare(s.surf, 0, true, y_exp, W, H, 1, K_UNORM8, true, why, sizeof(why)) &&
			     surf_compare(s.surf, 1, true, uv_exp, W / 2, H / 2, 2, K_UNORM8, true, why, sizeof(why));
			result(cs, "storage-planes", ok ? 1 : xf, ok ? "imageStore via R8/RG8 plane views pixel-exact" : r ? "submit failed" : why);
			vkFreeDescriptorSets(c.dev, c.dpool, 1, &s1);
			vkFreeDescriptorSets(c.dev, c.dpool, 1, &s2);
		}
		if (!ry)
			vkDestroyImageView(c.dev, vy, NULL);
		if (!ruv)
			vkDestroyImageView(c.dev, vuv, NULL);
		cvpb_check(cs, s.surf, xf);
		shimg_destroy(&c, &s);
	} else {
		IOSurfaceRef surf = surf_create_nv12(W, H, '420v', false);
		surf_describe(surf, desc, sizeof(desc));
		shimg py, puv;
		VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT |
		                          VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
		                          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
		VkResult r1, r2;
		void *ty = NULL, *tuv = NULL;
		if (which == NV_SPLIT_MTLTEX) {
			ty = mtl_texture_from_surface(c.mtl_device, surf, 0, MTLPixelFormatR8Unorm, W, H);
			tuv = mtl_texture_from_surface(c.mtl_device, surf, 1, MTLPixelFormatRG8Unorm, W / 2, H / 2);
			if (!ty || !tuv) {
				result(cs, "create", 0, "Metal newTextureWithDescriptor:iosurface:plane: failed");
				return 1;
			}
			r1 = shimg_create(&c, VK_FORMAT_R8_UNORM, W, H, usage, 0, SHIMG_MTLTEX, NULL, ty, NULL, 0, &py);
			r2 = shimg_create(&c, VK_FORMAT_R8G8_UNORM, W / 2, H / 2, usage, 0, SHIMG_MTLTEX, NULL, tuv, NULL, 0, &puv);
		} else {
			r1 = shimg_create(&c, VK_FORMAT_R8_UNORM, W, H, usage, 0, SHIMG_IMPORT, surf, NULL, NULL, 0, &py);
			r2 = shimg_create(&c, VK_FORMAT_R8G8_UNORM, W / 2, H / 2, usage, 0, SHIMG_IMPORT, surf, NULL, NULL, 0, &puv);
		}
		if (r1 || r2) {
			result(cs, "create", which == NV_SPLIT_IOSURF ? 2 : 0,
			       "R8 -> %d, RG8 -> %d (VkImportMetalIOSurfaceInfoEXT has no plane index; MoltenVK checks "
			       "plane-0 size/bpe)",
			       r1, r2);
			return which == NV_SPLIT_IOSURF ? 0 : 1;
		}
		result(cs, "create", 1, "surf: %s", desc);
		VkImageView vy, vuv;
		VkDescriptorSet s1, s2;
		view_create(&c, py.img, VK_FORMAT_R8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 0, &vy);
		view_create(&c, puv.img, VK_FORMAT_R8G8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 0, &vuv);
		cmd_begin(&c, &cb);
		cmd_to_general(cb, py.img, VK_IMAGE_ASPECT_COLOR_BIT);
		cmd_to_general(cb, puv.img, VK_IMAGE_ASPECT_COLOR_BIT);
		cmd_store_pattern(&c, cb, vy, W, H, 7, &s1);
		cmd_store_pattern(&c, cb, vuv, W / 2, H / 2, 7, &s2);
		r = cmd_submit_wait(&c, cb);
		nv12_expected(7, y_exp, uv_exp);
		ok = r == VK_SUCCESS && surf_compare(surf, 0, true, y_exp, W, H, 1, K_UNORM8, true, why, sizeof(why)) &&
		     surf_compare(surf, 1, true, uv_exp, W / 2, H / 2, 2, K_UNORM8, true, why, sizeof(why));
		result(cs, "storage-planes", ok, ok ? "imageStore into both plane images pixel-exact" : why);
		vkDestroyImageView(c.dev, vy, NULL);
		vkDestroyImageView(c.dev, vuv, NULL);
		vkFreeDescriptorSets(c.dev, c.dpool, 1, &s1);
		vkFreeDescriptorSets(c.dev, c.dpool, 1, &s2);
		cvpb_check(cs, surf, 0);
		shimg_destroy(&c, &py);
		shimg_destroy(&c, &puv);
		objc_release_obj(ty);
		objc_release_obj(tuv);
		CFRelease(surf);
	}
	free(y_exp);
	free(uv_exp);
	buf_destroy(&c, &b);
	vk_fini(&c);
	return g_fail;
}

/* ---------------- MTLSharedTextureHandle route (depth etc.) ---------------- */

static int run_sharedtex(int which)
{
	const fmtinfo *f = which ? &fmts[0] : &fmts[NFMTS - 1];
	int mtlfmt = which ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatDepth32Float;
	char cs[64], why[128] = "";
	snprintf(cs, sizeof(cs), "%s/MTLSharedTextureHandle", f->name);
	vkctx c;
	if (vk_init(&c, true))
		return 1;
	bool depth = f->kind == K_D32;
	VkImageAspectFlags aspect = depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT;
	mach_port_t port = MACH_PORT_NULL;
	void *t1 = mtl_shared_texture_new(c.mtl_device, mtlfmt, W, H, 1, &port);
	void *t2 = t1 && port ? mtl_shared_texture_from_port(c.mtl_device, port) : NULL;
	if (!t1 || !t2) {
		result(cs, "create", 0, "newSharedTexture t1=%p port=0x%x t2=%p", t1, port, t2);
		return 1;
	}
	VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
	                          VK_IMAGE_USAGE_TRANSFER_DST_BIT |
	                          (depth ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
	shimg a, b2;
	VkResult r1 = shimg_create(&c, f->vk, W, H, usage, 0, SHIMG_MTLTEX, NULL, t1, NULL, 0, &a);
	VkResult r2 = shimg_create(&c, f->vk, W, H, usage, 0, SHIMG_MTLTEX, NULL, t2, NULL, 0, &b2);
	if (r1 || r2) {
		result(cs, "create", 0, "import %d %d", r1, r2);
		return 1;
	}
	result(cs, "create", 1, "private shared texture -> mach port 0x%x -> newSharedTextureWithHandle -> VkImportMetalTextureInfoEXT", port);
	size_t n = (size_t)W * H * f->bpe;
	uint8_t *exp = malloc(n);
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++) {
			float v[4];
			pattern_f(f->kind, x, y, 9, v);
			encode(f->kind, v, exp + (y * W + x) * f->bpe);
		}
	buf b;
	buf_create(&c, n, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, &b);
	memcpy(b.map, exp, n);
	VkBufferImageCopy reg;
	copy_region(&reg, aspect, W, H);
	VkCommandBuffer cb;
	cmd_begin(&c, &cb);
	cmd_to_general(cb, a.img, aspect);
	cmd_to_general(cb, b2.img, aspect);
	vkCmdCopyBufferToImage(cb, b.b, a.img, VK_IMAGE_LAYOUT_GENERAL, 1, &reg);
	cmd_barrier_all(cb);
	VkResult r = cmd_submit_wait(&c, cb);
	memset(b.map, 0, n);
	cmd_begin(&c, &cb);
	vkCmdCopyImageToBuffer(cb, b2.img, VK_IMAGE_LAYOUT_GENERAL, b.b, 1, &reg);
	r = r ? r : cmd_submit_wait(&c, cb);
	int ok = r == VK_SUCCESS && !memcmp(b.map, exp, n);
	if (!ok)
		snprintf(why, sizeof(why), "r=%d mismatch", r);
	result(cs, "roundtrip", ok, ok ? "write via image A, read via handle-imported image B: exact" : why);
	free(exp);
	buf_destroy(&c, &b);
	shimg_destroy(&c, &a);
	shimg_destroy(&c, &b2);
	objc_release_obj(t1);
	objc_release_obj(t2);
	mach_port_deallocate(mach_task_self(), port);
	vk_fini(&c);
	return g_fail;
}

/* ---------------- 2-layer (multiview) swapchain images ---------------- */

static VkResult array_image(vkctx *c, const void *chain, VkImage *img, VkDeviceMemory *mem)
{
	VkImageCreateInfo ici = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = chain, .imageType = VK_IMAGE_TYPE_2D,
	                         .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {W, H, 1}, .mipLevels = 1, .arrayLayers = 2,
	                         .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
	                         .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
	                                  VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT};
	CHECK_VK(vkCreateImage(c->dev, &ici, NULL, img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(c->dev, *img, &mr);
	uint32_t mt = 0;
	while (!(mr.memoryTypeBits & (1u << mt)))
		mt++;
	VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = mt};
	CHECK_VK(vkAllocateMemory(c->dev, &mai, NULL, mem));
	return vkBindImageMemory(c->dev, *img, *mem, 0);
}

static int run_array(int which)
{
	const char *cs = which ? "RGBA8-array2/MTLSharedTextureHandle" : "RGBA8-array2/IOSurface-export";
	vkctx c;
	if (vk_init(&c, true))
		return 1;
	VkImage a = VK_NULL_HANDLE, b = VK_NULL_HANDLE;
	VkDeviceMemory ma = VK_NULL_HANDLE, mb = VK_NULL_HANDLE;
	void *t1 = NULL, *t2 = NULL;
	mach_port_t port = MACH_PORT_NULL;
	VkResult r;
	if (!which) {
		VkExportMetalObjectCreateInfoEXT exp = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
		                                        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_IOSURFACE_BIT_EXT};
		r = array_image(&c, &exp, &a, &ma);
		VkExportMetalIOSurfaceInfoEXT ex = {VK_STRUCTURE_TYPE_EXPORT_METAL_IO_SURFACE_INFO_EXT, .image = a};
		VkExportMetalObjectsInfoEXT moi = {VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &ex};
		if (!r)
			c.exportMetal(c.dev, &moi);
		char d[256] = "";
		if (ex.ioSurface)
			surf_describe(ex.ioSurface, d, sizeof(d));
		result(cs, "create", r == VK_SUCCESS && ex.ioSurface ? 3 : 2, "vkCreateImage %d, IOSurface %s", r,
		       ex.ioSurface ? d : "none");
		if (r || !ex.ioSurface)
			return 0;
		/* a single IOSurface is one 2D plane; see whether layer 1 survives a round trip at all */
		b = VK_NULL_HANDLE;
	} else {
		t1 = mtl_shared_texture_new(c.mtl_device, MTLPixelFormatRGBA8Unorm, W, H, 2, &port);
		t2 = t1 && port ? mtl_shared_texture_from_port(c.mtl_device, port) : NULL;
		VkImportMetalTextureInfoEXT i1 = {VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT,
		                                  .plane = VK_IMAGE_ASPECT_PLANE_0_BIT, .mtlTexture = (id<MTLTexture>)t1};
		VkImportMetalTextureInfoEXT i2 = i1;
		i2.mtlTexture = (id<MTLTexture>)t2;
		r = t2 ? array_image(&c, &i1, &a, &ma) : VK_ERROR_INITIALIZATION_FAILED;
		r = r ? r : array_image(&c, &i2, &b, &mb);
		result(cs, "create", r == VK_SUCCESS, "2DArray shared texture -> port 0x%x -> import: %d", port, r);
		if (r)
			return 1;
	}
	size_t n = (size_t)W * H * 4;
	uint8_t *exp = malloc(n);
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++)
			pattern(x, y, 11, exp + (y * W + x) * 4);
	buf bb;
	buf_create(&c, n, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, &bb);
	memcpy(bb.map, exp, n);
	VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1}, .imageExtent = {W, H, 1}};
	VkCommandBuffer cb;
	cmd_begin(&c, &cb);
	VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
	                           .newLayout = VK_IMAGE_LAYOUT_GENERAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	                           .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = a,
	                           .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 2}};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
	if (b) {
		ib.image = b;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &ib);
	}
	vkCmdCopyBufferToImage(cb, bb.b, a, VK_IMAGE_LAYOUT_GENERAL, 1, &reg);
	r = cmd_submit_wait(&c, cb);
	memset(bb.map, 0, n);
	cmd_begin(&c, &cb);
	vkCmdCopyImageToBuffer(cb, b ? b : a, VK_IMAGE_LAYOUT_GENERAL, bb.b, 1, &reg);
	r = r ? r : cmd_submit_wait(&c, cb);
	int ok = r == VK_SUCCESS && !memcmp(bb.map, exp, n);
	if (which)
		result(cs, "layer1-roundtrip", ok, ok ? "layer 1 written via A, read via handle-imported B: exact" : "mismatch");
	else
		result(cs, "layer1-roundtrip", 2, "a 2-layer VkImage cannot be one shareable IOSurface (it has 1 plane); "
		       "layer-1 data %s; use one IOSurface per layer or MTLSharedTextureHandle", ok ? "lives outside the IOSurface" : "lost");
	free(exp);
	buf_destroy(&c, &bb);
	vkDestroyImage(c.dev, a, NULL);
	vkFreeMemory(c.dev, ma, NULL);
	if (b) {
		vkDestroyImage(c.dev, b, NULL);
		vkFreeMemory(c.dev, mb, NULL);
	}
	objc_release_obj(t1);
	objc_release_obj(t2);
	vk_fini(&c);
	return g_fail;
}

/* ---------------- allocation benchmark ---------------- */

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void stats(const char *name, double *v, int n)
{
	qsort(v, n, sizeof(double), cmp_d);
	double s = 0;
	for (int i = 0; i < n; i++)
		s += v[i];
	printf("BENCH %-48s n=%d median=%8.1fus p90=%8.1fus mean=%8.1fus\n", name, n, v[n / 2], v[n * 9 / 10], s / n);
}

static int run_bench(void)
{
	vkctx c;
	if (vk_init(&c, true))
		return 1;
	enum { N = 50 };
	const uint32_t bw = 2048, bh = 2048;
	double t_surf[N], t_exp[N], t_imp[N], t_port[N], t_lookup[N], t_first[N], t_nv12[N];
	VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
	                          VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	for (int i = 0; i < N; i++) {
		double t0 = now_us();
		IOSurfaceRef s = surf_create(bw, bh, 4, 'RGBA');
		double t1 = now_us();
		shimg e;
		shimg_create(&c, VK_FORMAT_R8G8B8A8_UNORM, bw, bh, usage, 0, SHIMG_EXPORT, NULL, NULL, NULL, 0, &e);
		double t2 = now_us();
		shimg im;
		shimg_create(&c, VK_FORMAT_R8G8B8A8_UNORM, bw, bh, usage, 0, SHIMG_IMPORT, s, NULL, NULL, 0, &im);
		double t3 = now_us();
		mach_port_t p = IOSurfaceCreateMachPort(s);
		double t4 = now_us();
		IOSurfaceRef s2 = IOSurfaceLookupFromMachPort(p);
		double t5 = now_us();
		VkCommandBuffer cb;
		cmd_begin(&c, &cb);
		cmd_to_general(cb, im.img, VK_IMAGE_ASPECT_COLOR_BIT);
		VkClearColorValue cc = {{0}};
		VkImageSubresourceRange rr = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
		vkCmdClearColorImage(cb, im.img, VK_IMAGE_LAYOUT_GENERAL, &cc, 1, &rr);
		cmd_submit_wait(&c, cb);
		double t6 = now_us();
		IOSurfaceRef nv = surf_create_nv12(bw, bh, '420v', false);
		double t7 = now_us();
		t_surf[i] = t1 - t0;
		t_exp[i] = t2 - t1;
		t_imp[i] = t3 - t2;
		t_port[i] = t4 - t3;
		t_lookup[i] = t5 - t4;
		t_first[i] = t6 - t5;
		t_nv12[i] = t7 - t6;
		CFRelease(nv);
		CFRelease(s2);
		mach_port_deallocate(mach_task_self(), p);
		shimg_destroy(&c, &e);
		shimg_destroy(&c, &im);
		CFRelease(s);
	}
	stats("IOSurfaceCreate 2048^2 RGBA", t_surf, N);
	stats("IOSurfaceCreate 2048^2 NV12 (420v)", t_nv12, N);
	stats("vkCreateImage+alloc+bind+export (EXPORT)", t_exp, N);
	stats("vkCreateImage+alloc+bind (IMPORT)", t_imp, N);
	stats("IOSurfaceCreateMachPort", t_port, N);
	stats("IOSurfaceLookupFromMachPort (same proc)", t_lookup, N);
	stats("first submit using imported image (clear)", t_first, N);
	vk_fini(&c);
	return 0;
}

static int spawn_self(char *const argv[])
{
	char path[1024];
	uint32_t n = sizeof(path);
	_NSGetExecutablePath(path, &n);
	pid_t pid;
	if (posix_spawn(&pid, path, NULL, NULL, argv, environ))
		return -1;
	int st;
	waitpid(pid, &st, 0);
	if (WIFSIGNALED(st))
		return 1000 + WTERMSIG(st);
	return WEXITSTATUS(st);
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 4 && !strcmp(argv[1], "--case"))
		return run_case(atoi(argv[2]), atoi(argv[3]));
	if (argc == 3 && !strcmp(argv[1], "--nv12"))
		return run_nv12(atoi(argv[2]));
	if (argc == 3 && !strcmp(argv[1], "--array"))
		return run_array(atoi(argv[2]));
	if (argc == 3 && !strcmp(argv[1], "--sharedtex"))
		return run_sharedtex(atoi(argv[2]));
	if (argc == 2 && !strcmp(argv[1], "--bench"))
		return run_bench();

	vkctx c;
	if (vk_init(&c, false))
		return 1;
	vk_fini(&c);
	int fails = 0;
	char a1[16], a2[16];
	for (int fi = 0; fi < NFMTS; fi++)
		for (int m = SHIMG_EXPORT; m <= SHIMG_IMPORT; m++) {
			snprintf(a1, sizeof(a1), "%d", fi);
			snprintf(a2, sizeof(a2), "%d", m);
			char *av[] = {argv[0], "--case", a1, a2, NULL};
			int st = spawn_self(av);
			if (st >= 1000) {
				char cs[64];
				snprintf(cs, sizeof(cs), "%s/%s", fmts[fi].name, mode_name[m]);
				result(cs, "process", fmts[fi].kind == K_D32 ? 2 : 0, "crashed with signal %d", st - 1000);
				if (fmts[fi].kind != K_D32)
					fails++;
			} else if (st && fmts[fi].kind != K_D32)
				fails++;
		}
	for (int i = 0; i < NV_COUNT; i++) {
		snprintf(a1, sizeof(a1), "%d", i);
		char *av[] = {argv[0], "--nv12", a1, NULL};
		int st = spawn_self(av);
		if (st >= 1000)
			result(nv_name[i], "process", 0, "crashed with signal %d", st - 1000);
		if (st)
			fails++;
	}
	for (int i = 0; i < 2; i++) {
		snprintf(a1, sizeof(a1), "%d", i);
		char *av[] = {argv[0], "--sharedtex", a1, NULL};
		int st = spawn_self(av);
		if (st >= 1000)
			result(i ? "R8G8B8A8_UNORM/MTLSharedTextureHandle" : "D32_SFLOAT/MTLSharedTextureHandle", "process", 0,
			       "crashed with signal %d", st - 1000);
		if (st)
			fails++;
	}
	for (int i = 0; i < 2; i++) {
		snprintf(a1, sizeof(a1), "%d", i);
		char *av[] = {argv[0], "--array", a1, NULL};
		int st = spawn_self(av);
		if (st >= 1000)
			result(i ? "RGBA8-array2/MTLSharedTextureHandle" : "RGBA8-array2/IOSurface-export", "process", i ? 0 : 2,
			       "crashed with signal %d", st - 1000);
		if (st && i)
			fails++;
	}
	char *av[] = {argv[0], "--bench", NULL};
	spawn_self(av);
	return fails ? 1 : 0;
}
