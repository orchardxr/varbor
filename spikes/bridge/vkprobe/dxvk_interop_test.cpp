// Feasibility test for the bridge's D3D11 path on stock DXVK (docs/bridge-plan.md): a D3D11 texture backed by
// an IOSurface the unix side imports on DXVK's own host VkDevice, rendered by D3D11, then GPU-signalled through a
// timeline semaphore imported from an MTLSharedEvent, submitted on DXVK's queue under LockSubmissionQueue.
#include <windows.h>
#include <d3d11_3.h>
#include <cstdio>
#include <cstdint>
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

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  HMODULE probe = LoadLibraryA("vkprobe.dll");
  auto call = probe ? (int(WINAPI *)(unsigned, void *))GetProcAddress(probe, "vkprobe_call") : nullptr;
  CHECK(call != nullptr, "vkprobe.dll (builtin PE + unixlib) loaded from WINEDLLPATH");
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
  IDXGIVkInteropDevice1 *interop = nullptr;
  hr = dev0->QueryInterface(__uuidof(IDXGIVkInteropDevice1), (void **)&interop);
  CHECK(SUCCEEDED(hr) && interop, "IDXGIVkInteropDevice1 (DXVK) (hr %#lx)", hr);
  if (!interop)
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
  printf("  PE handles inst %p pd %p dev %p queue %p (family %u index %u)\n", inst, pd, vdev, queue, qfamily, qindex);
  printf("  host handles inst %#llx pd %#llx dev %#llx queue %#llx\n", (unsigned long long)init.host_instance,
         (unsigned long long)init.host_physdev, (unsigned long long)init.host_device,
         (unsigned long long)init.host_queue);
  printf("  %s\n", init.info);
  CHECK(init.status == 0, "unwrapped winevulkan handles to MoltenVK objects");
  if (init.status)
    return 1;

  const UINT W = 256, H = 128;
  probe_image img = {};
  img.width = W;
  img.height = H;
  call(PROBE_IMPORT_IMAGE, &img);
  printf("  %s\n", img.info);
  CHECK(img.status == 0, "IOSurface-backed VkImage + MTLSharedEvent timeline semaphore on DXVK's host device");
  if (img.status)
    return 1;

  D3D11_TEXTURE2D_DESC1 d = {};
  d.Width = W;
  d.Height = H;
  d.MipLevels = 1;
  d.ArraySize = 1;
  d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d.SampleDesc.Count = 1;
  d.Usage = D3D11_USAGE_DEFAULT;
  d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  ID3D11Texture2D *tex = nullptr;
  hr = interop->CreateTexture2DFromVkImage(&d, img.image, &tex);
  CHECK(SUCCEEDED(hr) && tex, "CreateTexture2DFromVkImage (hr %#lx)", hr);
  if (!tex)
    return 1;

  ID3D11RenderTargetView *rtv = nullptr;
  hr = dev0->CreateRenderTargetView(tex, nullptr, &rtv);
  const float color[4] = {1.0f, 0.5f, 0.0f, 1.0f};
  ctx->ClearRenderTargetView(rtv, color);

  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  interop->FlushRenderingCommands();
  interop->LockSubmissionQueue();
  probe_submit sub = {};
  sub.value = 1;
  call(PROBE_SUBMIT_SIGNAL, &sub);
  interop->ReleaseSubmissionQueue();
  QueryPerformanceCounter(&t1);
  printf("  %s\n", sub.info);
  CHECK(sub.status == 0, "signal submitted under Lock/ReleaseSubmissionQueue (%.3f ms incl. flush)",
        (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart);

  probe_read rd = {};
  rd.value = 1;
  rd.x = W / 2;
  rd.y = H / 2;
  call(PROBE_WAIT_READ, &rd);
  CHECK(rd.status == 0, "MTLSharedEvent reached 1 (waited %.3f ms)", rd.waited_ns / 1e6);
  CHECK(rd.pixel == 0xffff8000, "IOSurface pixel after D3D11 clear = %#x (want 0xffff8000)", rd.pixel);

  // Steady state: 200 frames of clear -> flush -> locked signal -> wait.
  double submit_ms[200], wait_ms[200];
  bool ok = true;
  for (int i = 0; i < 200; i++) {
    const float c[4] = {i / 255.0f, 0.0f, 1.0f, 1.0f};
    ctx->ClearRenderTargetView(rtv, c);
    QueryPerformanceCounter(&t0);
    interop->FlushRenderingCommands();
    interop->LockSubmissionQueue();
    sub.value = 2 + i;
    call(PROBE_SUBMIT_SIGNAL, &sub);
    interop->ReleaseSubmissionQueue();
    QueryPerformanceCounter(&t1);
    submit_ms[i] = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
    rd.value = 2 + i;
    call(PROBE_WAIT_READ, &rd);
    wait_ms[i] = rd.waited_ns / 1e6;
    ok = ok && rd.status == 0 && rd.pixel == (0xff0000ffu | (uint32_t)i << 16);
  }
  auto pct = [](double *v, int n, double p) {
    double t[200];
    for (int i = 0; i < n; i++) t[i] = v[i];
    for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (t[j] < t[i]) { double x = t[i]; t[i] = t[j]; t[j] = x; }
    return t[(int)(p * (n - 1))];
  };
  CHECK(ok, "200 frames pixel-exact; flush+locked submit p50 %.3f p99 %.3f ms; GPU done after submit p50 %.3f p99 %.3f ms",
        pct(submit_ms, 200, 0.5), pct(submit_ms, 200, 0.99), pct(wait_ms, 200, 0.5), pct(wait_ms, 200, 0.99));

  printf("%s\n", fails ? "SOME FAILED" : "ALL PASS");
  return fails ? 1 : 0;
}
