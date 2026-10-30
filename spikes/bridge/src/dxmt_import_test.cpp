// Feasibility test for the stock-DXMT import path the bridge would use (docs/bridge-plan.md, "Interop").
// Runs as a Windows x86_64 exe under CrossOver Wine with DXMT. Plays both roles in one process:
//  - "service": winemetal exports create a private MTLSharedTexture + MTLSharedEvent and register their
//    Mach ports in the bootstrap namespace (what Monado's service + the bridge's unix side would do);
//  - "bridge": wraps the names in local D3DKMT objects the way DXMT's own creator path does, then opens them
//    with ID3D11Device::OpenSharedResource / ID3D11Device5::OpenSharedFence. No DXMT changes.
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <cstdio>
#include <cstring>
#include <cstdint>

#include "../../../third_party/dxmt/src/util/util_d3dkmt.h"
#include "../../../third_party/dxmt/src/winemetal/winemetal.h"

#define D3DKMT_ESCAPE_UPDATE_RESOURCE_WINE_ 0x80000000u

// Must match dxmt src/d3d11/d3d11_texture_device.cpp
struct SharedResourceData {
  char mach_port_name[54];
  D3D11_RESOURCE_DIMENSION dimension;
  union {
    D3D11_TEXTURE1D_DESC desc1d;
    D3D11_TEXTURE2D_DESC1 desc2d;
    D3D11_TEXTURE3D_DESC1 desc3d;
  } desc;
  D3DKMT_HANDLE mutex_handle;
};

static int fails;
#define CHECK(c, ...)                                                                                                  \
  do {                                                                                                                 \
    printf("%s: ", (c) ? "PASS" : "FAIL");                                                                             \
    printf(__VA_ARGS__);                                                                                               \
    printf("\n");                                                                                                      \
    fflush(stdout);                                                                                                    \
    if (!(c))                                                                                                          \
      fails++;                                                                                                         \
  } while (0)

#define WM(name) static decltype(&::name) p##name;
WM(WMTCopyAllDevices)
WM(NSArray_object)
WM(MTLDevice_newSharedTexture)
WM(WMTBootstrapRegister)
WM(MTLDevice_newSharedEvent)
WM(MTLSharedEvent_createMachPort)
WM(MTLSharedEvent_signaledValue)
#define KM(name) static decltype(&::name) p##name;
KM(D3DKMTOpenAdapterFromLuid)
KM(D3DKMTCreateDevice)
KM(D3DKMTCreateAllocation2)
KM(D3DKMTCreateSynchronizationObject2)
KM(D3DKMTEscape)
KM(D3DKMTShareObjects)

static bool load() {
  HMODULE wm = LoadLibraryA("winemetal.dll"), g = LoadLibraryA("gdi32.dll");
  if (!wm || !g)
    return false;
#define L(m, name) p##name = (decltype(p##name))GetProcAddress(m, #name); if (!p##name) { printf("missing %s\n", #name); return false; }
  L(wm, WMTCopyAllDevices) L(wm, NSArray_object) L(wm, MTLDevice_newSharedTexture) L(wm, WMTBootstrapRegister)
  L(wm, MTLDevice_newSharedEvent) L(wm, MTLSharedEvent_createMachPort) L(wm, MTLSharedEvent_signaledValue)
  L(g, D3DKMTOpenAdapterFromLuid) L(g, D3DKMTCreateDevice) L(g, D3DKMTCreateAllocation2)
  L(g, D3DKMTCreateSynchronizationObject2) L(g, D3DKMTEscape) L(g, D3DKMTShareObjects)
  return true;
}

static void make_name(char (&out)[54], const char *kind) {
  snprintf(out, sizeof(out), "varbor_bridge_%s_%08lx_%08lx", kind, GetCurrentProcessId(), GetTickCount());
}

// The bridge-side wrapping: a KMT global share handle whose private runtime data names our Mach port.
static HANDLE wrap_texture(D3DKMT_HANDLE kmt_device, const char *name, const D3D11_TEXTURE2D_DESC &d) {
  SharedResourceData data = {};
  strncpy(data.mach_port_name, name, sizeof(data.mach_port_name) - 1);
  data.dimension = D3D11_RESOURCE_DIMENSION_TEXTURE2D;
  memcpy(&data.desc.desc2d, &d, sizeof(d));
  data.desc.desc2d.TextureLayout = D3D11_TEXTURE_LAYOUT_UNDEFINED;

  D3DKMT_CREATEALLOCATION create = {};
  create.hDevice = kmt_device;
  create.pPrivateRuntimeData = &data;
  create.PrivateRuntimeDataSize = sizeof(data);
  create.Flags.StandardAllocation = 1;
  create.NumAllocations = 1;
  D3DDDI_ALLOCATIONINFO2 info = {};
  create.pAllocationInfo2 = &info;
  D3DKMT_CREATESTANDARDALLOCATION standard = {};
  create.pStandardAllocation = &standard;
  standard.Type = D3DKMT_STANDARDALLOCATIONTYPE_EXISTINGHEAP;
  create.Flags.ExistingSysMem = 1;
  D3DDDI_ALLOCATIONINFO sysmem = {};
  info.pSystemMem = &sysmem;
  create.Flags.CreateResource = 1;
  create.Flags.CreateShared = 1;
  if (pD3DKMTCreateAllocation2(&create)) {
    printf("D3DKMTCreateAllocation2 failed\n");
    return nullptr;
  }
  return (HANDLE)(uintptr_t)create.hGlobalShare;
}

static HANDLE wrap_fence(D3DKMT_HANDLE kmt_device, const char *name) {
  D3DKMT_CREATESYNCHRONIZATIONOBJECT2 create = {};
  create.hDevice = kmt_device;
  create.Info.Type = D3DDDI_FENCE;
  create.Info.Flags.Shared = 1;
  create.Info.Flags.NtSecuritySharing = 1;
  NTSTATUS st = pD3DKMTCreateSynchronizationObject2(&create);
  printf("  CreateSynchronizationObject2 %#lx obj %#x\n", st, create.hSyncObject);
  if (st)
    return nullptr;
  char buf[54] = {};
  strncpy(buf, name, sizeof(buf) - 1);
  D3DKMT_ESCAPE escape = {};
  escape.Type = (D3DKMT_ESCAPETYPE)D3DKMT_ESCAPE_UPDATE_RESOURCE_WINE_;
  escape.pPrivateDriverData = buf;
  escape.PrivateDriverDataSize = sizeof(buf);
  escape.hContext = create.hSyncObject;
  st = pD3DKMTEscape(&escape);
  printf("  Escape(UPDATE_RESOURCE_WINE) %#lx\n", st);
  OBJECT_ATTRIBUTES attr = {};
  attr.Length = sizeof(attr);
  HANDLE nt = nullptr;
  st = pD3DKMTShareObjects(1, &create.hSyncObject, &attr, GENERIC_ALL, &nt);
  printf("  ShareObjects %#lx handle %p\n", st, nt);
  if (st)
    return nullptr;
  return nt;
}

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  if (!load())
    return 2;

  ID3D11Device *dev0 = nullptr;
  ID3D11DeviceContext *ctx0 = nullptr;
  D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_1;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &fl, 1, D3D11_SDK_VERSION, &dev0,
                                 nullptr, &ctx0);
  CHECK(SUCCEEDED(hr), "D3D11CreateDevice (hr %#lx)", hr);
  if (FAILED(hr))
    return 1;
  ID3D11Device5 *dev = nullptr;
  ID3D11DeviceContext4 *ctx = nullptr;
  dev0->QueryInterface(IID_PPV_ARGS(&dev));
  ctx0->QueryInterface(IID_PPV_ARGS(&ctx));
  CHECK(dev && ctx, "ID3D11Device5 / ID3D11DeviceContext4");

  IDXGIDevice *dxgi_dev = nullptr;
  IDXGIAdapter *adapter = nullptr;
  dev->QueryInterface(IID_PPV_ARGS(&dxgi_dev));
  dxgi_dev->GetAdapter(&adapter);
  DXGI_ADAPTER_DESC ad;
  adapter->GetDesc(&ad);
  printf("adapter: %ls\n", ad.Description);

  D3DKMT_OPENADAPTERFROMLUID open_adapter = {};
  open_adapter.AdapterLuid = ad.AdapterLuid;
  NTSTATUS st = pD3DKMTOpenAdapterFromLuid(&open_adapter);
  D3DKMT_CREATEDEVICE create_dev = {};
  create_dev.hAdapter = open_adapter.hAdapter;
  if (!st)
    st = pD3DKMTCreateDevice(&create_dev);
  CHECK(!st && create_dev.hDevice, "own D3DKMT device (status %#lx)", st);

  obj_handle_t mtl_devices = pWMTCopyAllDevices();
  obj_handle_t mtl = pNSArray_object(mtl_devices, 0);

  // "Service" side: a private shared texture, as Monado would allocate for a D3D11 client.
  const UINT W = 256, H = 128;
  WMTTextureInfo info = {};
  info.pixel_format = WMTPixelFormatRGBA8Unorm;
  info.width = W;
  info.height = H;
  info.depth = 1;
  info.array_length = 1;
  info.type = WMTTextureType2D;
  info.mipmap_level_count = 1;
  info.sample_count = 1;
  info.usage = (WMTTextureUsage)(WMTTextureUsageShaderRead | WMTTextureUsageRenderTarget);
  info.options = WMTResourceStorageModePrivate;
  obj_handle_t tex = pMTLDevice_newSharedTexture(mtl, &info);
  CHECK(tex && info.mach_port, "MTLDevice_newSharedTexture -> port %#x", info.mach_port);
  char tex_name[54];
  make_name(tex_name, "tex");
  CHECK(pWMTBootstrapRegister(tex_name, info.mach_port), "bootstrap register %s", tex_name);

  D3D11_TEXTURE2D_DESC d = {};
  d.Width = W;
  d.Height = H;
  d.MipLevels = 1;
  d.ArraySize = 1;
  d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  d.SampleDesc.Count = 1;
  d.Usage = D3D11_USAGE_DEFAULT;
  d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  HANDLE share = wrap_texture(create_dev.hDevice, tex_name, d);
  CHECK(share != nullptr, "KMT global share handle %p", share);

  ID3D11Texture2D *a = nullptr, *b = nullptr;
  hr = dev->OpenSharedResource(share, IID_PPV_ARGS(&a));
  CHECK(SUCCEEDED(hr) && a, "OpenSharedResource #1 (hr %#lx)", hr);
  hr = dev->OpenSharedResource(share, IID_PPV_ARGS(&b));
  CHECK(SUCCEEDED(hr) && b, "OpenSharedResource #2 (hr %#lx)", hr);
  if (!a || !b)
    return 1;

  // Render through import #1, read back through import #2: proves both wrap the same Metal storage.
  ID3D11RenderTargetView *rtv = nullptr;
  dev->CreateRenderTargetView(a, nullptr, &rtv);
  const float color[4] = {0.0f, 1.0f, 0.5f, 1.0f};
  ctx->ClearRenderTargetView(rtv, color);

  // "Service" side sync object: the bridge wraps the event so the game's context can signal it.
  obj_handle_t event = pMTLDevice_newSharedEvent(mtl);
  mach_port_t event_port = pMTLSharedEvent_createMachPort(event);
  char ev_name[54];
  make_name(ev_name, "ev");
  CHECK(event_port && pWMTBootstrapRegister(ev_name, event_port), "event port %#x registered", event_port);
  HANDLE fence_handle = wrap_fence(create_dev.hDevice, ev_name);
  CHECK(fence_handle != nullptr, "fence NT handle %p", fence_handle);
  ID3D11Fence *fence = nullptr;
  hr = dev->OpenSharedFence(fence_handle, IID_PPV_ARGS(&fence));
  CHECK(SUCCEEDED(hr) && fence, "OpenSharedFence (hr %#lx)", hr);

  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t0);
  if (fence)
    ctx->Signal(fence, 7);
  ctx->Flush();
  uint64_t v = 0;
  for (int i = 0; i < 2000 && (v = pMTLSharedEvent_signaledValue(event)) < 7; i++)
    Sleep(1);
  QueryPerformanceCounter(&t1);
  CHECK(v == 7, "Metal event reached %llu after ID3D11DeviceContext4::Signal (%.2f ms)", (unsigned long long)v,
        (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart);

  D3D11_TEXTURE2D_DESC sd = d;
  sd.Usage = D3D11_USAGE_STAGING;
  sd.BindFlags = 0;
  sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ID3D11Texture2D *staging = nullptr;
  dev->CreateTexture2D(&sd, nullptr, &staging);
  ctx->CopyResource(staging, b);
  D3D11_MAPPED_SUBRESOURCE m;
  hr = ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m);
  uint32_t px = SUCCEEDED(hr) ? ((uint32_t *)m.pData)[(H / 2) * (m.RowPitch / 4) + W / 2] : 0;
  if (SUCCEEDED(hr))
    ctx->Unmap(staging, 0);
  CHECK(px == 0xff80ff00, "pixel via import #2 = %#x (want 0xff80ff00)", px);

  // A swapchain-sized texture: 2 array layers (stereo) is what IOSurface can't do but shared textures can.
  info.array_length = 2;
  info.type = WMTTextureType2DArray;
  info.mach_port = 0;
  obj_handle_t arr = pMTLDevice_newSharedTexture(mtl, &info);
  char arr_name[54];
  make_name(arr_name, "arr");
  pWMTBootstrapRegister(arr_name, info.mach_port);
  d.ArraySize = 2;
  HANDLE arr_share = wrap_texture(create_dev.hDevice, arr_name, d);
  ID3D11Texture2D *c = nullptr;
  hr = arr && arr_share ? dev->OpenSharedResource(arr_share, IID_PPV_ARGS(&c)) : E_FAIL;
  CHECK(SUCCEEDED(hr) && c, "2-layer shared texture import (hr %#lx)", hr);

  printf("%s\n", fails ? "SOME FAILED" : "ALL PASS");
  return fails ? 1 : 0;
}
