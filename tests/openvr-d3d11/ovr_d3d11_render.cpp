// D3D11 OpenVR scene app for the vrclient bridge (vrclient/): renders each eye on the GPU every frame and submits it
// through Valve's openvr_api.dll with the interface versions Half-Life: Alyx uses (IVRSystem_026, IVRCompositor_029,
// IVRInput_011). Also loads an IVRInput action manifest and reads its actions every frame.
//   ovr_d3d11_render.exe [seconds] [plain|msaa|stress[N]] [WxH]
// Left eye: red, green square top-left. Right eye: blue, yellow square top-right. Both: a white bar that moves down
// one row per frame. msaa: 4x eye render targets, resolved by the bridge. stress: before each eye, a full-screen pass
// with an N-iteration (default 256) ALU loop per pixel into a scratch target, a few ms of GPU work that a CPU wait for
// the eye's copy would show. WxH: eye size instead of the recommended one.
#include <d3d11.h>
#include <d3dcompiler.h>
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

static const char* kStressShader = R"(
float4 vs(uint id : SV_VertexID) : SV_Position
{
	float2 t = float2((id << 1) & 2, id & 2);
	return float4(t * float2(2, -2) + float2(-1, 1), 0, 1);
}
float4 ps(float4 p : SV_Position) : SV_Target
{
	float a = p.x * 0.001, b = p.y * 0.001;
	[loop] for (uint i = 0; i < ITERS; i++) {
		a = sin(a * 1.01 + b);
		b = cos(b * 0.99 + a);
	}
	return float4(a, b, 0, 1);
}
)";

struct Stress {
	ID3D11VertexShader* vs = nullptr;
	ID3D11PixelShader* ps = nullptr;
	ID3D11RenderTargetView* rtv = nullptr;
	D3D11_VIEWPORT vp = {};
};

static bool make_stress(ID3D11Device* dev, uint32_t w, uint32_t h, unsigned iters, Stress& st)
{
	HMODULE dll = LoadLibraryA("d3dcompiler_47.dll");
	auto compile = dll ? (pD3DCompile)GetProcAddress(dll, "D3DCompile") : nullptr;
	if (!compile) {
		LOG("stress: no D3DCompile");
		return false;
	}
	char n[16];
	snprintf(n, sizeof(n), "%u", iters);
	const D3D_SHADER_MACRO defs[] = { { "ITERS", n }, { nullptr, nullptr } };
	ID3DBlob *vsb = nullptr, *psb = nullptr, *errb = nullptr;
	HRESULT hr = compile(kStressShader, strlen(kStressShader), "stress", defs, nullptr, "vs", "vs_5_0", 0, 0, &vsb, &errb);
	if (SUCCEEDED(hr))
		hr = compile(kStressShader, strlen(kStressShader), "stress", defs, nullptr, "ps", "ps_5_0", 0, 0, &psb, &errb);
	if (FAILED(hr)) {
		LOG("stress: D3DCompile 0x%08lx %s", (unsigned long)hr, errb ? (const char*)errb->GetBufferPointer() : "");
		return false;
	}
	ID3D11Texture2D* tex = make_texture(dev, w, h, 1, nullptr);
	bool ok = tex && SUCCEEDED(dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &st.vs))
	    && SUCCEEDED(dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &st.ps))
	    && SUCCEEDED(dev->CreateRenderTargetView(tex, nullptr, &st.rtv));
	if (tex)
		tex->Release();
	vsb->Release();
	psb->Release();
	st.vp = { 0, 0, float(w), float(h), 0, 1 };
	LOG("stress: %u iterations per pixel, %ux%u, per eye%s", iters, w, h, ok ? "" : ": setup failed");
	return ok;
}

static void run_stress(ID3D11DeviceContext* ctx, const Stress& st)
{
	ctx->OMSetRenderTargets(1, &st.rtv, nullptr);
	ctx->RSSetViewports(1, &st.vp);
	ctx->IASetInputLayout(nullptr);
	ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
	ctx->VSSetShader(st.vs, nullptr, 0);
	ctx->PSSetShader(st.ps, nullptr, 0);
	ctx->Draw(3, 0);
	ctx->OMSetRenderTargets(0, nullptr, nullptr);
}

int main(int argc, char** argv)
{
	double secs = argc > 1 ? atof(argv[1]) : 30;
	bool msaa = argc > 2 && !strcmp(argv[2], "msaa");
	bool stress = argc > 2 && !strncmp(argv[2], "stress", 6);
	unsigned stress_iters = stress && argv[2][6] ? (unsigned)atoi(argv[2] + 6) : 256;
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
	Stress st;
	if (stress && !make_stress(dev, w, h, stress_iters, st))
		return 1;

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

	// The other interfaces Half-Life: Alyx asks for, and a few harmless calls on them.
	static const char* const alyx_ifaces[] = { "IVROverlay_028", "IVRRenderModels_006", "IVRApplications_007",
		"IVRChaperone_004", "IVRMailbox_001", "IVRHeadsetView_001", "IVROverlayView_003", "IVRSettings_003" };
	int missing = 0;
	for (const char* name : alyx_ifaces) {
		vr::EVRInitError ge = vr::VRInitError_None;
		void* p = vr::VR_GetGenericInterface(name, &ge);
		if (!p)
			missing++;
		LOG("%s -> %p (%d)", name, p, ge);
	}
	vr::IVRRenderModels* models = vr::VRRenderModels();
	vr::IVRChaperone* chap = vr::VRChaperone();
	vr::IVRHeadsetView* hview = vr::VRHeadsetView();
	float pw = 0, ph = 0;
	if (chap)
		chap->GetPlayAreaSize(&pw, &ph);
	LOG("render models %u, chaperone calibration %d play area %.2fx%.2f, headset view mode %u", models ? models->GetRenderModelCount() : 0,
	    chap ? (int)chap->GetCalibrationState() : -1, pw, ph, hview ? (unsigned)hview->GetHeadsetViewMode() : 0);
	vr::IVROverlay* ovl = vr::VROverlay();
	vr::VROverlayHandle_t overlay = vr::k_ulOverlayHandleInvalid;
	const uint32_t ovl_px = 0xFF20C0FFu;
	ID3D11Texture2D* ovl_tex = make_texture(dev, 256, 128, 1, &ovl_px);
	vr::EVROverlayError oe = ovl ? ovl->CreateOverlay("macvr.vrclient.test", "vrclient test", &overlay) : vr::VROverlayError_InvalidHandle;
	if (oe == vr::VROverlayError_None) {
		ovl->SetOverlayWidthInMeters(overlay, 0.5f);
		vr::HmdMatrix34_t m = { { { 1, 0, 0, 0 }, { 0, 1, 0, 1.2f }, { 0, 0, 1, -1.5f } } };
		ovl->SetOverlayTransformAbsolute(overlay, vr::TrackingUniverseStanding, &m);
		vr::Texture_t t = { ovl_tex, vr::TextureType_DirectX, vr::ColorSpace_Gamma };
		oe = ovl->SetOverlayTexture(overlay, &t);
		vr::EVROverlayError se = ovl->ShowOverlay(overlay);
		LOG("overlay %llx: SetOverlayTexture(D3D11) -> %d, ShowOverlay -> %d", (unsigned long long)overlay, oe, se);
	} else {
		LOG("CreateOverlay -> %d", oe);
	}

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
			if (stress)
				run_stress(ctx, st);
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
		if (overlay != vr::k_ulOverlayHandleInvalid && frames % 60 == 59) {
			vr::Texture_t t = { ovl_tex, vr::TextureType_DirectX, vr::ColorSpace_Gamma };
			if ((oe = ovl->SetOverlayTexture(overlay, &t)) != vr::VROverlayError_None)
				LOG("frame %d SetOverlayTexture -> %d", frames, oe);
		}
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
	LOG("done: %d frames in %.1f s (%.1f fps), %d submit errors, %d wait errors, %d input errors, %d events, %d missing "
	    "interfaces", frames, elapsed, frames / elapsed, submit_errors, wait_errors, input_errors, events, missing);
	if (overlay != vr::k_ulOverlayHandleInvalid)
		ovl->DestroyOverlay(overlay);
	ovl_tex->Release();
	LOG("both-eye Submit ms: median %.2f p99 %.2f max %.2f; frame interval ms: median %.2f p99 %.2f", pct(submit_ms, 0.5),
	    pct(submit_ms, 0.99), pct(submit_ms, 1), pct(frame_ms, 0.5), pct(frame_ms, 0.99));
	vr::VR_Shutdown();
	for (int e = 0; e < 2; e++) {
		rtv[e]->Release();
		eyes[e]->Release();
		square[e]->Release();
	}
	bar->Release();
	if (stress) {
		st.vs->Release();
		st.ps->Release();
		st.rtv->Release();
	}
	ctx->Release();
	dev->Release();
	LOG("VR_Shutdown ok");
	return submit_errors ? 2 : 0;
}
