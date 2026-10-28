// M2 step 1: D3D11 on stock DXVK renders into a Monado swapchain through the x86_64 IPC client that vkprobe.so loads.
#include <windows.h>
#include <d3d11_3.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include "probe.h"

typedef uint64_t VkHandle;

struct IDXGIVkInteropDevice : public IUnknown {
  virtual void STDMETHODCALLTYPE GetVulkanHandles(void **pInstance, void **pPhysDev, void **pDevice) = 0;
  virtual void STDMETHODCALLTYPE GetSubmissionQueue(void **pQueue, uint32_t *pQueueFamilyIndex) = 0;
  virtual void STDMETHODCALLTYPE TransitionSurfaceLayout(IUnknown *pSurface, const void *pSubresources, int OldLayout,
                                                         int NewLayout) = 0;
  virtual void STDMETHODCALLTYPE FlushRenderingCommands() = 0;
  virtual void STDMETHODCALLTYPE LockSubmissionQueue() = 0;
  virtual void STDMETHODCALLTYPE ReleaseSubmissionQueue() = 0;
};
struct IDXGIVkInteropDevice1 : public IDXGIVkInteropDevice {
  virtual void STDMETHODCALLTYPE GetSubmissionQueue1(void **pQueue, uint32_t *pQueueIndex, uint32_t *pQueueFamilyIndex) = 0;
  virtual HRESULT STDMETHODCALLTYPE CreateTexture2DFromVkImage(const D3D11_TEXTURE2D_DESC1 *pDesc, VkHandle vkImage,
                                                               ID3D11Texture2D **ppTexture2D) = 0;
};
__CRT_UUID_DECL(IDXGIVkInteropDevice1, 0xe2ef5fa5, 0xdc21, 0x4af7, 0x90, 0xc4, 0xf6, 0x7e, 0xf6, 0xa0, 0x93, 0x24);

static int fails;
#define CHECK(c, ...)                                                                                                  \
  do {                                                                                                                 \
    printf("%s: ", (c) ? "PASS" : "FAIL");                                                                             \
    printf(__VA_ARGS__);                                                                                               \
    printf("\n");                                                                                                      \
    if (!(c))                                                                                                          \
      fails++;                                                                                                         \
  } while (0)

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  int frames = argc > 1 ? atoi(argv[1]) : 90;
  HMODULE probe = LoadLibraryA("vkprobe.dll");
  auto call = probe ? (int(WINAPI *)(unsigned, void *))GetProcAddress(probe, "vkprobe_call") : nullptr;
  CHECK(call != nullptr, "vkprobe.dll loaded");
  if (!call)
    return 1;

  ID3D11Device *dev0 = nullptr;
  ID3D11DeviceContext *ctx = nullptr;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &fl, 1, D3D11_SDK_VERSION, &dev0,
                                 nullptr, &ctx);
  CHECK(SUCCEEDED(hr), "D3D11CreateDevice (hr %#lx)", hr);
  if (FAILED(hr))
    return 1;
  ID3D11DeviceContext1 *ctx1 = nullptr;
  ctx->QueryInterface(__uuidof(ID3D11DeviceContext1), (void **)&ctx1);
  IDXGIVkInteropDevice1 *interop = nullptr;
  hr = dev0->QueryInterface(__uuidof(IDXGIVkInteropDevice1), (void **)&interop);
  CHECK(SUCCEEDED(hr) && interop && ctx1, "IDXGIVkInteropDevice1 + ID3D11DeviceContext1");
  if (!interop || !ctx1)
    return 1;

  probe_init init = {};
  void *inst, *pd, *vdev, *queue;
  uint32_t qindex = 0, qfamily = 0;
  interop->GetVulkanHandles(&inst, &pd, &vdev);
  interop->GetSubmissionQueue1(&queue, &qindex, &qfamily);
  init.pe_instance = (uint64_t)inst;
  init.pe_physdev = (uint64_t)pd;
  init.pe_device = (uint64_t)vdev;
  init.pe_queue = (uint64_t)queue;
  call(PROBE_INIT, &init);
  CHECK(init.status == 0, "unwrapped DXVK's handles: %s", init.info);
  if (init.status)
    return 1;
  if (argc > 1 && !strcmp(argv[1], "mti")) {
    int32_t failed = 0;
    interop->LockSubmissionQueue();
    call(PROBE_METAL_TEXTURE, &failed);
    interop->ReleaseSubmissionQueue();
    printf("%s\n", failed ? "SOME FAILED" : "ALL PASS");
    return failed ? 1 : 0;
  }

  xrprobe_init xi = {};
  xi.host_instance = init.host_instance;
  xi.host_physdev = init.host_physdev;
  xi.host_device = init.host_device;
  xi.queue_family = qfamily;
  xi.queue_index = qindex;
  xi.width = 320;
  xi.height = 240;
  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  interop->LockSubmissionQueue();
  call(XRPROBE_INIT, &xi);
  interop->ReleaseSubmissionQueue();
  CHECK(xi.status == 0, "x86_64 libopenxr_monado: instance, session on DXVK's device, swapchain: %s", xi.info);
  if (xi.status)
    return 1;

  ID3D11RenderTargetView *rtv[XRPROBE_MAX_IMAGES] = {};
  for (uint32_t i = 0; i < xi.image_count; i++) {
    D3D11_TEXTURE2D_DESC1 d = {};
    d.Width = xi.width;
    d.Height = xi.height;
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *tex = nullptr;
    hr = interop->CreateTexture2DFromVkImage(&d, xi.images[i], &tex);
    if (SUCCEEDED(hr))
      hr = dev0->CreateRenderTargetView(tex, nullptr, &rtv[i]);
    CHECK(SUCCEEDED(hr), "swapchain image %u (VkImage %#llx) wrapped as ID3D11Texture2D + RTV", i,
          (unsigned long long)xi.images[i]);
    if (FAILED(hr))
      return 1;
  }

  double end_ms[1000], ovh_ms[1000];
  bool ok = true;
  if (frames > 1000)
    frames = 1000;
  for (int i = 0; i < frames; i++) {
    xrprobe_frame fr = {};
    interop->LockSubmissionQueue();
    call(XRPROBE_BEGIN, &fr);
    interop->ReleaseSubmissionQueue();
    ok = ok && fr.status == 0;
    if (fr.status)
      break;
    const float left[4] = {1.0f, 0.5f, 0.0f, 1.0f}, right[4] = {0.0f, 0.4f, 1.0f, 1.0f}, bar[4] = {1, 1, 1, 1};
    D3D11_RECT l = {0, 0, (LONG)xi.width / 2, (LONG)xi.height}, r = {(LONG)xi.width / 2, 0, (LONG)xi.width, (LONG)xi.height};
    LONG x = (i * 4) % (xi.width / 2 - 16);
    D3D11_RECT b[2] = {{x, 100, x + 16, 140}, {(LONG)xi.width / 2 + x, 100, (LONG)xi.width / 2 + x + 16, 140}};
    ctx1->ClearView(rtv[fr.index], left, &l, 1);
    ctx1->ClearView(rtv[fr.index], right, &r, 1);
    ctx1->ClearView(rtv[fr.index], bar, b, 2);
    QueryPerformanceCounter(&t0);
    interop->FlushRenderingCommands();
    interop->LockSubmissionQueue();
    call(XRPROBE_END, &fr);
    interop->ReleaseSubmissionQueue();
    QueryPerformanceCounter(&t1);
    ok = ok && fr.status == 0;
    if (fr.status) {
      printf("  %s\n", fr.info);
      break;
    }
    end_ms[i] = fr.end_ns / 1e6;
    ovh_ms[i] = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
  }
  auto pct = [](double *v, int n, double p) {
    static double t[1000];
    for (int i = 0; i < n; i++) t[i] = v[i];
    for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (t[j] < t[i]) { double x = t[i]; t[i] = t[j]; t[j] = x; }
    return t[(int)(p * (n - 1))];
  };
  CHECK(ok, "%d frames: release+xrEndFrame p50 %.3f p99 %.3f ms; flush+lock+release+end p50 %.3f p99 %.3f ms", frames,
        pct(end_ms, frames, 0.5), pct(end_ms, frames, 0.99), pct(ovh_ms, frames, 0.5), pct(ovh_ms, frames, 0.99));
  interop->LockSubmissionQueue();
  call(XRPROBE_SHUTDOWN, nullptr);
  interop->ReleaseSubmissionQueue();
  printf("%s\n", fails ? "SOME FAILED" : "ALL PASS");
  return fails ? 1 : 0;
}
