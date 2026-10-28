# Source me: common environment for running Monado / hello_xr on macOS.
# Homebrew MoltenVK 1.4.2 only. Do NOT set DYLD_LIBRARY_PATH=/usr/local/lib: dyld would then
# resolve libMoltenVK.dylib by leaf name to the older SDK copy (MoltenVK 1.2.11) in /usr/local/lib.
export VK_DRIVER_FILES=/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json
export VK_LAYER_PATH=/usr/local/share/vulkan/explicit_layer.d
