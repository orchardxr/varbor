/* M2 step 4: XR_KHR_win32_convert_performance_counter_time through wineopenxr, in a D3D11 frame loop.
 * Also measures the thunk cost of a call that stays in the client (xrGetInstanceProperties). */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#define XR_USE_PLATFORM_WIN32
#define XR_USE_GRAPHICS_API_D3D11
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

static int fails;
#define CHECK(c, ...) do { printf("%s: ", (c) ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!(c)) fails++; } while (0)
#define XR(call) do { XrResult r_ = (call); if (XR_FAILED(r_)) { printf("FAIL: %s = %d\n", #call, r_); return 1; } } while (0)
#define GET(name) PFN_##name name; XR(xrGetInstanceProcAddr(instance, #name, (PFN_xrVoidFunction *)&name))

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
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    const char *exts[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME, XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME};
    XrInstanceCreateInfo ici = {XR_TYPE_INSTANCE_CREATE_INFO};
    XrInstance instance;
    XrSystemId system;
    LARGE_INTEGER freq, q, q2, t0, t1, start;
    static double lead_ms[10000], call_us[10000], wait_ms[10000], end_ms[10000];
    LONGLONG worst_rt = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (frames > 10000) frames = 10000;
    strcpy(ici.applicationInfo.applicationName, "xr_time_test");
    ici.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    ici.enabledExtensionCount = 2;
    ici.enabledExtensionNames = exts;
    XR(xrCreateInstance(&ici, &instance));
    GET(xrConvertWin32PerformanceCounterToTimeKHR);
    GET(xrConvertTimeToWin32PerformanceCounterKHR);
    GET(xrGetD3D11GraphicsRequirementsKHR);
    XrSystemGetInfo sgi = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
    XR(xrGetSystem(instance, &sgi, &system));
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);

    for (int i = 0; i < 10000; i++)
    {
        XrInstanceProperties props = {XR_TYPE_INSTANCE_PROPERTIES};
        QueryPerformanceCounter(&t0);
        xrGetInstanceProperties(instance, &props);
        QueryPerformanceCounter(&t1);
        call_us[i] = (t1.QuadPart - t0.QuadPart) * 1e6 / freq.QuadPart;
    }
    double c50 = pct(call_us, 10000, 0.5), c99 = pct(call_us, 10000, 0.99);
    printf("  xrGetInstanceProperties (loader + PE thunk + unix call + Monado): p50 %.2f us, p99 %.2f us\n", c50, c99);

    for (int i = 0; i < 100000; i++)
    {
        XrTime t;
        QueryPerformanceCounter(&q);
        q.QuadPart += i * 977;
        XR(xrConvertWin32PerformanceCounterToTimeKHR(instance, &q, &t));
        XR(xrConvertTimeToWin32PerformanceCounterKHR(instance, t, &q2));
        if (llabs(q2.QuadPart - q.QuadPart) > worst_rt) worst_rt = llabs(q2.QuadPart - q.QuadPart);
    }
    CHECK(worst_rt == 0, "QPC -> XrTime -> QPC round trip exact over 100000 values (worst %lld ticks, QPC %lld Hz)",
          worst_rt, freq.QuadPart);

    XrGraphicsRequirementsD3D11KHR req = {XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
    XR(xrGetD3D11GraphicsRequirementsKHR(instance, system, &req));
    ID3D11Device *dev;
    D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &fl, 1, D3D11_SDK_VERSION, &dev, NULL, NULL);
    CHECK(SUCCEEDED(hr), "D3D11CreateDevice");
    if (FAILED(hr)) return 1;
    XrGraphicsBindingD3D11KHR gb = {XR_TYPE_GRAPHICS_BINDING_D3D11_KHR, NULL, dev};
    XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &gb, 0, system};
    XrSession session;
    XR(xrCreateSession(instance, &sci, &session));

    for (int ready = 0; !ready;)
    {
        XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
        if (xrPollEvent(instance, &ev) != XR_SUCCESS) { Sleep(1); continue; }
        ready = ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED &&
                ((XrEventDataSessionStateChanged *)&ev)->state == XR_SESSION_STATE_READY;
    }
    XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
    XR(xrBeginSession(session, &bi));

    XrTime prev = 0;
    int monotonic = 1;
    for (int i = 0; i < frames; i++)
    {
        XrEventDataBuffer ev = {XR_TYPE_EVENT_DATA_BUFFER};
        while (xrPollEvent(instance, &ev) == XR_SUCCESS) ev.type = XR_TYPE_EVENT_DATA_BUFFER;
        XrFrameState fs = {XR_TYPE_FRAME_STATE};
        QueryPerformanceCounter(&t0);
        XR(xrWaitFrame(session, NULL, &fs));
        QueryPerformanceCounter(&t1);
        wait_ms[i] = (t1.QuadPart - t0.QuadPart) * 1e3 / freq.QuadPart;
        XR(xrConvertTimeToWin32PerformanceCounterKHR(instance, fs.predictedDisplayTime, &q));
        lead_ms[i] = (q.QuadPart - t1.QuadPart) * 1e3 / freq.QuadPart;
        monotonic &= fs.predictedDisplayTime > prev;
        prev = fs.predictedDisplayTime;
        XR(xrBeginFrame(session, NULL));
        XrFrameEndInfo fei = {XR_TYPE_FRAME_END_INFO, NULL, fs.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE};
        QueryPerformanceCounter(&t0);
        XR(xrEndFrame(session, &fei));
        QueryPerformanceCounter(&t1);
        end_ms[i] = (t1.QuadPart - t0.QuadPart) * 1e3 / freq.QuadPart;
    }
    double first[50], last[50];
    for (int i = 0; i < 50 && frames >= 100; i++)
    {
        first[i] = lead_ms[i];
        last[i] = lead_ms[frames - 50 + i];
    }
    double drift = frames >= 100 ? pct(last, 50, 0.5) - pct(first, 50, 0.5) : 0;
    double l0 = pct(lead_ms, frames, 0.0), l50 = pct(lead_ms, frames, 0.5), l100 = pct(lead_ms, frames, 1.0);
    CHECK(monotonic && l50 > 0 && l100 < 100, "%d frames: predictedDisplayTime as QPC is ahead of QPC after xrWaitFrame by "
          "min %.2f / p50 %.2f / max %.2f ms", frames, l0, l50, l100);
    printf("  median lead, last 50 frames - first 50 frames: %.3f ms over %.1f s\n", drift,
           (t1.QuadPart - start.QuadPart) / (double)freq.QuadPart);
    printf("  xrWaitFrame p50 %.2f ms; xrEndFrame (no layers, D3D11 lock) p50 %.3f p99 %.3f ms\n", pct(wait_ms, frames, 0.5),
           pct(end_ms, frames, 0.5), pct(end_ms, frames, 0.99));

    xrRequestExitSession(session);
    xrDestroySession(session);

    xrDestroyInstance(instance);
    ID3D11Device_Release(dev);
    printf("%s\n", fails ? "SOME FAILED" : "ALL PASS");
    return fails ? 1 : 0;
}
