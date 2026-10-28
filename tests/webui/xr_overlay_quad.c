// Spike for the web helper's compositor (app/Sources/CMacVRXR/mxr.c): one overlay session, one quad.
// A 512x128 test card (white ring + bar on transparent, alpha ramp) is shown 1 m wide, 1.5 m in front of the
// stage origin at 1.6 m, for N seconds.
//   xr_overlay_quad <runtime.dylib> [seconds]
#include "mxr.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <runtime.dylib> [seconds]\n", argv[0]);
		return 2;
	}
	double secs = argc > 2 ? atof(argv[2]) : 10;
	enum { W = 512, H = 128 };
	static uint8_t px[W * H * 4];
	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			double dx = x - 64, dy = y - 64, r = sqrt(dx * dx + dy * dy);
			double a = fabs(r - 40) < 8 ? 1 : 0;
			if (x > 140 && x < 500 && y > 50 && y < 78)
				a = (x - 140) / 360.0;
			uint8_t v = (uint8_t)lround(a * 255);
			uint8_t *p = px + (y * W + x) * 4;
			p[0] = p[1] = p[2] = v; // premultiplied white
			p[3] = v;
		}
	}
	mxr *m = mxr_create(argv[1], 2048, 2048, 500, NULL);
	mxr_upload(m, 100, 200, W, H, px, W * 4);
	mxr_quad q = {
	    .position = {0, 1.6f, -1.5f},
	    .orientation = {0, 0, 0, 1},
	    .width = 1.0f,
	    .height = 0.25f,
	    .rect = {100, 200, W, H},
	    .color_scale = {1, 1, 1, 1},
	};
	mxr_set_quads(m, &q, 1);
	for (int i = 0; i < secs * 10; i++) {
		usleep(100000);
		if (i % 20 == 19) {
			mxr_stats s;
			mxr_get_stats(m, &s);
			fprintf(stderr, "t=%.0fs frames %llu images %llu running %d csb %d\n", (i + 1) / 10.0,
			        (unsigned long long)s.frames, (unsigned long long)s.images, s.session_running,
			        s.color_scale_bias);
		}
	}
	mxr_set_quads(m, NULL, 0);
	usleep(1000000);
	mxr_destroy(m);
	return 0;
}
