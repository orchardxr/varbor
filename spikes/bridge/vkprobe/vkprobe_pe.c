/* PE side: loads the unixlib the way winecrt0's __wine_init_unix_call does, without linking winecrt0. */
#include <windows.h>
#include <winternl.h>
#include "probe.h"

typedef NTSTATUS (WINAPI *dispatcher_t)(UINT64, unsigned int, void *);
typedef NTSTATUS (WINAPI *query_vm_t)(HANDLE, const void *, int, void *, SIZE_T, SIZE_T *);

static UINT64 unixlib;
static dispatcher_t *dispatcher;

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        HMODULE ntdll = GetModuleHandleA("ntdll.dll");
        query_vm_t query = (query_vm_t)GetProcAddress(ntdll, "NtQueryVirtualMemory");
        dispatcher = (dispatcher_t *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
        DisableThreadLibraryCalls(inst);
        /* 1000 = MemoryWineLoadUnixLib (MemoryWineUnixFuncs before Wine 10) */
        if (!query || !dispatcher || query(GetCurrentProcess(), inst, 1000, &unixlib, sizeof(unixlib), NULL))
            unixlib = 0;
    }
    return TRUE;
}

__declspec(dllexport) int WINAPI vkprobe_call(unsigned int code, void *args)
{
    if (!unixlib) return -1;
    return (*dispatcher)(unixlib, code, args);
}
