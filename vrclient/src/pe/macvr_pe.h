/* MacVR's PE-side additions to Proton's vrclient: D3D11 submits through stock DXMT. */
#pragma once

struct dxmt_slot;

/* Per-Submit state, part of vrcompositor_manual.c's submit_state. */
struct macvr_submit
{
    struct dxmt_slot *slot;
    UINT64 fence;
    LONGLONG t_start, t_copied, t_waited;
};

void macvr_log( const char *fmt, ... ) __attribute__((format(printf, 1, 2)));
void macvr_log_runtime( BOOL loaded );

/* TRUE when the D3D11 texture is DXMT's (not DXVK's: those keep Proton's IDXGIVkInteropSurface path). */
BOOL macvr_dxmt_texture( IUnknown *texture );

/* Copies the eye's D3D11 texture (slice array_index, else eye for arrays, else 0; MSAA resolved) into a DXMT shared
 * texture, waits for it on the CPU and returns a TextureType_Metal texture for the native runtime. texture_out is
 * at least a w_VRTextureWithPose_t; flags loses the depth and motion bits. On failure the texture's handle is NULL,
 * which the unix side refuses with VRCompositorError_InvalidTexture. */
const void *macvr_load_texture_dxmt( uint32_t eye, const void *texture, uint32_t *flags, void *texture_out,
                                     struct macvr_submit *state, uint32_t array_index );
void macvr_free_texture_dxmt( struct macvr_submit *state );
