/* Force-included into the Windows hello_xr build: what MSVC's headers provide and mingw-w64's lack. */
#pragma once
#ifdef __cplusplus
#include <mutex>
#include <d3d11.h>

struct CD3D11_DEPTH_STENCIL_VIEW_DESC : public D3D11_DEPTH_STENCIL_VIEW_DESC {
    CD3D11_DEPTH_STENCIL_VIEW_DESC(D3D11_DSV_DIMENSION dimension, DXGI_FORMAT format, UINT mip_slice, UINT first_slice,
                                   UINT array_size)
    {
        Format = format;
        ViewDimension = dimension;
        Flags = 0;
        if (dimension == D3D11_DSV_DIMENSION_TEXTURE2DMSARRAY)
        {
            Texture2DMSArray.FirstArraySlice = first_slice;
            Texture2DMSArray.ArraySize = array_size;
        }
        else
        {
            Texture2DArray.MipSlice = mip_slice;
            Texture2DArray.FirstArraySlice = first_slice;
            Texture2DArray.ArraySize = array_size;
        }
    }
};

struct CD3D11_VIEWPORT : public D3D11_VIEWPORT {
    CD3D11_VIEWPORT(FLOAT x, FLOAT y, FLOAT w, FLOAT h, FLOAT min_depth = 0.0f, FLOAT max_depth = 1.0f)
    {
        TopLeftX = x;
        TopLeftY = y;
        Width = w;
        Height = h;
        MinDepth = min_depth;
        MaxDepth = max_depth;
    }
};
#endif
