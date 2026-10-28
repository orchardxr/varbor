/* M2 step 5: a D3D11 app with one 2-layer color swapchain and a 2-layer depth swapchain (single-pass stereo, as Unity
 * and UE do), submitted with XR_KHR_composition_layer_depth. Left eye orange, right eye blue, white bar moving.
 * Prints the bridge's per-frame cost of xrReleaseSwapchainImage (slice copies) and xrEndFrame. */
#define COBJMACROS
#include <windows.h>
#include <d3d11_1.h>
#include <stdio.h>
#include <stdlib.h>
#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D11
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

static int fails;
#define CHECK(c, ...) do { printf("%s: ", (c) ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!(c)) fails++; } while (0)
#define XR(call) do { XrResult r_ = (call); if (XR_FAILED(r_)) { printf("FAIL: %s = %d\n", #call, r_); return 1; } } while (0)

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double pct(double *v, int n, double p)
{
    qsort(v, n, sizeof(*v), cmp);
    return v[(int)(p * (n - 1))];
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 200;
    const char *exts[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME, XR_KHR_COMPOSITION_LAYER_DEPTH_EXTENSION_NAME};
    XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
    XrInstance instance;
    XrSystemId system;
    LARGE_INTEGER freq, t0, t1;
    static double release_ms[10000], end_ms[10000];

    setvbuf(stdout, NULL, _IONBF, 0);
    if (frames > 10000) frames = 10000;
    QueryPerformanceFrequency(&freq);
    strcpy(ici.applicationInfo.applicationName, "xr_array_test");
    ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    ici.enabledExtensionCount = 2;
    ici.enabledExtensionNames = exts;
    XR(xrCreateInstance(&ici, &instance));
    PFN_xrGetD3D11GraphicsRequirementsKHR get_req;
    XR(xrGetInstanceProcAddr(instance, "xrGetD3D11GraphicsRequirementsKHR", (PFN_xrVoidFunction *)&get_req));
    XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
    XR(xrGetSystem(instance, &sgi, &system));
    XrGraphicsRequirementsD3D11KHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
    XR(get_req(instance, system, &req));

    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    ID3D11DeviceContext1 *ctx1;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, NULL, &ctx)) ||
        FAILED(ID3D11DeviceContext_QueryInterface(ctx, &IID_ID3D11DeviceContext1, (void **)&ctx1)))
        return 1;
    XrGraphicsBindingD3D11KHR gb = {XR_TYPE_GRAPHICS_BINDING_D3D11_KHR, NULL, dev};
    XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &gb, 0, system};
    XrSession session;
    XR(xrCreateSession(instance, &sci, &session));

    XrSwapchainCreateInfo cci = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
    cci.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    cci.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    cci.sampleCount = 1;
    cci.width = 320;
    cci.height = 240;
    cci.faceCount = 1;
    cci.arraySize = 2;
    cci.mipCount = 1;
    XrSwapchain color, depth;
    XR(xrCreateSwapchain(session, &cci, &color));
    XrSwapchainCreateInfo dci = cci;
    dci.usageFlags = XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    dci.format = DXGI_FORMAT_D32_FLOAT;
    XR(xrCreateSwapchain(session, &dci, &depth));

    XrSwapchainImageD3D11KHR cimg[8], dimg[8];
    uint32_t cn, dn;
    for (int i = 0; i < 8; i++)
        cimg[i] = dimg[i] = (XrSwapchainImageD3D11KHR){XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR};
    XR(xrEnumerateSwapchainImages(color, 8, &cn, (XrSwapchainImageBaseHeader *)cimg));
    XR(xrEnumerateSwapchainImages(depth, 8, &dn, (XrSwapchainImageBaseHeader *)dimg));
    ID3D11RenderTargetView *rtv[8][2];
    ID3D11DepthStencilView *dsv[8][2];
    for (uint32_t i = 0; i < cn; i++)
        for (uint32_t s = 0; s < 2; s++)
        {
            D3D11_RENDER_TARGET_VIEW_DESC rd = {DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_RTV_DIMENSION_TEXTURE2DARRAY};
            rd.Texture2DArray.FirstArraySlice = s;
            rd.Texture2DArray.ArraySize = 1;
            if (FAILED(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)cimg[i].texture, &rd, &rtv[i][s]))) return 1;
        }
    for (uint32_t i = 0; i < dn; i++)
        for (uint32_t s = 0; s < 2; s++)
        {
            D3D11_DEPTH_STENCIL_VIEW_DESC dd = {DXGI_FORMAT_D32_FLOAT, D3D11_DSV_DIMENSION_TEXTURE2DARRAY};
            dd.Texture2DArray.FirstArraySlice = s;
            dd.Texture2DArray.ArraySize = 1;
            if (FAILED(ID3D11Device_CreateDepthStencilView(dev, (ID3D11Resource *)dimg[i].texture, &dd, &dsv[i][s]))) return 1;
        }
    CHECK(1, "2-layer B8G8R8A8 color swapchain (%u images) and 2-layer D32 depth swapchain (%u images)", cn, dn);

    XrReferenceSpaceCreateInfo rsci = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_LOCAL};
    rsci.poseInReferenceSpace.orientation.w = 1;
    XrSpace space;
    XR(xrCreateReferenceSpace(session, &rsci, &space));

    for (int ready = 0; !ready;)
    {
        XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
        if (xrPollEvent(instance, &ev) != XR_SUCCESS) { Sleep(1); continue; }
        ready = ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED &&
                ((XrEventDataSessionStateChanged *)&ev)->state == XR_SESSION_STATE_READY;
    }
    XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
    XR(xrBeginSession(session, &bi));

    for (int f = 0; f < frames; f++)
    {
        XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
        while (xrPollEvent(instance, &ev) == XR_SUCCESS) ev.type = XR_TYPE_EVENT_DATA_BUFFER;
        XrFrameState fs = {XR_TYPE_FRAME_STATE};
        XR(xrWaitFrame(session, NULL, &fs));
        XR(xrBeginFrame(session, NULL));
        XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
        XrViewState vs = {XR_TYPE_VIEW_STATE};
        XrViewLocateInfo vli = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, fs.predictedDisplayTime, space};
        uint32_t vn;
        XR(xrLocateViews(session, &vli, &vs, 2, &vn, views));

        uint32_t ci, di;
        XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
        XR(xrAcquireSwapchainImage(color, NULL, &ci));
        XR(xrWaitSwapchainImage(color, &wi));
        XR(xrAcquireSwapchainImage(depth, NULL, &di));
        XR(xrWaitSwapchainImage(depth, &wi));
        const float eye[2][4] = {{1.0f, 0.5f, 0.0f, 1.0f}, {0.0f, 0.4f, 1.0f, 1.0f}}, bar[4] = {1, 1, 1, 1};
        LONG x = (f * 4) % (320 - 16);
        D3D11_RECT r = {x, 100, x + 16, 140};
        for (int s = 0; s < 2; s++)
        {
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv[ci][s], eye[s]);
            ID3D11DeviceContext1_ClearView(ctx1, (ID3D11View *)rtv[ci][s], bar, &r, 1);
            ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv[di][s], D3D11_CLEAR_DEPTH, 1.0f, 0);
        }
        QueryPerformanceCounter(&t0);
        XR(xrReleaseSwapchainImage(color, NULL));
        QueryPerformanceCounter(&t1);
        release_ms[f] = (t1.QuadPart - t0.QuadPart) * 1e3 / freq.QuadPart;
        XR(xrReleaseSwapchainImage(depth, NULL));

        XrCompositionLayerDepthInfoKHR depth_info[2];
        XrCompositionLayerProjectionView pv[2];
        for (int s = 0; s < 2; s++)
        {
            depth_info[s] = (XrCompositionLayerDepthInfoKHR){XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR};
            depth_info[s].subImage.swapchain = depth;
            depth_info[s].subImage.imageRect.extent.width = 320;
            depth_info[s].subImage.imageRect.extent.height = 240;
            depth_info[s].subImage.imageArrayIndex = s;
            depth_info[s].minDepth = 0;
            depth_info[s].maxDepth = 1;
            depth_info[s].nearZ = 0.05f;
            depth_info[s].farZ = 100;
            pv[s] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, &depth_info[s]};
            pv[s].pose = views[s].pose;
            pv[s].fov = views[s].fov;
            pv[s].subImage.swapchain = color;
            pv[s].subImage.imageRect.extent.width = 320;
            pv[s].subImage.imageRect.extent.height = 240;
            pv[s].subImage.imageArrayIndex = s;
        }
        XrCompositionLayerProjection proj = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, space, 2, pv};
        const XrCompositionLayerBaseHeader *layers[] = {(XrCompositionLayerBaseHeader *)&proj};
        XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
                              fs.shouldRender ? 1 : 0, layers};
        QueryPerformanceCounter(&t0);
        XR(xrEndFrame(session, &fei));
        QueryPerformanceCounter(&t1);
        end_ms[f] = (t1.QuadPart - t0.QuadPart) * 1e3 / freq.QuadPart;
    }
    CHECK(1, "%d frames: xrReleaseSwapchainImage (2 slice copies + 2 host releases) p50 %.3f p99 %.3f ms; "
          "xrEndFrame (layer rewrite + flush + lock) p50 %.3f p99 %.3f ms", frames, pct(release_ms, frames, 0.5),
          pct(release_ms, frames, 0.99), pct(end_ms, frames, 0.5), pct(end_ms, frames, 0.99));

    xrRequestExitSession(session);
    XR(xrDestroySwapchain(color));
    XR(xrDestroySwapchain(depth));
    xrDestroySpace(space);
    xrDestroySession(session);
    xrDestroyInstance(instance);
    printf("%s\n", fails ? "SOME FAILED" : "ALL PASS");
    return fails ? 1 : 0;
}
