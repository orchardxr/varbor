/* Which D3D11 engine a game's eye textures come from, and how to name an unsupported one to the user. No Wine or
 * Windows headers: dxmt_pe.c, dxmt_unix.mm and tests/engine_test.c include it. */
#pragma once
#include <stdio.h>
#include <string.h>

enum varbor_engine
{
    VARBOR_ENGINE_DXVK,
    VARBOR_ENGINE_DXMT,
    VARBOR_ENGINE_UNSUPPORTED,
};

static inline int varbor_ieq( const char *a, const char *b )
{
    for (; *a && *b; a++, b++)
        if ((*a | 0x20) != (*b | 0x20)) return 0;
    return *a == *b;
}

/* dxvk_interop: the texture has IDXGIVkInteropSurface. dxmt_name: the bootstrap name DXMT gave a shared texture made on
 * the game's device (NULL when it has none, as with wined3d or D3DMetal). */
static inline enum varbor_engine varbor_classify_engine( int dxvk_interop, const char *dxmt_name )
{
    if (dxvk_interop) return VARBOR_ENGINE_DXVK;
    if (dxmt_name && !strncmp( dxmt_name, "DXMT_", 5 )) return VARBOR_ENGINE_DXMT;
    return VARBOR_ENGINE_UNSUPPORTED;
}

/* What an unsupported device most likely is, from CX_GRAPHICS_BACKEND and the Wine flavour. With nothing set CrossOver
 * picks D3DMetal, which arm64 Wine (FEX) can't load, so Wine's own wined3d does the D3D11. A DXMT or DXVK request that
 * still gave an unsupported device didn't load (stock FEX runners have no ARM64EC DXVK). */
static inline const char *varbor_engine_description( const char *backend, int arm64_wine, char *buf, size_t size )
{
    if (!backend || !*backend || varbor_ieq( backend, "auto" ))
        snprintf( buf, size, arm64_wine ? "wined3d (CrossOver's default, D3DMetal, can't run under FEX, so Wine's own "
                                          "D3D11 took over; no graphics engine is set)"
                                        : "D3DMetal (CrossOver's default; no graphics engine is set)" );
    else if (varbor_ieq( backend, "d3dmetal" ))
        snprintf( buf, size, arm64_wine ? "wined3d (D3DMetal can't run under FEX)" : "D3DMetal" );
    else if (varbor_ieq( backend, "dxmt" ) || varbor_ieq( backend, "dxvk" ))
        snprintf( buf, size, "wined3d (CX_GRAPHICS_BACKEND=%s is set, but %s didn't load)", backend,
                  varbor_ieq( backend, "dxmt" ) ? "DXMT" : "DXVK" );
    else if (varbor_ieq( backend, "wined3d" ))
        snprintf( buf, size, "wined3d (CX_GRAPHICS_BACKEND=wined3d)" );
    else
        snprintf( buf, size, "%s (CX_GRAPHICS_BACKEND=%s)", backend, backend );
    return buf;
}
