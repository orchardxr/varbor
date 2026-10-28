// Checks wivrn::recentered_stage_offset (WiVRn patch 0006-recenter-stage).
//   clang++ -std=c++20 -I third_party/wivrn/server -I build/monado-snapshot/src/xrt/include \
//       tests/wivrn/recenter_stage_test.cpp -o build/tests/recenter_stage_test && build/tests/recenter_stage_test
#include "driver/recenter_stage.h"

#include <cmath>
#include <cstdio>

static int failures = 0;

static xrt_quat quat_axis_angle(float ax, float ay, float az, float deg)
{
	float n = std::sqrt(ax * ax + ay * ay + az * az);
	float h = deg * float(M_PI) / 360.f;
	float s = std::sin(h) / n;
	return {ax * s, ay * s, az * s, std::cos(h)};
}

static xrt_quat mul(const xrt_quat & a, const xrt_quat & b)
{
	return {
	        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
	        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
	        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
	        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
	};
}

static xrt_vec3 rotate(const xrt_quat & q, const xrt_vec3 & v)
{
	xrt_quat p{v.x, v.y, v.z, 0};
	xrt_quat c{-q.x, -q.y, -q.z, q.w};
	auto r = mul(mul(q, p), c);
	return {r.x, r.y, r.z};
}

static void check(bool ok, const char * what)
{
	if (!ok)
	{
		std::printf("FAIL %s\n", what);
		failures++;
	}
}

static bool near(float a, float b, float eps = 1e-4f)
{
	return std::fabs(a - b) < eps;
}

// Head in the new stage space = inverse(stage) * head.
static xrt_pose head_in_stage(const xrt_pose & stage, const xrt_pose & head)
{
	xrt_quat inv{-stage.orientation.x, -stage.orientation.y, -stage.orientation.z, stage.orientation.w};
	xrt_vec3 d{head.position.x - stage.position.x, head.position.y - stage.position.y, head.position.z - stage.position.z};
	return {mul(inv, head.orientation), rotate(inv, d)};
}

static void run_case(const char * name, xrt_quat head_q, xrt_vec3 head_p, float expect_yaw_deg)
{
	xrt_pose old_stage{{0, 0, 0, 1}, {0, 0, 0}};
	xrt_pose head{head_q, head_p};
	xrt_pose stage = wivrn::recentered_stage_offset(head, old_stage);
	float yaw = wivrn::yaw_of(stage.orientation) * 180.f / float(M_PI);
	auto rel = head_in_stage(stage, head);
	xrt_vec3 fwd = rotate(rel.orientation, {0, 0, -1});

	std::printf("%-28s stage pos (%.3f, %.3f, %.3f) yaw %7.2f | head in new stage pos (%.3f, %.3f, %.3f) fwd (%.3f, %.3f, %.3f)\n",
	            name, stage.position.x, stage.position.y, stage.position.z, yaw,
	            rel.position.x, rel.position.y, rel.position.z, fwd.x, fwd.y, fwd.z);

	check(stage.orientation.x == 0 && stage.orientation.z == 0, "gravity aligned");
	check(near(stage.orientation.y * stage.orientation.y + stage.orientation.w * stage.orientation.w, 1), "unit quat");
	check(stage.position.y == old_stage.position.y, "floor height kept");
	check(near(rel.position.x, 0) && near(rel.position.z, 0), "head above new origin");
	check(near(rel.position.y, head_p.y), "head height kept");
	check(near(std::remainder(yaw - expect_yaw_deg, 360.f), 0, 1e-2f), "yaw");
	if (std::fabs(fwd.x) + std::fabs(fwd.z) > 1e-3f)
		check(near(fwd.x, 0, 1e-3f) && fwd.z < 0, "head faces -Z of new stage");
}

int main()
{
	auto Y = [](float d) { return quat_axis_angle(0, 1, 0, d); };
	auto X = [](float d) { return quat_axis_angle(1, 0, 0, d); };
	auto Z = [](float d) { return quat_axis_angle(0, 0, 1, d); };

	run_case("identity", {0, 0, 0, 1}, {0, 1.7f, 0}, 0);
	run_case("yaw 90, offset", Y(90), {1.2f, 1.6f, -0.5f}, 90);
	run_case("yaw -135", Y(-135), {-0.3f, 1.1f, 2.f}, -135);
	run_case("yaw 180", Y(180), {0.5f, 1.5f, 0.5f}, 180);
	run_case("yaw 30 pitch -40 roll 20", mul(mul(Y(30), X(-40)), Z(20)), {0.2f, 1.2f, 0.1f}, 30);
	run_case("yaw 60 pitch 80", mul(Y(60), X(80)), {0, 1.4f, 0}, 60);
	run_case("yaw 60 pitch 90 (up)", mul(Y(60), X(90)), {0, 1.4f, 0}, 60);
	run_case("yaw 60 pitch -90 (down)", mul(Y(60), X(-90)), {0, 1.4f, 0}, 60);

	// Repeated recenter from a non-identity stage is absolute, not cumulative.
	{
		xrt_pose old_stage{Y(45), {3, 0.25f, -2}};
		xrt_pose head{Y(10), {1, 1.7f, 1}};
		auto s = wivrn::recentered_stage_offset(head, old_stage);
		check(near(wivrn::yaw_of(s.orientation) * 180.f / float(M_PI), 10, 1e-2f), "absolute yaw");
		check(s.position.y == 0.25f && s.position.x == 1 && s.position.z == 1, "absolute position, old floor y");
	}

	std::printf(failures ? "%d FAILED\n" : "ALL PASS\n", failures);
	return failures != 0;
}
