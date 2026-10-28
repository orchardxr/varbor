/* Process A (server role): owns the bootstrap service, imports the client's IOSurfaces and
 * MTLSharedEvent, GPU-waits on the shared timeline and verifies every frame pixel-exact. */
#import <Metal/Metal.h>
#include <mach/notify.h>
#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>
#include "vkutil.h"
#include "xproc.h"

extern kern_return_t bootstrap_register2(mach_port_t bp, name_t service_name, mach_port_t sp, uint64_t flags);

@protocol MTLDeviceSPI <MTLDevice>
- (id<MTLSharedEvent>)newSharedEventWithMachPort:(mach_port_t)machPort;
@end

static char g_case[64] = "xproc";
static int g_fail;

static void result(const char *test, int ok, const char *fmt, ...)
{
	char msg[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	const char *tag = ok == 1 ? "PASS" : ok == 0 ? "FAIL" : ok == 2 ? "XFAIL" : "INFO";
	printf("%-5s %-34s %-14s %s\n", tag, g_case, test, msg);
	fflush(stdout);
	if (ok == 0)
		g_fail = 1;
}

static int cmp_d(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void stat_line(const char *test, const char *what, double *v, int n)
{
	if (!n)
		return;
	qsort(v, n, sizeof(double), cmp_d);
	double s = 0;
	for (int i = 0; i < n; i++)
		s += v[i];
	result(test, 3, "%-30s n=%4d median=%8.1fus p99=%8.1fus mean=%8.1fus max=%8.1fus", what, n, v[n / 2],
	       v[(n * 99) / 100], s / n, v[n - 1]);
}

typedef struct slot
{
	shimg img;
	buf rb;
	VkCommandBuffer cb;
	VkFence fence;
} slot;

#define MAXF 4096
typedef struct phase_stats
{
	int n, bad;
	double oneway[MAXF], submit[MAXF], done[MAXF], verify[MAXF];
	uint64_t t_first, t_last;
} phase_stats;

#define PH_MASK (XPF_GPU_WAIT | XPF_DELAYED | XPF_PACED)
static phase_stats g_ph[PH_MASK + 1];
static const char *phase_name(int ph)
{
	switch (ph) {
	case 0: return "cpu-wait";
	case XPF_GPU_WAIT: return "gpu-wait";
	case XPF_PACED: return "cpu-wait-90Hz";
	case XPF_GPU_WAIT | XPF_PACED: return "gpu-wait-90Hz";
	default: return "gpu-wait-before-signal";
	}
}

static bool verify_frame(const uint8_t *p, uint32_t w, uint32_t h, uint32_t frame, char *why, size_t n)
{
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++) {
			uint8_t e[4];
			pattern(x, y, frame, e);
			const uint8_t *g = p + (y * w + x) * 4;
			if (memcmp(g, e, 4)) {
				snprintf(why, n, "frame %u (%u,%u) got %02x%02x%02x%02x want %02x%02x%02x%02x", frame, x, y, g[0],
				         g[1], g[2], g[3], e[0], e[1], e[2], e[3]);
				return false;
			}
		}
	return true;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	int timeout_ms = 30000;
	for (int i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--timeout") && i + 1 < argc)
			timeout_ms = atoi(argv[++i]);

	char name[128];
	snprintf(name, sizeof(name), XP_SERVICE_FMT, getuid());
	mach_port_t svc = MACH_PORT_NULL;
	kern_return_t kr = bootstrap_check_in(bootstrap_port, name, &svc);
	const char *api = "bootstrap_check_in";
	if (kr != KERN_SUCCESS) {
		mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &svc);
		mach_port_insert_right(mach_task_self(), svc, svc, MACH_MSG_TYPE_MAKE_SEND);
		kr = bootstrap_register2(bootstrap_port, name, svc, 0);
		api = "bootstrap_register2";
	}
	if (kr != KERN_SUCCESS) {
		result("register", 0, "%s: %d %s", name, kr, bootstrap_strerror(kr));
		return 1;
	}
	printf("# server: registered %s via %s\n", name, api);

	vkctx c;
	if (vk_init(&c, true)) {
		result("vk-init", 0, "failed");
		return 1;
	}
	printf("READY\n");

	xp_rcv r;
	kr = xp_recv(svc, &r, timeout_ms);
	if (kr != KERN_SUCCESS || xp_type_of(&r) != XP_HELLO) {
		result("hello", 0, "no HELLO (kr=0x%x)", kr);
		return 1;
	}
	uint64_t t_hello = now_ns();
	mach_port_t client = r.h.msgh_remote_port;
	uint64_t nonce = r.msg.m.nonce;
	snprintf(g_case, sizeof(g_case), "xproc[client=%s]", r.msg.m.info);
	result("hello", client != MACH_PORT_NULL, "client reply port 0x%x nonce=%016llx bootstrap msg latency %.1fus",
	       client, nonce, (t_hello - r.msg.m.t_send_ns) / 1000.0);
	printf("# server driver: %s\n", c.driver);

	mach_port_t pc;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &pc);
	xp_hello_ack ack = {0};
	ack.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	ack.h.msgh_size = sizeof(ack);
	ack.h.msgh_remote_port = client;
	ack.h.msgh_id = XP_HELLO_ACK;
	ack.body.msgh_descriptor_count = 1;
	ack.port.name = pc;
	ack.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
	ack.port.type = MACH_MSG_PORT_DESCRIPTOR;
	ack.type = XP_HELLO_ACK;
	ack.nonce = nonce;
	kr = mach_msg(&ack.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(ack), 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
	if (kr) {
		result("hello-ack", 0, "send 0x%x", kr);
		return 1;
	}
	mach_port_t prev;
	mach_port_request_notification(mach_task_self(), pc, MACH_NOTIFY_NO_SENDERS, 1, pc, MACH_MSG_TYPE_MAKE_SEND_ONCE,
	                               &prev);

	slot slots[XP_MAX_PORTS] = {0};
	shimg rev = {0};
	void *shtex = NULL;
	VkImage shimg_img = VK_NULL_HANDLE;
	VkDeviceMemory shimg_mem = VK_NULL_HANDLE;
	uint32_t nsurf = 0, W = 0, H = 0;
	VkSemaphore sem = VK_NULL_HANDLE;
	id<MTLSharedEvent> ev = nil;
	int npings = 0;
	uint32_t last_frame = 0, last_slot = 0;
	bool bye = false;

	while (!bye) {
		kr = xp_recv(pc, &r, timeout_ms);
		if (kr != KERN_SUCCESS) {
			result("protocol", 0, "receive failed/timeout 0x%x", kr);
			break;
		}
		uint64_t t_recv = now_ns();
		uint32_t type = xp_type_of(&r);
		if (r.h.msgh_id == MACH_NOTIFY_NO_SENDERS) {
			result("protocol", 0, "client vanished before BYE");
			break;
		}
		switch (type) {
		case XP_PING: {
			xp_msg m = {.type = XP_PONG, .t_send_ns = r.msg.m.t_send_ns, .t_aux_ns = t_recv};
			xp_send(client, &m, 0, MACH_PORT_NULL);
			npings++;
			break;
		}
		case XP_SURFACES: {
			xp_surfaces *s = &r.surf.m;
			mach_port_t *ports = (mach_port_t *)s->ports.address;
			uint32_t np = s->ports.count;
			W = s->w;
			H = s->hgt;
			nsurf = s->n_surfaces;
			double t_msg = (t_recv - s->t_send_ns) / 1000.0;
			double t0 = now_us();
			bool ok = np == nsurf + (s->has_event ? 1 : 0) && nsurf <= XP_MAX_PORTS;
			IOSurfaceRef surfs[XP_MAX_PORTS] = {0};
			for (uint32_t i = 0; ok && i < nsurf; i++) {
				surfs[i] = IOSurfaceLookupFromMachPort(ports[i]);
				ok = surfs[i] != NULL;
			}
			double t1 = now_us();
			for (uint32_t i = 0; ok && i < nsurf; i++) {
				ok = shimg_create(&c, (VkFormat)s->vkformat, W, H,
				                  VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, 0, SHIMG_IMPORT, surfs[i],
				                  NULL, NULL, 0, &slots[i].img) == VK_SUCCESS;
				CFRelease(surfs[i]);
			}
			double t2 = now_us();
			char d[256];
			if (ok)
				surf_describe(slots[0].img.surf, d, sizeof(d));
			result("import-surfaces", ok, "%u IOSurface ports in one OOL-ports msg (%.1fus in flight); "
			       "lookup %.1fus, vk import %.1fus total; %s",
			       nsurf, t_msg, t1 - t0, t2 - t1, ok ? d : "");
			if (s->has_event) {
				double t3 = now_us();
				ev = [(id<MTLDeviceSPI>)c.mtl_device newSharedEventWithMachPort:ports[nsurf]];
				uint64_t before = ev ? ev.signaledValue : 0;
				VkImportMetalSharedEventInfoEXT imp = {VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT,
				                                       .mtlSharedEvent = ev};
				/* MoltenVK overwrites signaledValue with initialValue on import, so pass the current value */
				VkSemaphoreTypeCreateInfo tci = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .pNext = &imp,
				                                 .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE, .initialValue = before};
				VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &tci};
				VkResult vr = ev ? vkCreateSemaphore(c.dev, &sci, NULL, &sem) : VK_ERROR_INITIALIZATION_FAILED;
				double t4 = now_us();
				result("import-event", vr == VK_SUCCESS && ev.signaledValue == before,
				       "-[MTLDevice newSharedEventWithMachPort:] (SPI) -> %s, signaledValue=%llu (client set %llu), "
				       "VkSemaphore timeline import %d, %.1fus",
				       ev ? "ok" : "nil", ev ? ev.signaledValue : 0, s->event_value, vr, t4 - t3);
			}
			for (uint32_t i = 0; i < np; i++)
				mach_port_deallocate(mach_task_self(), ports[i]);
			vm_deallocate(mach_task_self(), (vm_address_t)ports, np * sizeof(mach_port_t));

			/* reverse direction (Monado's swapchain case): server allocates + fills, client imports */
			enum { RW = 256, RH = 256 };
			buf up;
			buf_create(&c, RW * RH * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &up);
			for (uint32_t y = 0; y < RH; y++)
				for (uint32_t x = 0; x < RW; x++)
					pattern(x, y, 77, (uint8_t *)up.map + (y * RW + x) * 4);
			bool rok = shimg_create(&c, VK_FORMAT_R8G8B8A8_UNORM, RW, RH,
			                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
			                            VK_IMAGE_USAGE_SAMPLED_BIT,
			                        0, SHIMG_EXPORT, NULL, NULL, NULL, 0, &rev) == VK_SUCCESS;
			VkCommandBuffer cb;
			cmd_begin(&c, &cb);
			for (uint32_t i = 0; i < nsurf; i++)
				cmd_to_general(cb, slots[i].img.img, VK_IMAGE_ASPECT_COLOR_BIT);
			if (rok) {
				cmd_to_general(cb, rev.img, VK_IMAGE_ASPECT_COLOR_BIT);
				VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
				                         .imageExtent = {RW, RH, 1}};
				vkCmdCopyBufferToImage(cb, up.b, rev.img, VK_IMAGE_LAYOUT_GENERAL, 1, &reg);
			}
			cmd_submit_wait(&c, cb);
			buf_destroy(&c, &up);
			if (rok) {
				mach_port_t rp = IOSurfaceCreateMachPort(rev.surf);
				xp_surfaces rm = {0};
				rm.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
				rm.h.msgh_size = sizeof(rm);
				rm.h.msgh_remote_port = client;
				rm.h.msgh_id = XP_SURFACES;
				rm.body.msgh_descriptor_count = 1;
				rm.ports.address = &rp;
				rm.ports.count = 1;
				rm.ports.copy = MACH_MSG_PHYSICAL_COPY;
				rm.ports.disposition = MACH_MSG_TYPE_MOVE_SEND;
				rm.ports.type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
				rm.type = XP_SURFACES;
				rm.w = RW;
				rm.hgt = RH;
				rm.vkformat = VK_FORMAT_R8G8B8A8_UNORM;
				rm.n_surfaces = 1;
				rm.t_send_ns = now_ns();
				rok = mach_msg(&rm.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(rm), 0, MACH_PORT_NULL, 2000,
				               MACH_PORT_NULL) == KERN_SUCCESS;
			}
			if (!rok)
				result("reverse-export", 0, "server-side export/send failed");

			/* 2-layer swapchain image: IOSurface cannot be an array, so use MTLSharedTextureHandle */
			mach_port_t tp = MACH_PORT_NULL;
			shtex = mtl_shared_texture_new(c.mtl_device, MTLPixelFormatRGBA8Unorm, RW, RH, 2, &tp);
			rok = shtex && tp &&
			      image_from_mtltex(&c, shtex, VK_FORMAT_R8G8B8A8_UNORM, RW, RH, 2,
			                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, &shimg_img,
			                        &shimg_mem) == VK_SUCCESS;
			if (rok) {
				buf up2;
				buf_create(&c, RW * RH * 4, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &up2);
				for (uint32_t y = 0; y < RH; y++)
					for (uint32_t x = 0; x < RW; x++)
						pattern(x, y, 78, (uint8_t *)up2.map + (y * RW + x) * 4);
				VkCommandBuffer cb2;
				cmd_begin(&c, &cb2);
				VkImageMemoryBarrier ib = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
				                           .dstAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
				                           .newLayout = VK_IMAGE_LAYOUT_GENERAL,
				                           .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				                           .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				                           .image = shimg_img,
				                           .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 2}};
				vkCmdPipelineBarrier(cb2, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0,
				                     NULL, 0, NULL, 1, &ib);
				VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 1},
				                         .imageExtent = {RW, RH, 1}};
				vkCmdCopyBufferToImage(cb2, up2.b, shimg_img, VK_IMAGE_LAYOUT_GENERAL, 1, &reg);
				cmd_submit_wait(&c, cb2);
				buf_destroy(&c, &up2);
				xp_surfaces rm = {0};
				rm.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
				rm.h.msgh_size = sizeof(rm);
				rm.h.msgh_remote_port = client;
				rm.h.msgh_id = XP_SHARED_TEX;
				rm.body.msgh_descriptor_count = 1;
				rm.ports.address = &tp;
				rm.ports.count = 1;
				rm.ports.copy = MACH_MSG_PHYSICAL_COPY;
				rm.ports.disposition = MACH_MSG_TYPE_MOVE_SEND;
				rm.ports.type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
				rm.type = XP_SHARED_TEX;
				rm.w = RW;
				rm.hgt = RH;
				rm.vkformat = VK_FORMAT_R8G8B8A8_UNORM;
				rm.n_surfaces = 1;
				rok = mach_msg(&rm.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(rm), 0, MACH_PORT_NULL, 2000,
				               MACH_PORT_NULL) == KERN_SUCCESS;
			}
			if (!rok)
				result("reverse-sharedtex", 0, "server-side MTLSharedTextureHandle export/send failed");
			for (uint32_t i = 0; i < nsurf; i++) {
				slot *sl = &slots[i];
				buf_create(&c, (VkDeviceSize)W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &sl->rb);
				VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
				                                  .commandPool = c.pool, .commandBufferCount = 1};
				vkAllocateCommandBuffers(c.dev, &ai, &sl->cb);
				VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
				vkBeginCommandBuffer(sl->cb, &bi);
				cmd_barrier_all(sl->cb);
				VkBufferImageCopy reg = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
				                         .imageExtent = {W, H, 1}};
				vkCmdCopyImageToBuffer(sl->cb, sl->img.img, VK_IMAGE_LAYOUT_GENERAL, sl->rb.b, 1, &reg);
				cmd_barrier_all(sl->cb);
				vkEndCommandBuffer(sl->cb);
				VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
				vkCreateFence(c.dev, &fci, NULL, &sl->fence);
			}
			break;
		}
		case XP_FRAME: {
			xp_msg *m = &r.msg.m;
			if (m->slot >= nsurf) {
				result("frame", 0, "bad slot %u", m->slot);
				bye = true;
				break;
			}
			slot *sl = &slots[m->slot];
			int ph = m->flags & PH_MASK;
			phase_stats *ps = &g_ph[ph];
			VkTimelineSemaphoreSubmitInfo ts = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
			                                    .waitSemaphoreValueCount = 1, .pWaitSemaphoreValues = &m->value};
			VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
			VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &sl->cb};
			if (m->flags & XPF_GPU_WAIT) {
				si.pNext = &ts;
				si.waitSemaphoreCount = 1;
				si.pWaitSemaphores = &sem;
				si.pWaitDstStageMask = &stage;
			}
			vkResetFences(c.dev, 1, &sl->fence);
			VkResult vr = vkQueueSubmit(c.q, 1, &si, sl->fence);
			uint64_t t_sub = now_ns();
			vr = vr ? vr : vkWaitForFences(c.dev, 1, &sl->fence, VK_TRUE, 5000000000ull);
			uint64_t t_done = now_ns();
			xp_msg rel = {.type = XP_RELEASE, .slot = m->slot, .frame = m->frame, .t_send_ns = now_ns(),
			              .t_aux_ns = t_done};
			xp_send(client, &rel, 0, MACH_PORT_NULL);
			char why[160] = "";
			double tv0 = now_us();
			bool ok = vr == VK_SUCCESS && verify_frame(sl->rb.map, W, H, m->frame, why, sizeof(why));
			double tv1 = now_us();
			if (ps->n < MAXF) {
				if (!ps->n)
					ps->t_first = t_recv;
				ps->t_last = t_done;
				ps->oneway[ps->n] = (t_recv - m->t_send_ns) / 1000.0;
				ps->submit[ps->n] = (t_sub - t_recv) / 1000.0;
				ps->done[ps->n] = (t_done - t_recv) / 1000.0;
				ps->verify[ps->n] = tv1 - tv0;
				ps->n++;
			}
			if (!ok) {
				ps->bad++;
				if (ps->bad < 4)
					result(phase_name(ph), 0, "%s", vr ? "vk error" : why);
			}
			if (ph == (XPF_GPU_WAIT | XPF_DELAYED)) {
				double wait_ms = (t_done - t_recv) / 1e6, sub_ms = (t_sub - t_recv) / 1e6;
				double delay_ms = m->t_aux_ns / 1e6;
				bool gpu_waited = wait_ms >= delay_ms * 0.8 && sub_ms < delay_ms * 0.25;
				result("gpu-wait-x-proc", ok && gpu_waited,
				       "frame %u: submit returned after %.2fms, copy done after %.2fms (client delayed signal "
				       "%.0fms), pixels %s",
				       m->frame, sub_ms, wait_ms, delay_ms, ok ? "exact" : "WRONG");
			}
			last_frame = m->frame;
			last_slot = m->slot;
			break;
		}
		case XP_BYE:
			bye = true;
			break;
		default:
			result("protocol", 0, "unexpected msg type %u", type);
			bye = true;
		}
	}

	if (npings)
		result("ping", 3, "%d PING/PONG round trips answered (client reports RTT)", npings);
	for (int p = 0; p <= PH_MASK; p++) {
		phase_stats *ps = &g_ph[p];
		if (!ps->n || (p & XPF_DELAYED))
			continue;
		double secs = (ps->t_last - ps->t_first) / 1e9;
		result(phase_name(p), ps->bad == 0, "%d frames %ux%u ring=%u, %d mismatches, %.1f frames/s through A", ps->n, W,
		       H, nsurf, ps->bad, secs > 0 ? (ps->n - 1) / secs : 0);
		stat_line(phase_name(p), "FRAME msg one-way", ps->oneway, ps->n);
		stat_line(phase_name(p), "A: recv->vkQueueSubmit returned", ps->submit, ps->n);
		stat_line(phase_name(p), "A: recv->copy complete", ps->done, ps->n);
		stat_line(phase_name(p), "A: CPU verify (not in path)", ps->verify, ps->n);
	}

	/* client has exited or is exiting: its send right to pc dies -> no-senders notification */
	kr = xp_recv(pc, &r, 5000);
	result("client-exit", kr == KERN_SUCCESS && r.h.msgh_id == MACH_NOTIFY_NO_SENDERS,
	       "MACH_NOTIFY_NO_SENDERS on per-client port %s", kr ? "NOT received" : "received");

	if (nsurf) {
		slot *sl = &slots[last_slot];
		memset(sl->rb.map, 0, sl->rb.size);
		VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &sl->cb};
		vkResetFences(c.dev, 1, &sl->fence);
		vkQueueSubmit(c.q, 1, &si, sl->fence);
		vkWaitForFences(c.dev, 1, &sl->fence, VK_TRUE, 5000000000ull);
		char why[160] = "";
		bool ok = verify_frame(sl->rb.map, W, H, last_frame, why, sizeof(why));
		result("surface-outlives-client", ok, "after client exit, imported IOSurface still holds frame %u%s%s",
		       last_frame, ok ? "" : ": ", why);
	}

	vkDeviceWaitIdle(c.dev);
	for (uint32_t i = 0; i < nsurf; i++) {
		vkDestroyFence(c.dev, slots[i].fence, NULL);
		buf_destroy(&c, &slots[i].rb);
		shimg_destroy(&c, &slots[i].img);
	}
	if (sem)
		vkDestroySemaphore(c.dev, sem, NULL);
	shimg_destroy(&c, &rev);
	if (shimg_img) {
		vkDestroyImage(c.dev, shimg_img, NULL);
		vkFreeMemory(c.dev, shimg_mem, NULL);
	}
	objc_release_obj(shtex);
	[ev release];
	vk_fini(&c);
	return g_fail;
}
