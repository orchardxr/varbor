# wineopenxr.dll (PE, llvm-mingw) + wineopenxr.so (universal x86_64 + arm64 Mach-O unixlib: Rosetta and FEX runners) and
# a universal IPC client.
# Normally run by scripts/build-bridge.sh.
ROOT_DIR   := $(abspath ..)
B          ?= $(ROOT_DIR)/build/bridge
# llvm-mingw root (x86_64 ucrt); scripts/build-bridge.sh detects it
LLVM_MINGW ?= $(error LLVM_MINGW is not set: run scripts/build-bridge.sh bridge, or pass LLVM_MINGW=<llvm-mingw root>)
XR_XML     ?= $(ROOT_DIR)/third_party/openxr-sdk/specification/registry/xr.xml
# Generated OpenXR headers come from the openxr-sdk-win build.
XR_INC     := -I$(B)/openxr-sdk-win/include -I$(ROOT_DIR)/third_party/openxr-sdk/include
GEN        := $(B)/gen
OUT        := $(B)/root
# IPC clients from the server's WiVRn tree (scripts/build-wivrn.sh --client-x86_64 and --client-arm64), joined with lipo;
# both slices must carry the same ipc-stamp
MONADO     ?= $(ROOT_DIR)/build/wivrn-client-x86_64/client/libopenxr_monado.dylib
MONADO_ARM64 ?= $(ROOT_DIR)/build/wivrn-client-arm64/client/libopenxr_monado.dylib

PE_CC      := $(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang
PE_CFLAGS  := -O2 -g -Wall -Wno-unused-function -Isrc -I$(GEN) $(XR_INC) -I$(B)/vulkan/include
UNIX_CFLAGS := -mmacosx-version-min=13.0 -O2 -g -Wall -Isrc -I$(GEN) $(XR_INC) -I/usr/local/include
UNIX_SRC    := src/wineopenxr_unix.c src/dxmt_unix.m $(GEN)/xr_thunks_unix.c

GENERATED  := $(GEN)/xr_thunks.h $(GEN)/xr_thunks_pe.c $(GEN)/xr_thunks_unix.c $(GEN)/xr_host_functions.h
HEADERS    := $(wildcard src/*.h) $(GENERATED)

all: $(OUT)/x86_64-windows/wineopenxr.dll $(OUT)/x86_64-windows/macvrreg.dll $(OUT)/x86_64-unix/wineopenxr.so $(OUT)/x86_64-unix/libopenxr_monado.dylib \
     $(OUT)/x86_64-unix/ipc-stamp \
     $(OUT)/wineopenxr.json $(B)/tests/xr_time_test.exe $(B)/tests/xr_array_test.exe

$(GENERATED) &: make_openxr.py $(XR_XML)
	python3 make_openxr.py $(XR_XML) $(GEN)

$(OUT)/x86_64-windows/wineopenxr.dll: src/wineopenxr.c $(GEN)/xr_thunks_pe.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(PE_CC) $(PE_CFLAGS) -shared -o $@ src/wineopenxr.c $(GEN)/xr_thunks_pe.c -ldxgi -ldxguid -luuid
	python3 tools/mark-builtin.py $@

# Registration-only builtin: wineboot applies its WINE_REGISTRY script whenever it creates or updates a prefix (NotProton's
# templates included). The script is a placeholder MacVR fills per user at install (RunnerRegistration.swift).
$(GEN)/macvrreg.rgs:
	@mkdir -p $(dir $@)
	python3 -c 'import sys; m = b"MACVR-RGS-BEGIN"; e = b"MACVR-RGS-END"; sys.stdout.buffer.write(m + b" " * (8192 - len(m) - len(e)) + e)' > $@

$(OUT)/x86_64-windows/macvrreg.dll: src/macvrreg.c src/macvrreg.rc $(GEN)/macvrreg.rgs
	@mkdir -p $(dir $@)
	$(LLVM_MINGW)/bin/x86_64-w64-mingw32-windres -I$(GEN) src/macvrreg.rc -O coff -o $(GEN)/macvrreg.res.o
	$(PE_CC) -O2 -shared -nostdlib -Wl,-e,DllMain -o $@ src/macvrreg.c $(GEN)/macvrreg.res.o
	python3 tools/mark-builtin.py $@

$(OUT)/x86_64-unix/wineopenxr.so: $(UNIX_SRC) $(HEADERS)
	@mkdir -p $(dir $@)
	clang -arch x86_64 -arch arm64 $(UNIX_CFLAGS) -fno-objc-arc -dynamiclib -o $@ $(UNIX_SRC) \
		-framework Foundation -framework Metal

$(OUT)/x86_64-unix/libopenxr_monado.dylib: $(MONADO) $(MONADO_ARM64)
	@mkdir -p $(dir $@)
	lipo -create -output $@ $(MONADO) $(MONADO_ARM64)

$(OUT)/x86_64-unix/ipc-stamp: $(MONADO) $(MONADO_ARM64)
	@mkdir -p $(dir $@)
	cmp $(dir $(MONADO))ipc-stamp $(dir $(MONADO_ARM64))ipc-stamp || \
		{ echo "ipc-stamps of the x86_64 and arm64 clients differ: rebuild both (build-wivrn.sh --client-*)"; exit 1; }
	cp $(dir $(MONADO))ipc-stamp $@

$(OUT)/wineopenxr.json: wineopenxr.json
	cp $< $@

$(B)/tests/%.exe: tests/%.c
	@mkdir -p $(dir $@)
	$(PE_CC) -O1 -g -Wall $(XR_INC) -c -o $@.o $<
	$(PE_CC)++ -o $@ $@.o -L$(B)/openxr-sdk-win/src/loader -lopenxr_loader -ld3d11 -ldxguid -ladvapi32 -static

clean:
	rm -rf $(GEN) $(OUT) $(B)/tests

.PHONY: all clean
