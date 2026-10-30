// D3D11 OpenVR scene app for the vrclient bridge (vrclient/): renders each eye on the GPU every frame and submits it
// through Valve's openvr_api.dll with the interface versions Half-Life: Alyx uses (IVRSystem_026, IVRCompositor_029,
// IVRInput_011). Also loads an IVRInput action manifest and reads its actions every frame.
//   ovr_d3d11_render.exe [seconds] [plain|msaa] [WxH]
// Left eye: red, green square top-left. Right eye: blue, yellow square top-right. Both: a white bar that moves down
// one row per frame. msaa: 4x eye render targets, resolved by the bridge. WxH: eye size instead of the recommended one.
#include <d3d11.h>
#include <openvr.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#define LOG(...) (printf("ovr_render: " __VA_ARGS__), printf("\n"), fflush(stdout))

static const char* kManifest = R"({
  "default_bindings": [ { "controller_type": "oculus_touch", "binding_url": "ovr_render_bindings_touch.json" } ],
  "actions": [
    { "name": "/actions/main/in/trigger", "type": "boolean" },
    { "name": "/actions/main/in/hand_left", "type": "pose" },
    { "name": "/actions/main/in/skeleton_left", "type": "skeleton", "skeleton": "/skeleton/hand/left" },
    { "name": "/actions/main/out/haptic", "type": "vibration" }
  ],
  "action_sets": [ { "name": "/actions/main", "usage": "leftright" } ]
})";

static const char* kBindings = R"({
  "controller_type": "oculus_touch",
  "bindings": {
    "/actions/main": {
      "sources": [ { "path": "/user/hand/right/input/trigger", "mode": "button", "inputs": { "click": { "output": "/actions/main/in/trigger" } } } ],
      "poses": [ { "path": "/user/hand/left/pose/raw", "output": "/actions/main/in/hand_left" } ],
      "skeleton": [ { "path": "/user/hand/left/input/skeleton/left", "output": "/actions/main/in/skeleton_left" } ],
      "haptics": [ { "path": "/user/hand/right/output/haptic", "output": "/actions/main/out/haptic" } ]
    }
  }
})";

static double now_ms()
{
	static LARGE_INTEGER freq = {}, start = {};
	LARGE_INTEGER t;
	if (!freq.QuadPart) {
		QueryPerformanceFrequency(&freq);
		QueryPerformanceCounter(&start);
	}
	QueryPerformanceCounter(&t);
	return double(t.QuadPart - start.QuadPart) * 1000.0 / double(freq.QuadPart);
}

static std::string exe_dir()
{
	char path[MAX_PATH];
	DWORD n = GetModuleFileNameA(nullptr, path, MAX_PATH);
	std::string s(path, n);
	return s.substr(0, s.find_last_of("\\/"));
}

static void write_file(const std::string& path, const char* text)
{
	if (FILE* f = fopen(path.c_str(), "wb")) {
		fputs(text, f);
		fclose(f);
	}
}

static ID3D11Texture2D* make_texture(ID3D11Device* dev, uint32_t w, uint32_t h, UINT samples, const uint32_t* fill)
{
	D3D11_TEXTURE2D_DESC d = {};
	d.Width = w;
	d.Height = h;
	d.MipLevels = 1;
	d.ArraySize = 1;
	d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	d.SampleDesc.Count = samples;
	d.Usage = D3D11_USAGE_DEFAULT;
	d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
	std::vector<uint32_t> px;
	D3D11_SUBRESOURCE_DATA init = {};
	if (fill) {
		px.assign(size_t(w) * h, *fill);
		init = { px.data(), w * 4, 0 };
	}
	ID3D11Texture2D* tex = nullptr;
	HRESULT hr = dev->CreateTexture2D(&d, fill ? &init : nullptr, &tex);
	if (FAILED(hr))
		LOG("CreateTexture2D %ux%u x%u failed 0x%08lx", w, h, samples, (unsigned long)hr);
	return tex;
}

int main(int argc, char** argv)
{
	double secs = argc > 1 ? atof(argv[1]) : 30;
	bool msaa = argc > 2 && !strcmp(argv[2], "msaa");
	UINT samples = msaa ? 4 : 1;

	vr::EVRInitError err = vr::VRInitError_None;
	double t0 = now_ms();
	vr::IVRSystem* sys = vr::VR_Init(&err, vr::VRApplication_Scene);
	if (!sys) {
		LOG("VR_Init failed: %d %s", err, vr::VR_GetVRInitErrorAsEnglishDescription(err));
		return 1;
	}
	uint32_t w = 0, h = 0;
	sys->GetRecommendedRenderTargetSize(&w, &h);
	if (argc > 3)
		sscanf(argv[3], "%ux%u", &w, &h);
	char model[256] = {};
	sys->GetStringTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_ModelNumber_String, model, sizeof(model));
	LOG("VR_Init %.0f ms: %s, %s, render target %ux%u, HMD '%s', %.0f Hz", now_ms() - t0, vr::IVRSystem_Version,
	    vr::IVRCompositor_Version, w, h, model,
	    sys->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_DisplayFrequency_Float));

	ID3D11Device* dev = nullptr;
	ID3D11DeviceContext* ctx = nullptr;
	HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &dev,
	    nullptr, &ctx);
	if (FAILED(hr)) {
		LOG("D3D11CreateDevice failed 0x%08lx", (unsigned long)hr);
		return 1;
	}

	const uint32_t white = 0xFFFFFFFFu, marks[2] = { 0xFF00FF00u, 0xFF00FFFFu }; // RGBA bytes: green / yellow
	const float clear[2][4] = { { 0.85f, 0.1f, 0.1f, 1 }, { 0.1f, 0.2f, 0.9f, 1 } };
	const uint32_t bar_h = std::max(4u, h / 40), sq = h / 5;
	ID3D11Texture2D* eyes[2];
	ID3D11RenderTargetView* rtv[2];
	ID3D11Texture2D* bar = make_texture(dev, w, bar_h, 1, &white);
	ID3D11Texture2D* square[2] = { make_texture(dev, sq, sq, 1, &marks[0]), make_texture(dev, sq, sq, 1, &marks[1]) };
	for (int e = 0; e < 2; e++) {
		eyes[e] = make_texture(dev, w, h, samples, nullptr);
		if (!eyes[e] || FAILED(dev->CreateRenderTargetView(eyes[e], nullptr, &rtv[e])))
			return 1;
	}
	// MSAA targets can't take CopySubresourceRegion from single-sample textures: clear only.
	if (msaa)
		LOG("MSAA x%u eye targets: clear colour only", samples);

	vr::IVRCompositor* comp = vr::VRCompositor();
	vr::IVRInput* input = vr::VRInput();
	std::string dir = exe_dir();
	write_file(dir + "\\ovr_render_bindings_touch.json", kBindings);
	write_file(dir + "\\ovr_render_actions.json", kManifest);
	vr::EVRInputError ie = input->SetActionManifestPath((dir + "\\ovr_render_actions.json").c_str());
	vr::VRActionSetHandle_t set = 0;
	vr::VRActionHandle_t trig = 0, pose = 0, skel = 0, hap = 0;
	input->GetActionSetHandle("/actions/main", &set);
	input->GetActionHandle("/actions/main/in/trigger", &trig);
	input->GetActionHandle("/actions/main/in/hand_left", &pose);
	input->GetActionHandle("/actions/main/in/skeleton_left", &skel);
	input->GetActionHandle("/actions/main/out/haptic", &hap);
	LOG("SetActionManifestPath -> %d, handles set %llx trigger %llx pose %llx skeleton %llx haptic %llx", ie,
	    (unsigned long long)set, (unsigned long long)trig, (unsigned long long)pose, (unsigned long long)skel,
	    (unsigned long long)hap);

	int frames = 0, submit_errors = 0, wait_errors = 0, input_errors = 0, events = 0;
	std::vector<double> submit_ms, frame_ms;
	double start = now_ms(), last = start;
	bool quit = false;
	while (now_ms() - start < secs * 1000 && !quit) {
		vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
		vr::EVRCompositorError ce = comp->WaitGetPoses(poses, vr::k_unMaxTrackedDeviceCount, nullptr, 0);
		if (ce != vr::VRCompositorError_None && wait_errors++ < 5)
			LOG("frame %d WaitGetPoses -> %d", frames, ce);

		vr::VREvent_t ev;
		while (sys->PollNextEvent(&ev, sizeof(ev))) {
			events++;
			if (ev.eventType == vr::VREvent_Quit) {
				sys->AcknowledgeQuit_Exiting();
				quit = true;
			}
		}
		vr::VRActiveActionSet_t active = {};
		active.ulActionSet = set;
		vr::InputDigitalActionData_t dd = {};
		vr::InputPoseActionData_t pd = {};
		vr::InputSkeletalActionData_t sd = {};
		vr::EVRInputError r[4] = {
			input->UpdateActionState(&active, sizeof(active), 1),
			input->GetDigitalActionData(trig, &dd, sizeof(dd), vr::k_ulInvalidInputValueHandle),
			input->GetPoseActionDataForNextFrame(pose, vr::TrackingUniverseStanding, &pd, sizeof(pd), vr::k_ulInvalidInputValueHandle),
			input->GetSkeletalActionData(skel, &sd, sizeof(sd)),
		};
		for (vr::EVRInputError e : r)
			if (e != vr::VRInputError_None && e != vr::VRInputError_NoData && input_errors++ < 5)
				LOG("frame %d input error %d", frames, e);
		if (frames == 30)
			input->TriggerHapticVibrationAction(hap, 0, 0.1f, 160, 0.5f, vr::k_ulInvalidInputValueHandle);

		uint32_t y = (uint32_t(frames) * 4) % (h - bar_h);
		for (int e = 0; e < 2; e++) {
			ctx->ClearRenderTargetView(rtv[e], clear[e]);
			if (!msaa) {
				ctx->CopySubresourceRegion(eyes[e], 0, e ? w - w / 5 - sq : w / 5, h / 10, 0, square[e], 0, nullptr);
				ctx->CopySubresourceRegion(eyes[e], 0, 0, y, 0, bar, 0, nullptr);
			}
		}
		double s0 = now_ms();
		for (int e = 0; e < 2; e++) {
			vr::Texture_t t = { eyes[e], vr::TextureType_DirectX, vr::ColorSpace_Gamma };
			ce = comp->Submit(e ? vr::Eye_Right : vr::Eye_Left, &t);
			if (ce != vr::VRCompositorError_None && submit_errors++ < 5)
				LOG("frame %d Submit(eye %d) -> %d", frames, e, ce);
		}
		double s1 = now_ms();
		comp->PostPresentHandoff();
		submit_ms.push_back(s1 - s0);
		frame_ms.push_back(s1 - last);
		last = s1;
		if (frames == 0 || frames == 60)
			LOG("frame %d: HMD pose valid %d, trigger active %d, pose active %d, skeleton active %d", frames,
			    poses[0].bPoseIsValid, dd.bActive, pd.bActive, sd.bActive);
		frames++;
	}
	double elapsed = (now_ms() - start) / 1000;
	auto pct = [](std::vector<double> v, double p) {
		if (v.empty())
			return 0.0;
		std::sort(v.begin(), v.end());
		return v[std::min(v.size() - 1, size_t(p * v.size()))];
	};
	LOG("done: %d frames in %.1f s (%.1f fps), %d submit errors, %d wait errors, %d input errors, %d events", frames,
	    elapsed, frames / elapsed, submit_errors, wait_errors, input_errors, events);
	LOG("both-eye Submit ms: median %.2f p99 %.2f max %.2f; frame interval ms: median %.2f p99 %.2f", pct(submit_ms, 0.5),
	    pct(submit_ms, 0.99), pct(submit_ms, 1), pct(frame_ms, 0.5), pct(frame_ms, 0.99));
	vr::VR_Shutdown();
	for (int e = 0; e < 2; e++) {
		rtv[e]->Release();
		eyes[e]->Release();
		square[e]->Release();
	}
	bar->Release();
	ctx->Release();
	dev->Release();
	LOG("VR_Shutdown ok");
	return submit_errors ? 2 : 0;
}
