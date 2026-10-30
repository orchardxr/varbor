# vrclient_x64.dll (PE, llvm-mingw) + vrclient_x64.so (universal x86_64 + arm64 Mach-O unixlib: Rosetta and FEX
# runners), Proton's vrclient built outside a Wine tree. Normally run by scripts/build-bridge.sh vrclient.
ROOT_DIR   := $(abspath ..)
B          ?= $(ROOT_DIR)/build/vrclient
LLVM_MINGW ?= $(error LLVM_MINGW is not set: run scripts/build-bridge.sh vrclient, or pass LLVM_MINGW=<llvm-mingw root>)
# Wine's headers (scripts/build-bridge.sh fetches them): the unix side is built like a Wine unixlib, the PE side takes
# only what mingw lacks (wine/*.h, cxx.h's helpers) from there
WINE_SRC   ?= $(B)/wine
WINE_INC   := $(WINE_SRC)/include
OUT        := $(B)/root
OBJ        := $(B)/obj
VK_INC     ?= /usr/local/include

PE_CC      = $(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang
PE_CXX     = $(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang++
PE_FLAGS   := -O2 -g -DMACVR -DGNUC -D__WINESRC__ -D__WINE_PE_BUILD -include src/pe/pe_compat.h -Isrc/pe -Iproton -Isrc \
              -isystem $(VK_INC) -idirafter $(WINE_INC) -Wno-unused-function -Wno-ignored-attributes -Wno-incompatible-pointer-types \
              -Wno-int-conversion -Wno-macro-redefined -fno-strict-aliasing
UNIX_ARCHS := -arch x86_64 -arch arm64
UNIX_FLAGS := $(UNIX_ARCHS) -mmacosx-version-min=13.0 -O2 -g -DMACVR -DWINE_UNIX_LIB -D__WINESRC__ -include wchar.h -include string.h -Isrc -Iproton -I$(WINE_INC) \
              -fPIC -Wno-ignored-attributes -Wno-unused-function -Wno-deprecated-declarations \
              -Wno-macro-redefined -Wno-invalid-offsetof -Wno-format -Wno-pragma-pack -Wno-comment

PROTON_SRCS := $(notdir $(wildcard proton/*.c proton/*.cpp))
PE_SRCS    := $(filter %.c,$(PROTON_SRCS))
UNIX_SRCS  := $(filter %.cpp,$(PROTON_SRCS))
PE_OBJS    := $(addprefix $(OBJ)/pe/,$(PE_SRCS:.c=.o)) $(OBJ)/pe/winecrt0_debug.o $(OBJ)/pe/winecrt0_unix_lib.o $(OBJ)/pe/dxmt_pe.o
UNIX_OBJS  := $(addprefix $(OBJ)/unix/,$(UNIX_SRCS:.cpp=.o)) $(OBJ)/unix/dxmt_unix.o $(OBJ)/unix/macos_unix.o
HEADERS    := $(wildcard proton/*.h src/*.h src/pe/*.h)
OVR        := $(ROOT_DIR)/third_party/openvr

all: $(OUT)/x86_64-windows/vrclient_x64.dll $(OUT)/x86_64-unix/vrclient_x64.so $(B)/tests/ovr_d3d11_render.exe \
     $(B)/tests/openvr_api.dll

# Against Valve's openvr_api.dll, as games ship it
$(B)/tests/ovr_d3d11_render.exe: $(ROOT_DIR)/tests/openvr-d3d11/ovr_d3d11_render.cpp
	@mkdir -p $(dir $@)
	$(PE_CXX) -std=c++17 -O1 -g -Wall -I$(OVR)/headers -o $@ $< $(OVR)/lib/win64/openvr_api.lib -ld3d11 -static

$(B)/tests/openvr_api.dll: $(OVR)/bin/win64/openvr_api.dll
	@mkdir -p $(dir $@)
	cp $< $@

$(OBJ)/pe/%.o: proton/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(PE_CC) $(PE_FLAGS) -c -o $@ $<

$(OBJ)/pe/%.o: src/%.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(PE_CC) $(PE_FLAGS) -c -o $@ $<

$(OBJ)/unix/%.o: proton/%.cpp $(HEADERS)
	@mkdir -p $(dir $@)
	clang++ -std=c++17 $(UNIX_FLAGS) -c -o $@ $<

$(OBJ)/unix/%.o: src/%.mm $(HEADERS)
	@mkdir -p $(dir $@)
	clang++ -std=c++17 $(UNIX_FLAGS) -fno-objc-arc -c -o $@ $<

$(OBJ)/unix/%.o: src/%.cpp $(HEADERS)
	@mkdir -p $(dir $@)
	clang++ -std=c++17 $(UNIX_FLAGS) -c -o $@ $<

# What winegcc links from libwinecrt0.a: the debug channel helpers and the unixlib dispatcher. Built from Wine's own
# sources with Wine's headers only.
$(OBJ)/pe/winecrt0_%.o: $(WINE_SRC)/dlls/winecrt0/%.c
	@mkdir -p $(dir $@)
	$(PE_CC) -O2 -g -nostdlibinc -I$(WINE_INC) -I$(WINE_INC)/msvcrt -D__WINESRC__ -D__WINE_PE_BUILD -D_UCRT -c -o $@ $<

$(OUT)/x86_64-windows/vrclient_x64.dll: $(PE_OBJS) proton/vrclient_x64.spec src/vrclient_x64.def 
	@mkdir -p $(dir $@)
	$(PE_CC) -shared -o $@ $(PE_OBJS) src/vrclient_x64.def  -ladvapi32 -lntdll -ldxguid -luuid \
		-Wl,--pdb=
	python3 ../bridge/tools/mark-builtin.py $@

# ntdll.so's exports resolve at load time from the one Wine has loaded (no install-name dependency: under FEX the .so
# sits in the runner's x86_64-windows dir, away from aarch64-unix/ntdll.so).
$(OUT)/x86_64-unix/vrclient_x64.so: $(UNIX_OBJS)
	@mkdir -p $(dir $@)
	clang++ $(UNIX_ARCHS) -mmacosx-version-min=13.0 -dynamiclib -o $@ $(UNIX_OBJS) -Wl,-undefined,dynamic_lookup \
		-framework Foundation -framework Metal

clean:
	rm -rf $(OBJ) $(OUT)

.PHONY: all clean
