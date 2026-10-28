// Force-included into the OpenComposite build: MSVC d3d11.h helpers that mingw-w64 lacks.
#pragma once
#if defined(__cplusplus) && defined(__MINGW32__)
#include <d3d11.h>

struct CD3D11_VIEWPORT : public D3D11_VIEWPORT {
	CD3D11_VIEWPORT() = default;
	CD3D11_VIEWPORT(FLOAT x, FLOAT y, FLOAT w, FLOAT h, FLOAT min_depth = 0.0f, FLOAT max_depth = 1.0f)
	{
		TopLeftX = x;
		TopLeftY = y;
		Width = w;
		Height = h;
		MinDepth = min_depth;
		MaxDepth = max_depth;
	}
	CD3D11_VIEWPORT(ID3D11Texture2D* tex, ID3D11RenderTargetView* rtv, FLOAT x = 0.0f, FLOAT y = 0.0f,
	    FLOAT min_depth = 0.0f, FLOAT max_depth = 1.0f)
	{
		D3D11_TEXTURE2D_DESC td;
		tex->GetDesc(&td);
		D3D11_RENDER_TARGET_VIEW_DESC rd;
		rtv->GetDesc(&rd);
		UINT mip = 0;
		switch (rd.ViewDimension) {
		case D3D11_RTV_DIMENSION_TEXTURE2D: mip = rd.Texture2D.MipSlice; break;
		case D3D11_RTV_DIMENSION_TEXTURE2DARRAY: mip = rd.Texture2DArray.MipSlice; break;
		default: break;
		}
		UINT w = td.Width >> mip, h = td.Height >> mip;
		TopLeftX = x;
		TopLeftY = y;
		Width = (FLOAT)(w ? w : 1) - x;
		Height = (FLOAT)(h ? h : 1) - y;
		MinDepth = min_depth;
		MaxDepth = max_depth;
	}
};
#endif
