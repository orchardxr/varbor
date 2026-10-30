#include <stdarg.h>
#include <stddef.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"

#include "unix_private.h"
#include "macvr_unixlib.h"

#if 0
#pragma makedep unix
#endif

NTSTATUS macvr_input_internal( void *args )
{
    struct macvr_input_internal_params *params = (struct macvr_input_internal_params *)args;
    typedef uint64_t (*method)( void *, uint64_t, uint64_t, uint64_t );
    void *object = (void *)(uintptr_t)params->u_iface;
    method *vtable = *(method **)object;

    params->_ret = vtable[params->index]( object, params->a, params->b, params->c );
    return 0;
}
