// Overlay compositor of the web helper (the vrcompositor scene-graph role): an XR_EXTX_overlay session on the
// OpenXR runtime that shows rectangles of one page texture as quad layers in STAGE space.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mxr mxr;

typedef void (*mxr_log_fn)(const char *line);

typedef struct mxr_quad
{
	float position[3];
	float orientation[4]; // x y z w
	float width, height;  // metres
	int32_t rect[4];      // x y w h in page pixels
	float color_scale[4]; // premultiplied: rgb * opacity, opacity
} mxr_quad;

typedef struct mxr_stats
{
	uint64_t frames;          // xrEndFrame calls
	uint64_t images;          // swapchain images produced
	uint64_t uploads;         // mxr_upload calls
	uint64_t upload_pixels;   // pixels converted and staged
	double upload_cpu_ms;     // CPU time in mxr_upload (conversion)
	double copy_gpu_wait_ms;  // CPU time waiting for the staging->swapchain copy
	int session_running;
	int color_scale_bias;
} mxr_stats;

// runtime: path of the OpenXR runtime library (libopenxr_wivrn.dylib). Starts the XR thread; the session is
// created when quads are set and ended after `linger_ms` without quads. Never blocks on the runtime.
mxr *mxr_create(const char *runtime, uint32_t page_width, uint32_t page_height, uint32_t linger_ms, mxr_log_fn log);

// Copies a rect of page pixels (BGRA8, premultiplied, sRGB-encoded, as a WebKit snapshot) into the page texture.
// Converts to premultiplied-in-linear sRGB (the swapchain is _SRGB), so edges blend like the browser's
// own premultiplied result over black. Safe from any thread.
void mxr_upload(mxr *m, int32_t x, int32_t y, int32_t w, int32_t h, const void *bgra, size_t stride);

// Replaces the layer list (drawn in order, last on top). n = 0 hides everything.
void mxr_set_quads(mxr *m, const mxr_quad *quads, uint32_t n);

void mxr_get_stats(mxr *m, mxr_stats *out);

void mxr_destroy(mxr *m);

#ifdef __cplusplus
}
#endif
