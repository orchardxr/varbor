/* D3D11 submits through DXVK (CX_GRAPHICS_BACKEND=dxvk) and Vulkan games' submits, for the Metal-only native
 * runtime. DXVK's side is Proton's: IDXGIVkInteropSurface names the VkImage, its layout and DXVK's device and queue,
 * the image goes to TRANSFER_SRC_OPTIMAL, DXVK flushes, and its submission queue stays locked until after the
 * runtime's call. vk_unix.mm turns the image into a Metal texture for the runtime (macvr_vk_begin_params). A Vulkan
 * game's texture comes in that state already (OpenVR's contract), its queue is the game's. */
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define COBJMACROS
#include <windows.h>
#include <d3d11_4.h>

#include "dxvk-interop.h"
#include "vrclient_private.h"
#include "macvr_pe.h"

WINE_DEFAULT_DEBUG_CHANNEL(vrclient);

enum { TARGET_OVERLAY = 2 };

/* Held from a load to its free: the unix side's per-device state and OpenComposite's sync are one at a time. */
static SRWLOCK vk_lock = SRWLOCK_INIT;
static int copy_only = -1;

BOOL macvr_dxvk_texture( IUnknown *texture )
{
    IUnknown *surface;
    if (!texture || FAILED(IUnknown_QueryInterface( texture, &IID_IDXGIVkInteropSurface, (void **)&surface )))
        return FALSE;
    IUnknown_Release( surface );
    return TRUE;
}

static void log_path( const struct macvr_vk_begin_params *p, BOOL dxvk )
{
    static char last[2][256];
    char *prev = last[p->target == TARGET_OVERLAY];
    if (!strcmp( prev, p->info )) return;
    strcpy( prev, p->info );
    macvr_log( "%s %s: %s", dxvk ? "DXVK" : "Vulkan", p->target == TARGET_OVERLAY ? "overlay" : "eye", p->info );
}

static const void *metal_texture( const w_Texture_t *in, uint32_t *flags, w_VRTextureWithPose_t *out, UINT64 texture )
{
    UINT pose = *flags & Submit_TextureWithPose;
    memcpy( out, in, pose ? sizeof(w_VRTextureWithPose_t) : sizeof(w_Texture_t) );
    out->handle = (void *)(UINT_PTR)texture;
    out->eType = TextureType_Metal;
    *flags = (*flags & ~(Submit_TextureWithMotion | Submit_VulkanTextureWithArrayData)) | pose;
    return out;
}

static const void *load( uint32_t target, uint64_t target_id, uint32_t slice, const w_Texture_t *in, uint32_t *flags,
                         void *texture_out, struct macvr_submit *state, BOOL copy )
{
    struct macvr_vk_begin_params p = {0};
    w_VRVulkanTextureData_t vkdata;

    AcquireSRWLockExclusive( &vk_lock );
    state->vk_locked = TRUE;
    state->vk_texture = 0;
    state->dxvk = NULL;
    state->dxvk_surface = NULL;
    state->overlay = target == TARGET_OVERLAY;
    state->t_start = macvr_now();
    if (copy_only < 0)
    {
        const char *env = getenv( "VRCLIENT_VK_DIRECT" );
        copy_only = env && !atoi( env );
        if (copy_only) macvr_log( "VRCLIENT_VK_DIRECT=0: copying Vulkan images" );
    }

    if (in->eType == TextureType_DirectX)
    {
        VkImageCreateInfo image_info;
        IDXGIVkInteropSurface *surface;
        if (!in->handle || FAILED(IUnknown_QueryInterface( (IUnknown *)in->handle, &IID_IDXGIVkInteropSurface,
                                                            (void **)&surface )))
            goto done;
        vrclient_translate_texture_dxvk( in, &vkdata, surface, &state->dxvk, &state->dxvk_layout, &image_info );
        state->dxvk_surface = surface;
        state->dxvk_subresources.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        state->dxvk_subresources.baseMipLevel = 0;
        state->dxvk_subresources.levelCount = image_info.mipLevels;
        state->dxvk_subresources.baseArrayLayer = 0;
        state->dxvk_subresources.layerCount = image_info.arrayLayers;
        state->dxvk->lpVtbl->TransitionSurfaceLayout( state->dxvk, surface, &state->dxvk_subresources,
                                                      state->dxvk_layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL );
        state->dxvk->lpVtbl->FlushRenderingCommands( state->dxvk );
        state->dxvk->lpVtbl->LockSubmissionQueue( state->dxvk );
    }
    else
    {
        if (!in->handle) goto done;
        vkdata = *(const w_VRVulkanTextureData_t *)in->handle;
        if (*flags & Submit_VulkanTextureWithArrayData)
            slice = ((const w_VRVulkanTextureArrayData_t *)in->handle)->m_unArrayIndex;
    }
    state->t_copied = macvr_now();

    p.device = (UINT_PTR)vkdata.m_pDevice;
    p.physical_device = (UINT_PTR)vkdata.m_pPhysicalDevice;
    p.queue = (UINT_PTR)vkdata.m_pQueue;
    p.queue_family = vkdata.m_nQueueFamilyIndex;
    p.image = vkdata.m_nImage;
    p.format = vkdata.m_nFormat;
    p.width = vkdata.m_nWidth;
    p.height = vkdata.m_nHeight;
    p.samples = vkdata.m_nSampleCount;
    p.slice = slice;
    p.target = target;
    p.target_id = target_id;
    p.copy = copy || copy_only;
    VRCLIENT_CALL( macvr_vk_begin, &p );
    state->t_waited = macvr_now();
    state->vk_texture = p.texture;
    log_path( &p, state->dxvk != NULL );

done:
    return metal_texture( in, flags, texture_out, state->vk_texture );
}

const void *macvr_load_texture_vk( uint32_t eye, const void *texture, uint32_t *flags, void *texture_out,
                                   struct macvr_submit *state, uint32_t array_index )
{
    return load( eye & 1, eye, array_index, texture, flags, texture_out, state, FALSE );
}

/* Overlays (and the skybox) are copied, like DXMT's: OpenComposite may show them long after the call. */
const void *macvr_load_overlay_vk( uint64_t overlay, const void *texture, uint32_t *flags, void *texture_out,
                                   struct macvr_submit *state )
{
    return load( TARGET_OVERLAY, overlay, 0, texture, flags, texture_out, state, TRUE );
}

void macvr_free_texture_vk( struct macvr_submit *state )
{
    if (!state->vk_locked) return;
    if (state->vk_texture)
    {
        struct macvr_vk_end_params e = {0};
        VRCLIENT_CALL( macvr_vk_end, &e );
    }
    if (state->dxvk)
    {
        state->dxvk->lpVtbl->ReleaseSubmissionQueue( state->dxvk );
        state->dxvk->lpVtbl->TransitionSurfaceLayout( state->dxvk, state->dxvk_surface, &state->dxvk_subresources,
                                                      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, state->dxvk_layout );
        state->dxvk->lpVtbl->Release( state->dxvk );
    }
    if (state->dxvk_surface) state->dxvk_surface->lpVtbl->Release( state->dxvk_surface );
    if (state->vk_texture && !state->overlay) macvr_stats_add( state, macvr_now() );
    state->dxvk = NULL;
    state->dxvk_surface = NULL;
    state->vk_texture = 0;
    state->vk_locked = FALSE;
    ReleaseSRWLockExclusive( &vk_lock );
}
