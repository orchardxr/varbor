// Minimal CComPtr for building OpenComposite with llvm-mingw (no ATL in mingw-w64).
#pragma once
#include <unknwn.h>

template <class T>
class CComPtr {
public:
	T* p = nullptr;

	CComPtr() = default;
	CComPtr(decltype(nullptr)) {}
	CComPtr(T* lp) : p(lp) { if (p) p->AddRef(); }
	CComPtr(const CComPtr& o) : p(o.p) { if (p) p->AddRef(); }
	CComPtr(CComPtr&& o) noexcept : p(o.p) { o.p = nullptr; }
	~CComPtr() { if (p) p->Release(); }

	T* operator=(T* lp)
	{
		if (lp) lp->AddRef();
		if (p) p->Release();
		p = lp;
		return p;
	}
	T* operator=(const CComPtr& o) { return *this = o.p; }
	T* operator=(CComPtr&& o) noexcept
	{
		if (this != &o) {
			if (p) p->Release();
			p = o.p;
			o.p = nullptr;
		}
		return p;
	}

	operator T*() const { return p; }
	T& operator*() const { return *p; }
	T** operator&() { return &p; }
	T* operator->() const { return p; }
	bool operator!() const { return p == nullptr; }

	void Release()
	{
		T* tmp = p;
		if (tmp) {
			p = nullptr;
			tmp->Release();
		}
	}
	void Attach(T* p2)
	{
		if (p) p->Release();
		p = p2;
	}
	T* Detach()
	{
		T* tmp = p;
		p = nullptr;
		return tmp;
	}
	template <class Q>
	HRESULT QueryInterface(Q** pp) const { return p->QueryInterface(__uuidof(Q), (void**)pp); }
};
