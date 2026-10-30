/* IVRInputInternal_002: undocumented and not in the OpenVR SDK, so Proton's generator has no wrapper for it. Half-Life:
 * Alyx asks for it; OpenComposite answers with 20 placeholder methods (all abort). Each slot forwards to the same slot
 * of the native object with the first three integer arguments; the first call of each is logged. */
#include <stdarg.h>
#include <stdint.h>

#include "vrclient_private.h"
#include "varbor_unixlib.h"

void varbor_log( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));

WINE_DEFAULT_DEBUG_CHANNEL(vrclient);

#define METHODS 20

static uint64_t forward( struct w_iface *_this, uint32_t index, uint64_t a, uint64_t b, uint64_t c )
{
    static LONG logged[METHODS];
    struct varbor_input_internal_params params =
    {
        .u_iface = _this->u_iface.handle,
        .index = index,
        .a = a,
        .b = b,
        .c = c,
    };
    if (!InterlockedExchange( &logged[index], 1 ))
        varbor_log( "IVRInputInternal_002 method %u (%#llx, %#llx, %#llx)", index, (unsigned long long)a,
                   (unsigned long long)b, (unsigned long long)c );
    VRCLIENT_CALL( varbor_input_internal, &params );
    return params._ret;
}

#define METHOD(n) \
    DEFINE_THISCALL_WRAPPER(winIVRInputInternal_IVRInputInternal_002_m##n, 28) \
    uint64_t __thiscall winIVRInputInternal_IVRInputInternal_002_m##n( struct w_iface *_this, uint64_t a, uint64_t b, \
                                                                      uint64_t c ) \
    { \
        return forward( _this, n, a, b, c ); \
    }

METHOD(0) METHOD(1) METHOD(2) METHOD(3) METHOD(4) METHOD(5) METHOD(6) METHOD(7) METHOD(8) METHOD(9)
METHOD(10) METHOD(11) METHOD(12) METHOD(13) METHOD(14) METHOD(15) METHOD(16) METHOD(17) METHOD(18) METHOD(19)

extern vtable_ptr winIVRInputInternal_IVRInputInternal_002_vtable;

DEFINE_RTTI_DATA0(winIVRInputInternal_IVRInputInternal_002, 0, ".?AVIVRInputInternal@@")

#define F(n) VTABLE_ADD_FUNC(winIVRInputInternal_IVRInputInternal_002_m##n)
__ASM_BLOCK_BEGIN(winIVRInputInternal_IVRInputInternal_002_vtables)
    __ASM_VTABLE(winIVRInputInternal_IVRInputInternal_002,
        F(0) F(1) F(2) F(3) F(4) F(5) F(6) F(7) F(8) F(9)
        F(10) F(11) F(12) F(13) F(14) F(15) F(16) F(17) F(18) F(19)
    );
__ASM_BLOCK_END
#undef F

struct w_iface *create_winIVRInputInternal_IVRInputInternal_002( struct u_iface u_iface )
{
    struct w_iface *r = HeapAlloc( GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*r) );
    TRACE( "-> %p\n", r );
    varbor_log( "IVRInputInternal_002 -> %p (native %#llx)", r, (unsigned long long)u_iface.handle );
    r->vtable = &winIVRInputInternal_IVRInputInternal_002_vtable;
    r->u_iface = u_iface;
    return r;
}

void destroy_winIVRInputInternal_IVRInputInternal_002( struct w_iface *object )
{
    TRACE( "%p\n", object );
    HeapFree( GetProcessHeap(), 0, object );
}

void init_winIVRInputInternal_rtti( char *base )
{
    init_winIVRInputInternal_IVRInputInternal_002_rtti( base );
}
