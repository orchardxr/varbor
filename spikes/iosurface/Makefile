# Builds the IOSurface/MoltenVK spike. Requires glslc and the LunarG SDK in /usr/local.
VK_PREFIX ?= /usr/local
BUILD     ?= build
CC        := clang
CFLAGS    := -O2 -g -Wall -Wno-unused-function -Wno-four-char-constants -I$(VK_PREFIX)/include -I$(BUILD)
LDFLAGS   := -L$(VK_PREFIX)/lib -lvulkan -Wl,-rpath,$(VK_PREFIX)/lib \
             -framework Foundation -framework Metal -framework IOSurface -framework CoreVideo -framework CoreMedia -framework VideoToolbox
SHADERS   := $(BUILD)/store.spv.inc $(BUILD)/fetch.spv.inc
COMMON    := src/vkutil.m src/vkutil.h

all: $(BUILD)/fmt_test $(BUILD)/fmt_test_x86_64 $(BUILD)/bs_probe $(BUILD)/xproc_server $(BUILD)/xproc_client $(BUILD)/xproc_client_x86_64

$(BUILD)/%.spv.inc: src/shaders/%.comp | $(BUILD)
	glslc -fshader-stage=compute --target-env=vulkan1.1 -mfmt=num -o $@ $<

$(BUILD):
	mkdir -p $@

$(BUILD)/fmt_test: src/fmt_test.m $(COMMON) $(SHADERS)
	$(CC) -arch arm64 $(CFLAGS) -o $@ src/fmt_test.m src/vkutil.m $(LDFLAGS)

$(BUILD)/fmt_test_x86_64: src/fmt_test.m $(COMMON) $(SHADERS)
	$(CC) -arch x86_64 $(CFLAGS) -o $@ src/fmt_test.m src/vkutil.m $(LDFLAGS)

$(BUILD)/bs_probe: src/bs_probe.c | $(BUILD)
	$(CC) -arch arm64 $(CFLAGS) -Wno-deprecated-declarations -o $@ $<

$(BUILD)/xproc_server: src/xproc_server.m src/xproc.h $(COMMON) $(SHADERS)
	$(CC) -arch arm64 $(CFLAGS) -Wno-deprecated-declarations -o $@ src/xproc_server.m src/vkutil.m $(LDFLAGS)

$(BUILD)/xproc_client: src/xproc_client.m src/xproc.h $(COMMON) $(SHADERS)
	$(CC) -arch arm64 $(CFLAGS) -o $@ src/xproc_client.m src/vkutil.m $(LDFLAGS)

$(BUILD)/xproc_client_x86_64: src/xproc_client.m src/xproc.h $(COMMON) $(SHADERS)
	$(CC) -arch x86_64 $(CFLAGS) -o $@ src/xproc_client.m src/vkutil.m $(LDFLAGS)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
