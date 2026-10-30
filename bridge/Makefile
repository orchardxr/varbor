# wineopenxr.dll (PE, llvm-mingw) + wineopenxr.so (universal x86_64 + arm64 Mach-O unixlib: Rosetta and FEX runners).
# The .so loads the host's OpenXR runtime (the WiVRn install's) at run time.
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
VK_INC     ?= /usr/local/include

PE_CC      := $(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang
PE_CFLAGS  := -O2 -g -Wall -Wno-unused-function -Isrc -I$(GEN) $(XR_INC) -I$(B)/vulkan/include
UNIX_CFLAGS := -mmacosx-version-min=13.0 -O2 -g -Wall -Isrc -I$(GEN) $(XR_INC) -I$(VK_INC)
UNIX_SRC    := src/wineopenxr_unix.c src/dxmt_unix.m $(GEN)/xr_thunks_unix.c

GENERATED  := $(GEN)/xr_thunks.h $(GEN)/xr_thunks_pe.c $(GEN)/xr_thunks_unix.c $(GEN)/xr_host_functions.h
HEADERS    := $(wildcard src/*.h) $(GENERATED)

all: $(OUT)/x86_64-windows/wineopenxr.dll $(OUT)/x86_64-windows/varborreg.dll $(OUT)/x86_64-unix/wineopenxr.so \
     $(OUT)/wineopenxr.json $(B)/tests/xr_time_test.exe $(B)/tests/xr_array_test.exe

$(GENERATED) &: make_openxr.py $(XR_XML)
	python3 make_openxr.py $(XR_XML) $(GEN)

$(OUT)/x86_64-windows/wineopenxr.dll: src/wineopenxr.c $(GEN)/xr_thunks_pe.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(PE_CC) $(PE_CFLAGS) -shared -o $@ src/wineopenxr.c $(GEN)/xr_thunks_pe.c -ldxgi -ldxguid -luuid
	python3 tools/mark-builtin.py $@

# Registration-only builtin: wineboot applies its WINE_REGISTRY script whenever it creates or updates a prefix (NotProton's
# templates included). The script is a placeholder VarboR fills per user at install (RunnerRegistration.swift).
$(GEN)/varborreg.rgs:
	@mkdir -p $(dir $@)
	python3 -c 'import sys; m = b"VARBOR-RGS-BEGIN"; e = b"VARBOR-RGS-END"; sys.stdout.buffer.write(m + b" " * (8192 - len(m) - len(e)) + e)' > $@

$(OUT)/x86_64-windows/varborreg.dll: src/varborreg.c src/varborreg.rc $(GEN)/varborreg.rgs
	@mkdir -p $(dir $@)
	$(LLVM_MINGW)/bin/x86_64-w64-mingw32-windres -I$(GEN) src/varborreg.rc -O coff -o $(GEN)/varborreg.res.o
	$(PE_CC) -O2 -shared -nostdlib -Wl,-e,DllMain -o $@ src/varborreg.c $(GEN)/varborreg.res.o
	python3 tools/mark-builtin.py $@

$(OUT)/x86_64-unix/wineopenxr.so: $(UNIX_SRC) $(HEADERS)
	@mkdir -p $(dir $@)
	clang -arch x86_64 -arch arm64 $(UNIX_CFLAGS) -fno-objc-arc -dynamiclib -o $@ $(UNIX_SRC) \
		-framework Foundation -framework Metal

$(OUT)/wineopenxr.json: wineopenxr.json
	cp $< $@

$(B)/tests/%.exe: tests/%.c
	@mkdir -p $(dir $@)
	$(PE_CC) -O1 -g -Wall $(XR_INC) -c -o $@.o $<
	$(PE_CC)++ -o $@ $@.o -L$(B)/openxr-sdk-win/src/loader -lopenxr_loader -ld3d11 -ldxguid -ladvapi32 -static

clean:
	rm -rf $(GEN) $(OUT) $(B)/tests

.PHONY: all clean
