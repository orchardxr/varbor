#pragma once

#include <mach/mach.h>
#include <stdint.h>
#include <unistd.h>

#define XP_SERVICE_FMT "org.macvr.spike.iosurface.%d"

enum xp_type
{
	XP_HELLO = 1,     /* B -> service port; header local port = B's reply port (MAKE_SEND) */
	XP_HELLO_ACK,     /* A -> B; port descriptor: per-client receive port (MAKE_SEND) */
	XP_SURFACES,      /* B -> A; OOL ports: n IOSurface ports + optional MTLSharedEvent port */
	XP_FRAME,         /* B -> A; slot/frame/timeline value only */
	XP_RELEASE,       /* A -> B */
	XP_PING,
	XP_PONG,
	XP_BYE,
	XP_SHARED_TEX, /* A -> B; xp_surfaces layout, 1 MTLSharedTextureHandle port, 2 layers */
};

enum xp_frame_flags
{
	XPF_GPU_WAIT = 1,  /* A waits on the shared timeline semaphore on the GPU */
	XPF_DELAYED = 2,   /* B sends FRAME before it submits the GPU work (wait-before-signal test) */
	XPF_VERIFY = 4,
	XPF_PACED = 8,     /* B paces frames at a fixed rate, so nothing queues up */
};

#define XP_RING 3
#define XP_MAX_PORTS 8

typedef struct xp_msg
{
	mach_msg_header_t h;
	uint32_t type;
	uint32_t slot;
	uint32_t frame;
	uint32_t flags;
	uint64_t nonce;
	uint64_t value;
	uint64_t t_send_ns;
	uint64_t t_aux_ns;
	char info[64];
} xp_msg;

typedef struct xp_hello_ack
{
	mach_msg_header_t h;
	mach_msg_body_t body;
	mach_msg_port_descriptor_t port;
	uint32_t type;
	uint32_t pad;
	uint64_t nonce;
} xp_hello_ack;

typedef struct xp_surfaces
{
	mach_msg_header_t h;
	mach_msg_body_t body;
	mach_msg_ool_ports_descriptor_t ports;
	uint32_t type;
	uint32_t w, hgt, vkformat;
	uint32_t n_surfaces;
	uint32_t has_event;
	uint64_t t_send_ns;
	uint64_t event_value;
} xp_surfaces;

typedef union xp_rcv
{
	mach_msg_header_t h;
	struct
	{
		xp_msg m;
		mach_msg_max_trailer_t t;
	} msg;
	struct
	{
		xp_hello_ack m;
		mach_msg_max_trailer_t t;
	} ack;
	struct
	{
		xp_surfaces m;
		mach_msg_max_trailer_t t;
	} surf;
	uint8_t raw[1024];
} xp_rcv;

static inline uint32_t xp_type_of(const xp_rcv *r)
{
	if (r->h.msgh_bits & MACH_MSGH_BITS_COMPLEX)
		return r->h.msgh_id;
	return r->msg.m.type;
}

static inline kern_return_t xp_send(mach_port_t dest, xp_msg *m, mach_msg_type_name_t local_disp, mach_port_t local)
{
	m->h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, local_disp);
	m->h.msgh_size = sizeof(*m);
	m->h.msgh_remote_port = dest;
	m->h.msgh_local_port = local;
	m->h.msgh_id = (mach_msg_id_t)m->type;
	return mach_msg(&m->h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(*m), 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
}

/* ms < 0 blocks, ms == 0 polls */
static inline kern_return_t xp_recv(mach_port_t port, xp_rcv *r, int ms)
{
	return mach_msg(&r->h, MACH_RCV_MSG | (ms >= 0 ? MACH_RCV_TIMEOUT : 0), 0, sizeof(*r), port,
	                ms >= 0 ? (mach_msg_timeout_t)ms : MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
}

static inline const char *xp_arch(void)
{
#if defined(__x86_64__)
	return "x86_64";
#else
	return "arm64";
#endif
}
