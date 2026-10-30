/* VarboR's PE-side additions to Proton's vrclient: D3D11 submits through DXMT and DXVK, Vulkan submits, all as Metal
 * textures for the native runtime. */
#pragma once
#include <vulkan/vulkan.h>

struct dxmt_slot;

/* Per-Submit state, part of vrcompositor_manual.c's submit_state. */
struct varbor_submit
{
    struct dxmt_slot *slot;
    UINT64 fence;
    LONGLONG t_start, t_copied, t_waited;
    BOOL locked, overlay, gpu;
    /* VarboR DXMT interop: the game's own id<MTLTexture>, and the DXMT device to resume after the runtime's call */
    struct IDXMTInteropDevice *interop;
    UINT64 direct_texture, signal_event, signal_value;
    /* Vulkan path (vk_pe.c): vk_locked from load to free; DXVK's device and surface while its queue is locked */
    BOOL vk_locked;
    struct IDXGIVkInteropDevice *dxvk;
    struct IDXGIVkInteropSurface *dxvk_surface;
    VkImageLayout dxvk_layout;
    VkImageSubresourceRange dxvk_subresources;
    UINT64 vk_texture;
};

void varbor_log( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
void varbor_log_runtime( BOOL loaded );
LONGLONG varbor_now(void);
/* VRCLIENT_STATS=1: one eye submit's bridge share, from state->t_start to end */
void varbor_stats_add( const struct varbor_submit *state, LONGLONG end );

/* TRUE when the D3D11 texture is DXMT's (not DXVK's: those take vk_pe.c's path). */
BOOL varbor_dxmt_texture( IUnknown *texture );

/* With VarboR DXMT (IDXMTInteropSurface on the texture) the runtime gets the game's own Metal texture, ordered by
 * DXMT's and OpenComposite's MTLSharedEvents. Otherwise copies the eye's D3D11 texture (slice array_index, else eye
 * for arrays, else 0; MSAA resolved) into a DXMT shared texture, syncs the runtime's copy with it and returns a
 * TextureType_Metal texture for the native runtime.
 * texture_out is at least a w_VRTextureWithPose_t; flags loses the depth and motion bits. On failure the texture's
 * handle is NULL, which the unix side refuses with VRCompositorError_InvalidTexture. */
const void *varbor_load_texture_dxmt( uint32_t eye, const void *texture, uint32_t *flags, void *texture_out,
                                     struct varbor_submit *state, uint32_t array_index );
/* The same for an overlay's texture, with a ring per overlay handle. */
const void *varbor_load_overlay_dxmt( uint64_t overlay, const void *texture, uint32_t *flags, void *texture_out,
                                     struct varbor_submit *state );
/* After the runtime's call; required after every load (releases the bridge's lock). */
void varbor_free_texture_dxmt( struct varbor_submit *state );

/* DXVK's D3D11 textures (TextureType_DirectX with IDXGIVkInteropSurface) and Vulkan games' textures
 * (TextureType_Vulkan) as TextureType_Metal: the image's own MTLTexture, or a copy (vk_unix.mm). Same contract as
 * the DXMT functions above; varbor_free_texture_vk after every load. */
const void *varbor_load_texture_vk( uint32_t eye, const void *texture, uint32_t *flags, void *texture_out,
                                   struct varbor_submit *state, uint32_t array_index );
const void *varbor_load_overlay_vk( uint64_t overlay, const void *texture, uint32_t *flags, void *texture_out,
                                   struct varbor_submit *state );
void varbor_free_texture_vk( struct varbor_submit *state );
/* TRUE for a DXVK D3D11 texture */
BOOL varbor_dxvk_texture( IUnknown *texture );
