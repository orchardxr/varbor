// Minimal OpenVR scene app for M3 (docs/m3-opencomposite.md): VR_Init, per-eye D3D11 test pattern textures through
// IVRCompositor::Submit, legacy controller state and IVRInput actions. Links Valve's openvr_api.dll.
//   ovr_d3d11_test.exe [frames] [action manifest]
// OVR_TEST_IGNORE_QUIT=1 keeps rendering after VREvent_Quit (an app that ignores it).
// OVR_TEST_INTERSTITIAL=1 plays Half-Life: Alyx's interstitials sequence (as the game does it): RegisterMailbox
// 'hlvr/mailbox', IVRControlPanel_006::RegisterExternalWebRoot(OVR_TEST_WEBROOT), wait for the page's "ready", then the
// 'hlvr/interstitials' messages from the game's log: set_paths, begin_loading at frame 5, show_message at frame
// OVR_TEST_PROMPT_FRAME (default 30), end_loading 40 frames before the end.
// With a manifest (e.g. a copy of Half-Life: Alyx's hlvr/cfg/actions.json), the test activates all of its action
// sets and reads the Alyx-style default actions (poses, skeletons, turn, trigger) instead of its own.
// Left eye: orange, green square top-left. Right eye: blue, magenta square top-right. Both: white bar across the middle.
#include <d3d11.h>
#include <openvr.h>
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#define LOG(...) (printf("ovr_test: " __VA_ARGS__), printf("\n"), fflush(stdout))

// Valve's undocumented vrclient interface, as in OpenComposite's custom_interfaces/IVRMailbox_001.h
class IVRMailbox {
public:
	virtual int RegisterMailbox(const char* name, uint64_t* handle) = 0;
	virtual int UnregisterMailbox(uint64_t handle) = 0;
	virtual int SendMessage(uint64_t handle, const char* type, const char* message) = 0;
	virtual int ReadMessage(uint64_t mbox, char* outBuf, uint32_t outBufLen, uint32_t* msgLen) = 0;
};

// IVRControlPanel_006::RegisterExternalWebRoot is vtable slot 26 (Alyx's vr.dll calls vtable + 0xd0 with the path).
static int RegisterExternalWebRoot(void* panel, const char* path)
{
	typedef int (*fn_t)(void*, const char*);
	return ((fn_t*)*(void**)panel)[26](panel, path);
}

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

static const char* kManifest = R"({
  "default_bindings": [ { "controller_type": "oculus_touch", "binding_url": "ovr_test_bindings_touch.json" } ],
  "actions": [
    { "name": "/actions/main/in/trigger", "type": "boolean" },
    { "name": "/actions/main/in/squeeze", "type": "vector1" },
    { "name": "/actions/main/in/hand_left", "type": "pose" },
    { "name": "/actions/main/in/hand_right", "type": "pose" },
    { "name": "/actions/main/out/haptic", "type": "vibration" }
  ],
  "action_sets": [ { "name": "/actions/main", "usage": "leftright" } ]
})";

static const char* kBindings = R"({
  "controller_type": "oculus_touch",
  "bindings": {
    "/actions/main": {
      "sources": [
        { "path": "/user/hand/right/input/trigger", "mode": "button", "inputs": { "click": { "output": "/actions/main/in/trigger" } } },
        { "path": "/user/hand/left/input/grip", "mode": "trigger", "inputs": { "pull": { "output": "/actions/main/in/squeeze" } } }
      ],
      "poses": [
        { "path": "/user/hand/left/pose/raw", "output": "/actions/main/in/hand_left" },
        { "path": "/user/hand/right/pose/raw", "output": "/actions/main/in/hand_right" }
      ],
      "haptics": [ { "path": "/user/hand/right/output/haptic", "output": "/actions/main/out/haptic" } ]
    }
  }
})";

static std::string exe_dir()
{
	char path[MAX_PATH];
	DWORD n = GetModuleFileNameA(nullptr, path, MAX_PATH);
	std::string s(path, n);
	return s.substr(0, s.find_last_of("\\/"));
}

static bool write_file(const std::string& path, const char* text)
{
	FILE* f = fopen(path.c_str(), "wb");
	if (!f)
		return false;
	fputs(text, f);
	fclose(f);
	return true;
}

static ID3D11Texture2D* make_eye(ID3D11Device* dev, uint32_t w, uint32_t h, bool right)
{
	std::vector<uint32_t> px(size_t(w) * h);
	const uint32_t bg = right ? 0xFFFF4000u : 0xFF0080FFu; // ABGR in memory order RGBA: blue / orange
	const uint32_t mark = right ? 0xFFFF00FFu : 0xFF00FF00u; // magenta / green
	for (uint32_t y = 0; y < h; y++) {
		for (uint32_t x = 0; x < w; x++) {
			uint32_t c = bg;
			if (y > h * 9 / 20 && y < h * 11 / 20)
				c = 0xFFFFFFFFu;
			bool in_sq_y = y > h / 10 && y < h * 3 / 10;
			bool in_sq_x = right ? (x > w * 6 / 10 && x < w * 8 / 10) : (x > w * 2 / 10 && x < w * 4 / 10);
			if (in_sq_x && in_sq_y)
				c = mark;
			px[size_t(y) * w + x] = c;
		}
	}
	D3D11_TEXTURE2D_DESC d = {};
	d.Width = w;
	d.Height = h;
	d.MipLevels = 1;
	d.ArraySize = 1;
	d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	d.SampleDesc.Count = 1;
	d.Usage = D3D11_USAGE_DEFAULT;
	d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
	D3D11_SUBRESOURCE_DATA init = { px.data(), w * 4, 0 };
	ID3D11Texture2D* tex = nullptr;
	HRESULT hr = dev->CreateTexture2D(&d, &init, &tex);
	if (FAILED(hr))
		LOG("CreateTexture2D failed 0x%08lx", (unsigned long)hr);
	return tex;
}

static const char* class_name(vr::ETrackedDeviceClass c)
{
	switch (c) {
	case vr::TrackedDeviceClass_HMD: return "HMD";
	case vr::TrackedDeviceClass_Controller: return "Controller";
	case vr::TrackedDeviceClass_GenericTracker: return "GenericTracker";
	case vr::TrackedDeviceClass_TrackingReference: return "TrackingReference";
	case vr::TrackedDeviceClass_DisplayRedirect: return "DisplayRedirect";
	default: return "?";
	}
}

int main(int argc, char** argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 300;
	double t0 = now_ms();
	bool installed = vr::VR_IsRuntimeInstalled();
	double t1 = now_ms();
	bool present = vr::VR_IsHmdPresent();
	double t2 = now_ms();
	present = vr::VR_IsHmdPresent();
	double t3 = now_ms();
	LOG("VR_IsRuntimeInstalled %d (%.1f ms), VR_IsHmdPresent %d (%.1f ms, again %.1f ms)", installed, t1 - t0, present,
	    t2 - t1, t3 - t2);
	char rt[1024] = {};
	uint32_t rtlen = 0;
	if (vr::VR_GetRuntimePath(rt, sizeof(rt), &rtlen))
		LOG("runtime path %s", rt);

	vr::EVRInitError err = vr::VRInitError_None;
	t0 = now_ms();
	vr::IVRSystem* sys = vr::VR_Init(&err, vr::VRApplication_Scene);
	t1 = now_ms();
	if (!sys) {
		LOG("VR_Init failed (%.1f ms): %d %s %s", t1 - t0, err, vr::VR_GetVRInitErrorAsSymbol(err),
		    vr::VR_GetVRInitErrorAsEnglishDescription(err));
		t0 = now_ms();
		sys = vr::VR_Init(&err, vr::VRApplication_Scene);
		LOG("VR_Init retry (%.1f ms): %d %s", now_ms() - t0, err, vr::VR_GetVRInitErrorAsSymbol(err));
		if (sys)
			vr::VR_Shutdown();
		return 1;
	}
	LOG("VR_Init took %.1f ms", t1 - t0);
	uint32_t w = 0, h = 0;
	sys->GetRecommendedRenderTargetSize(&w, &h);
	char model[256] = {};
	sys->GetStringTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_ModelNumber_String, model, sizeof(model));
	LOG("VR_Init ok: render target %ux%u, HMD model '%s', refresh %.1f", w, h, model,
	    sys->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd, vr::Prop_DisplayFrequency_Float));

	int32_t adapter = -1;
	sys->GetDXGIOutputInfo(&adapter);
	ID3D11Device* dev = nullptr;
	ID3D11DeviceContext* ctx = nullptr;
	HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &dev,
	    nullptr, &ctx);
	if (FAILED(hr)) {
		LOG("D3D11CreateDevice failed 0x%08lx", (unsigned long)hr);
		return 1;
	}
	LOG("D3D11 device ok (DXGI output adapter index %d)", adapter);

	ID3D11Texture2D* eyes[2] = { make_eye(dev, w, h, false), make_eye(dev, w, h, true) };
	if (!eyes[0] || !eyes[1])
		return 1;

	vr::IVRCompositor* comp = vr::VRCompositor();
	vr::IVRInput* input = vr::VRInput();
	std::string dir = exe_dir();
	write_file(dir + "\\ovr_test_bindings_touch.json", kBindings);
	write_file(dir + "\\ovr_test_actions.json", kManifest);
	const char* ext_manifest = argc > 2 ? argv[2] : nullptr;
	vr::EVRInputError ie = input->SetActionManifestPath(ext_manifest ? ext_manifest : (dir + "\\ovr_test_actions.json").c_str());
	LOG("SetActionManifestPath -> %d", ie);
	vr::VRActionSetHandle_t set = 0;
	vr::VRActionHandle_t trig = 0, squeeze = 0, pl = 0, pr = 0, hap = 0;
	input->GetActionSetHandle("/actions/main", &set);
	input->GetActionHandle("/actions/main/in/trigger", &trig);
	input->GetActionHandle("/actions/main/in/squeeze", &squeeze);
	input->GetActionHandle("/actions/main/in/hand_left", &pl);
	input->GetActionHandle("/actions/main/in/hand_right", &pr);
	input->GetActionHandle("/actions/main/out/haptic", &hap);
	LOG("handles set %llx trigger %llx squeeze %llx poses %llx %llx haptic %llx", (unsigned long long)set,
	    (unsigned long long)trig, (unsigned long long)squeeze, (unsigned long long)pl, (unsigned long long)pr,
	    (unsigned long long)hap);

	const char* ext_sets[] = { "/actions/default", "/actions/move", "/actions/interact", "/actions/weapon", "/actions/scroll", "/actions/dev" };
	vr::VRActiveActionSet_t ext_active[6] = {};
	vr::VRActionHandle_t ext_pose[2] = {}, ext_skel[2] = {}, ext_turn = 0, ext_trigger = 0, ext_fire = 0;
	if (ext_manifest) {
		for (int i = 0; i < 6; i++)
			input->GetActionSetHandle(ext_sets[i], &ext_active[i].ulActionSet);
		input->GetActionHandle("/actions/default/in/HandPoseLeft", &ext_pose[0]);
		input->GetActionHandle("/actions/default/in/HandPoseRight", &ext_pose[1]);
		input->GetActionHandle("/actions/default/in/HandSkeletonLeft", &ext_skel[0]);
		input->GetActionHandle("/actions/default/in/HandSkeletonRight", &ext_skel[1]);
		input->GetActionHandle("/actions/move/in/ContinuousTurn", &ext_turn);
		input->GetActionHandle("/actions/default/in/TriggerPull", &ext_trigger);
		input->GetActionHandle("/actions/weapon/in/Fire", &ext_fire);
	}

	int submit_errors = 0, events = 0, pose_valid = 0, wait_errors = 0;
	IVRMailbox* mbox = nullptr;
	uint64_t mbox_handle = 0;
	int prompt_frame = getenv("OVR_TEST_PROMPT_FRAME") ? atoi(getenv("OVR_TEST_PROMPT_FRAME")) : 30;
	if (getenv("OVR_TEST_INTERSTITIAL")) {
		vr::EVRInitError me = vr::VRInitError_None;
		mbox = (IVRMailbox*)vr::VR_GetGenericInterface("IVRMailbox_001", &me);
		LOG("IVRMailbox_001 %p (%d)", (void*)mbox, me);
		void* panel = vr::VR_GetGenericInterface("IVRControlPanel_006", &me);
		LOG("IVRControlPanel_006 %p (%d)", panel, me);
		const char* webroot = getenv("OVR_TEST_WEBROOT") ? getenv("OVR_TEST_WEBROOT") : "C:\\game\\hlvr\\webui";
		if (mbox) {
			mbox->RegisterMailbox("hlvr/mailbox", &mbox_handle);
			if (panel) {
				double t0 = now_ms();
				int r = RegisterExternalWebRoot(panel, webroot);
				LOG("RegisterExternalWebRoot(%s) -> %d in %.0f ms", webroot, r, now_ms() - t0);
			}
			double t0 = now_ms();
			char buf[4096];
			uint32_t len = 0;
			bool ready = false;
			while (!ready && now_ms() - t0 < 20000) {
				if (mbox->ReadMessage(mbox_handle, buf, sizeof(buf), &len) == 0) {
					LOG("hlvr/mailbox: %s", buf);
					ready = strstr(buf, "\"ready\"") != nullptr;
				} else {
					Sleep(10);
				}
			}
			LOG("ready %d after %.0f ms", ready, now_ms() - t0);
			std::string root = webroot, models = root.substr(0, root.rfind('\\')) + "\\models\\ui\\";
			auto esc = [](std::string v) { std::string o; for (char c : v) { if (c == '\\') o += '\\'; o += c; } return o; };
			std::string sp = "{\n\t\"type\": \"set_paths\",\n\t\"webroot\": \"" + esc(root) + "\",\n\t\"models\": \"" + esc(models) + "\"\n}";
			mbox->SendMessage(mbox_handle, "hlvr/interstitials", sp.c_str());
		}
	}
	auto mailbox = [&](int f) {
		const char* msg = nullptr;
		if (f == 5)
			msg = "{\n\t\"type\": \"begin_loading\",\n\t\"mapName\": \"startup\",\n\t\"chapter\": \"\",\n\t\"tipText\": "
			      "\"WEAPONS: You can quickly switch between your hand and previous weapon by tapping the weapon selection button.\",\n\t"
			      "\"description\": \"THE BLACK MESA INCIDENT: A failed experiment with an alien substance created the disastrous "
			      "event known as THE RESONANCE CASCADE.\",\n\t\"loadingText\": \"LOADING\",\n\t\"facingAngle\": 0.000000\n}";
		else if (f == prompt_frame)
			msg = "{\n\t\"type\": \"show_message\",\n\t\"text\": \"Press Trigger To Start\"\n}";
		else if (f == frames - 40)
			msg = "{\n\t\"type\": \"end_loading\"\n}";
		if (msg) {
			int r = mbox->SendMessage(mbox_handle, "hlvr/interstitials", msg);
			LOG("frame %d: mailbox %s -> %d", f, strstr(msg, "begin") ? "begin_loading" : strstr(msg, "show") ? "show_message" : "end_loading", r);
		}
	};

	bool quit = false, ignore_quit = getenv("OVR_TEST_IGNORE_QUIT") != nullptr;
	int f = 0;
	for (; f < frames && !quit; f++) {
		vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
		vr::EVRCompositorError ce = comp->WaitGetPoses(poses, vr::k_unMaxTrackedDeviceCount, nullptr, 0);
		if (ce != vr::VRCompositorError_None && wait_errors++ < 5)
			LOG("frame %d (%.0f ms) WaitGetPoses -> %d", f, now_ms(), ce);

		if (mbox)
			mailbox(f);

		vr::VREvent_t ev;
		while (sys->PollNextEvent(&ev, sizeof(ev))) {
			events++;
			if (ev.eventType == vr::VREvent_Quit) {
				LOG("frame %d (%.0f ms): VREvent_Quit%s", f, now_ms(), ignore_quit ? ", ignored" : ", acknowledging and exiting");
				if (!ignore_quit) {
					sys->AcknowledgeQuit_Exiting();
					quit = true;
				}
			}
		}

		vr::VRActiveActionSet_t active = {};
		active.ulActionSet = set;
		ie = ext_manifest ? input->UpdateActionState(ext_active, sizeof(ext_active[0]), 6)
		                  : input->UpdateActionState(&active, sizeof(active), 1);
		if (ext_manifest) {
			vr::InputPoseActionData_t p[2] = {};
			vr::InputSkeletalActionData_t sk = {};
			vr::VRBoneTransform_t bones[31];
			vr::InputAnalogActionData_t turn = {}, trig = {};
			vr::InputDigitalActionData_t fire = {};
			vr::EVRInputError r[7];
			for (int h = 0; h < 2; h++)
				r[h] = input->GetPoseActionDataForNextFrame(ext_pose[h], vr::TrackingUniverseStanding, &p[h], sizeof(p[h]),
				    vr::k_ulInvalidInputValueHandle);
			r[2] = input->GetSkeletalActionData(ext_skel[0], &sk, sizeof(sk));
			r[3] = input->GetSkeletalBoneData(ext_skel[1], vr::VRSkeletalTransformSpace_Parent, vr::VRSkeletalMotionRange_WithController,
			    bones, 31);
			r[4] = input->GetAnalogActionData(ext_turn, &turn, sizeof(turn), vr::k_ulInvalidInputValueHandle);
			r[5] = input->GetAnalogActionData(ext_trigger, &trig, sizeof(trig), vr::k_ulInvalidInputValueHandle);
			r[6] = input->GetDigitalActionData(ext_fire, &fire, sizeof(fire), vr::k_ulInvalidInputValueHandle);
			if (f == 0 || f == 60 || f == frames - 1)
				LOG("frame %d manifest actions: poseL %d (active %d valid %d) poseR %d (active %d valid %d) skelL %d (active %d) "
				    "bonesR %d turn %d (active %d) trigger %d (active %d) fire %d (active %d)",
				    f, r[0], p[0].bActive, p[0].pose.bPoseIsValid, r[1], p[1].bActive, p[1].pose.bPoseIsValid, r[2], sk.bActive,
				    r[3], r[4], turn.bActive, r[5], trig.bActive, r[6], fire.bActive);
		}
		vr::InputDigitalActionData_t dd = {};
		vr::EVRInputError e1 = input->GetDigitalActionData(trig, &dd, sizeof(dd), vr::k_ulInvalidInputValueHandle);
		vr::InputAnalogActionData_t ad = {};
		vr::EVRInputError e2 = input->GetAnalogActionData(squeeze, &ad, sizeof(ad), vr::k_ulInvalidInputValueHandle);
		vr::InputPoseActionData_t pd[2] = {};
		vr::EVRInputError e3 = input->GetPoseActionDataForNextFrame(pl, vr::TrackingUniverseStanding, &pd[0], sizeof(pd[0]),
		    vr::k_ulInvalidInputValueHandle);
		vr::EVRInputError e4 = input->GetPoseActionDataForNextFrame(pr, vr::TrackingUniverseStanding, &pd[1], sizeof(pd[1]),
		    vr::k_ulInvalidInputValueHandle);
		if (pd[0].bActive && pd[0].pose.bPoseIsValid)
			pose_valid++;
		if (f == 30)
			input->TriggerHapticVibrationAction(hap, 0, 0.1f, 160, 0.5f, vr::k_ulInvalidInputValueHandle);

		if (f == 0 || f == frames - 1 || f == 60) {
			LOG("frame %d HMD pose valid %d y=%.3f; UpdateActionState %d trigger(%d active %d state %d) "
			    "squeeze(%d active %d x %.2f) poseL(%d active %d valid %d) poseR(%d active %d valid %d)",
			    f, poses[0].bPoseIsValid, poses[0].mDeviceToAbsoluteTracking.m[1][3], ie, e1, dd.bActive, dd.bState,
			    e2, ad.bActive, ad.x, e3, pd[0].bActive, pd[0].pose.bPoseIsValid, e4, pd[1].bActive,
			    pd[1].pose.bPoseIsValid);
			for (vr::TrackedDeviceIndex_t i = 0; i < vr::k_unMaxTrackedDeviceCount; i++) {
				vr::ETrackedDeviceClass c = sys->GetTrackedDeviceClass(i);
				if (c == vr::TrackedDeviceClass_Invalid)
					continue;
				char name[256] = {}, ctype[128] = {};
				sys->GetStringTrackedDeviceProperty(i, vr::Prop_ModelNumber_String, name, sizeof(name));
				sys->GetStringTrackedDeviceProperty(i, vr::Prop_ControllerType_String, ctype, sizeof(ctype));
				vr::VRControllerState_t st = {};
				vr::TrackedDevicePose_t sp = {};
				bool ok = sys->GetControllerState(i, &st, sizeof(st));
				bool okp = sys->GetControllerStateWithPose(vr::TrackingUniverseStanding, i, &st, sizeof(st), &sp);
				LOG("  device %u %s '%s' type '%s' connected %d role %d: GetControllerState %d (buttons %llx axis0 %.2f,%.2f "
				    "trigger %.2f) WithPose %d valid %d",
				    i, class_name(c), name, ctype, sys->IsTrackedDeviceConnected(i),
				    sys->GetControllerRoleForTrackedDeviceIndex(i), ok, (unsigned long long)st.ulButtonPressed,
				    st.rAxis[0].x, st.rAxis[0].y, st.rAxis[1].x, okp, sp.bPoseIsValid);
			}
			LOG("  role left -> %u, right -> %u",
			    sys->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand),
			    sys->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand));
		}

		for (int e = 0; e < 2; e++) {
			vr::Texture_t t = { eyes[e], vr::TextureType_DirectX, vr::ColorSpace_Gamma };
			ce = comp->Submit(e == 0 ? vr::Eye_Left : vr::Eye_Right, &t);
			if (ce != vr::VRCompositorError_None && submit_errors++ < 5)
				LOG("frame %d Submit(eye %d) -> %d", f, e, ce);
		}
		comp->PostPresentHandoff();
	}
	LOG("done: %d frames, %d submit errors, %d events, left pose valid on %d frames", f, submit_errors, events,
	    pose_valid);
	t0 = now_ms();
	vr::VR_Shutdown();
	LOG("VR_Shutdown took %.1f ms", now_ms() - t0);
	eyes[0]->Release();
	eyes[1]->Release();
	ctx->Release();
	dev->Release();
	LOG("VR_Shutdown ok");
	return 0;
}
