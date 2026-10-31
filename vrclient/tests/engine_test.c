#include <stdio.h>
#include <string.h>
#include "engine.h"

static int failures;

static void expect( int ok, const char *what )
{
    if (ok) return;
    printf( "FAIL: %s\n", what );
    failures++;
}

static int has( const char *backend, int arm64, const char *needle )
{
    char buf[256];
    return strstr( varbor_engine_description( backend, arm64, buf, sizeof(buf) ), needle ) != NULL;
}

int main(void)
{
    expect( varbor_classify_engine( 1, NULL ) == VARBOR_ENGINE_DXVK, "DXVK interop surface" );
    expect( varbor_classify_engine( 1, "DXMT_1" ) == VARBOR_ENGINE_DXVK, "DXVK wins over a name" );
    expect( varbor_classify_engine( 0, "DXMT_0042" ) == VARBOR_ENGINE_DXMT, "DXMT shared name" );
    expect( varbor_classify_engine( 0, NULL ) == VARBOR_ENGINE_UNSUPPORTED, "no name: wined3d or D3DMetal" );
    expect( varbor_classify_engine( 0, "" ) == VARBOR_ENGINE_UNSUPPORTED, "empty name" );
    expect( varbor_classify_engine( 0, "DXM" ) == VARBOR_ENGINE_UNSUPPORTED, "short name" );
    expect( varbor_classify_engine( 0, "dxmt_1" ) == VARBOR_ENGINE_UNSUPPORTED, "names are case-sensitive" );

    expect( has( NULL, 1, "wined3d" ) && has( NULL, 1, "no graphics engine is set" ), "unset on FEX: wined3d" );
    expect( has( "", 1, "wined3d" ), "empty on FEX: wined3d" );
    expect( has( "auto", 1, "wined3d" ) && has( "AUTO", 1, "wined3d" ), "auto on FEX: wined3d" );
    expect( has( NULL, 0, "D3DMetal" ) && !has( NULL, 0, "wined3d" ), "unset on Rosetta: D3DMetal" );
    expect( has( "d3dmetal", 1, "wined3d" ), "d3dmetal on FEX: wined3d" );
    expect( has( "d3dmetal", 0, "D3DMetal" ) && !has( "d3dmetal", 0, "wined3d" ), "d3dmetal on Rosetta" );
    expect( has( "dxvk", 1, "DXVK didn't load" ), "dxvk without ARM64EC DXVK" );
    expect( has( "DXMT", 0, "DXMT didn't load" ), "dxmt that didn't load" );
    expect( has( "wined3d", 1, "CX_GRAPHICS_BACKEND=wined3d" ), "wined3d asked for" );
    expect( has( "vkd3d", 0, "vkd3d (CX_GRAPHICS_BACKEND=vkd3d)" ), "unknown backend named as is" );

    {
        char small[8];
        varbor_engine_description( NULL, 1, small, sizeof(small) );
        expect( strlen( small ) == sizeof(small) - 1, "truncates to the buffer" );
    }

    if (!failures) printf( "engine_test: all passed\n" );
    return failures != 0;
}
