# Bridge feasibility spikes. See RESULTS.md.
# Marks the PE as a Wine builtin, like `winebuild --builtin` (an x86_64 winebuild can hang in Rosetta).
WINEBUILD ?= ../../bridge/tools/mark-builtin.py
VK_PREFIX ?= /usr/local
MINGW_CXX ?= x86_64-w64-mingw32-g++
MINGW_CC  ?= x86_64-w64-mingw32-gcc
# Generated OpenXR headers (openxr_loader_negotiation.h); any configured openxr-sdk build has them.
XR_INCLUDE ?= ../../build/openxr-sdk/include
B := build
ROOT := $(B)/root

all: $(B)/handle_probe_arm64 $(B)/handle_probe_x86_64 $(B)/metal_texture_import_arm64 $(B)/dxmt_import_test.exe \
     $(ROOT)/x86_64-windows/vkprobe.dll $(ROOT)/x86_64-unix/vkprobe.so $(B)/dxvk_interop_test.exe $(B)/xr_probe_test.exe

$(B)/metal_texture_import_%: src/metal_texture_import.m
	@mkdir -p $(B)
	clang -arch $* -O1 -g -fobjc-arc -Wall -I$(VK_PREFIX)/include -o $@ $< -framework Foundation -framework Metal

$(B)/handle_probe_%: src/handle_probe.m
	@mkdir -p $(B)
	clang -arch $* -O1 -g -fobjc-arc -Wall -Wno-four-char-constants -o $@ $< -framework Foundation -framework Metal -framework IOSurface

$(B)/dxmt_import_test.exe: src/dxmt_import_test.cpp
	$(MINGW_CXX) -std=c++17 -O1 -g -o $@ $< -ld3d11 -ldxgi -ldxguid -static

$(ROOT)/x86_64-windows/vkprobe.dll: vkprobe/vkprobe_pe.c vkprobe/probe.h
	@mkdir -p $(dir $@)
	$(MINGW_CC) -O1 -shared -o $@ $< -Wl,--image-base,0x6c000000
	$(WINEBUILD) $@

$(ROOT)/x86_64-unix/vkprobe.so: vkprobe/vkprobe_unix.m vkprobe/xrprobe_unix.m src/metal_texture_import.m vkprobe/probe.h
	@mkdir -p $(dir $@)
	clang -arch x86_64 -O1 -g -fobjc-arc -Wall -Wno-four-char-constants -dynamiclib -I$(VK_PREFIX)/include -I$(XR_INCLUDE) \
	  -DMTI_NO_MAIN -o $@ vkprobe/vkprobe_unix.m vkprobe/xrprobe_unix.m src/metal_texture_import.m -framework Foundation -framework Metal -framework IOSurface

$(B)/dxvk_interop_test.exe: vkprobe/dxvk_interop_test.cpp vkprobe/probe.h
	$(MINGW_CXX) -std=c++17 -O1 -g -o $@ $< -ld3d11 -ldxguid -static

$(B)/xr_probe_test.exe: vkprobe/xr_probe_test.cpp vkprobe/probe.h
	$(MINGW_CXX) -std=c++17 -O1 -g -o $@ $< -ld3d11 -ldxguid -static

clean:
	rm -rf $(B)

.PHONY: all clean
