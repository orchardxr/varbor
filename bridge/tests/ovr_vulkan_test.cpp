// Minimal OpenVR Vulkan scene app for M3 (docs/m3-opencomposite.md), the path Half-Life: Alyx takes with -vulkan:
// VkInstance/VkDevice with the compositor's required extensions, per-eye test pattern images submitted as
// VRVulkanTextureData_t in TRANSFER_SRC_OPTIMAL layout.
//   ovr_vulkan_test.exe [frames]
// Left eye: dark green, yellow square top-left. Right eye: purple, cyan square top-right. Both: white bar.
#include <vulkan/vulkan.h>
#include <openvr.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#define LOG(...) (printf("ovr_vk_test: " __VA_ARGS__), printf("\n"), fflush(stdout))
#define VKCHECK(x)                                              \
	do {                                                        \
		VkResult r_ = (x);                                      \
		if (r_ != VK_SUCCESS) {                                 \
			LOG("%s failed: %d (line %d)", #x, r_, __LINE__); \
			exit(1);                                            \
		}                                                       \
	} while (0)

static std::vector<std::string> split(const std::string& s)
{
	std::vector<std::string> out;
	std::istringstream in(s);
	std::string w;
	while (in >> w)
		out.push_back(w);
	return out;
}

static std::vector<uint32_t> pattern(uint32_t w, uint32_t h, bool right)
{
	std::vector<uint32_t> px(size_t(w) * h);
	const uint32_t bg = right ? 0xFF800060u : 0xFF006000u;
	const uint32_t mark = right ? 0xFFFFFF00u : 0xFF00FFFFu;
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++) {
			uint32_t c = bg;
			if (y > h * 9 / 20 && y < h * 11 / 20)
				c = 0xFFFFFFFFu;
			bool sy = y > h / 10 && y < h * 3 / 10;
			bool sx = right ? (x > w * 6 / 10 && x < w * 8 / 10) : (x > w * 2 / 10 && x < w * 4 / 10);
			if (sx && sy)
				c = mark;
			px[size_t(y) * w + x] = c;
		}
	return px;
}

static uint32_t mem_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	LOG("no memory type for bits %x flags %x", bits, want);
	exit(1);
}

int main(int argc, char** argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 300;
	vr::EVRInitError err = vr::VRInitError_None;
	vr::IVRSystem* sys = vr::VR_Init(&err, vr::VRApplication_Scene);
	if (!sys) {
		LOG("VR_Init failed: %d %s", err, vr::VR_GetVRInitErrorAsEnglishDescription(err));
		return 1;
	}
	uint32_t w = 0, h = 0;
	sys->GetRecommendedRenderTargetSize(&w, &h);
	vr::IVRCompositor* comp = vr::VRCompositor();

	char buf[4096] = {};
	comp->GetVulkanInstanceExtensionsRequired(buf, sizeof(buf));
	LOG("VR_Init ok: %ux%u; instance extensions: %s", w, h, buf);
	std::vector<std::string> iext = split(buf);
	std::vector<const char*> iextp;
	for (auto& s : iext)
		iextp.push_back(s.c_str());

	VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
	ai.pApplicationName = "ovr_vulkan_test";
	ai.apiVersion = VK_API_VERSION_1_1;
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
	ici.pApplicationInfo = &ai;
	ici.enabledExtensionCount = (uint32_t)iextp.size();
	ici.ppEnabledExtensionNames = iextp.data();
	VkInstance inst;
	VKCHECK(vkCreateInstance(&ici, nullptr, &inst));
	LOG("vkCreateInstance ok");

	uint64_t hmd_pd = 0;
	sys->GetOutputDevice(&hmd_pd, vr::TextureType_Vulkan, inst);
	uint32_t n = 0;
	vkEnumeratePhysicalDevices(inst, &n, nullptr);
	std::vector<VkPhysicalDevice> pds(n);
	vkEnumeratePhysicalDevices(inst, &n, pds.data());
	VkPhysicalDevice pd = hmd_pd ? (VkPhysicalDevice)hmd_pd : pds[0];
	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(pd, &props);
	LOG("GetOutputDevice -> %p (%s), %u physical devices, using '%s'", (void*)hmd_pd,
	    hmd_pd == (uint64_t)pds[0] ? "== device 0" : "not device 0", n, props.deviceName);

	memset(buf, 0, sizeof(buf));
	comp->GetVulkanDeviceExtensionsRequired(pd, buf, sizeof(buf));
	LOG("device extensions: %s", buf);
	std::vector<std::string> dext = split(buf);
	std::vector<const char*> dextp;
	for (auto& s : dext)
		dextp.push_back(s.c_str());

	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, nullptr);
	std::vector<VkQueueFamilyProperties> qf(n);
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, qf.data());
	uint32_t qfi = 0;
	while (qfi < n && !(qf[qfi].queueFlags & VK_QUEUE_GRAPHICS_BIT))
		qfi++;
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
	qci.queueFamilyIndex = qfi;
	qci.queueCount = 1;
	qci.pQueuePriorities = &prio;
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
	dci.queueCreateInfoCount = 1;
	dci.pQueueCreateInfos = &qci;
	dci.enabledExtensionCount = (uint32_t)dextp.size();
	dci.ppEnabledExtensionNames = dextp.data();
	VkDevice dev;
	VKCHECK(vkCreateDevice(pd, &dci, nullptr, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, qfi, 0, &queue);

	const VkDeviceSize size = VkDeviceSize(w) * h * 4;
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
	bci.size = size * 2;
	bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
	VkBuffer staging;
	VKCHECK(vkCreateBuffer(dev, &bci, nullptr, &staging));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, staging, &mr);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = mem_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory smem;
	VKCHECK(vkAllocateMemory(dev, &mai, nullptr, &smem));
	VKCHECK(vkBindBufferMemory(dev, staging, smem, 0));
	void* map;
	VKCHECK(vkMapMemory(dev, smem, 0, size * 2, 0, &map));
	for (int e = 0; e < 2; e++) {
		auto px = pattern(w, h, e == 1);
		memcpy((char*)map + size * e, px.data(), size);
	}
	vkUnmapMemory(dev, smem);

	VkImage img[2];
	VkDeviceMemory imem[2];
	for (int e = 0; e < 2; e++) {
		VkImageCreateInfo ic = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
		ic.imageType = VK_IMAGE_TYPE_2D;
		ic.format = VK_FORMAT_R8G8B8A8_UNORM;
		ic.extent = { w, h, 1 };
		ic.mipLevels = 1;
		ic.arrayLayers = 1;
		ic.samples = VK_SAMPLE_COUNT_1_BIT;
		ic.tiling = VK_IMAGE_TILING_OPTIMAL;
		ic.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT
		    | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
		VKCHECK(vkCreateImage(dev, &ic, nullptr, &img[e]));
		vkGetImageMemoryRequirements(dev, img[e], &mr);
		mai.allocationSize = mr.size;
		mai.memoryTypeIndex = mem_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
		VKCHECK(vkAllocateMemory(dev, &mai, nullptr, &imem[e]));
		VKCHECK(vkBindImageMemory(dev, img[e], imem[e], 0));
	}

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	cpci.queueFamilyIndex = qfi;
	VkCommandPool pool;
	VKCHECK(vkCreateCommandPool(dev, &cpci, nullptr, &pool));
	VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
	cbai.commandPool = pool;
	cbai.commandBufferCount = 1;
	VkCommandBuffer cb;
	VKCHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	VKCHECK(vkBeginCommandBuffer(cb, &cbbi));
	for (int e = 0; e < 2; e++) {
		VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
		b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		b.image = img[e];
		b.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
		b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
		    nullptr, 1, &b);
		VkBufferImageCopy r = {};
		r.bufferOffset = size * e;
		r.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
		r.imageExtent = { w, h, 1 };
		vkCmdCopyBufferToImage(cb, staging, img[e], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &r);
		b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
		b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
		vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
		    nullptr, 1, &b);
	}
	VKCHECK(vkEndCommandBuffer(cb));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
	si.commandBufferCount = 1;
	si.pCommandBuffers = &cb;
	VKCHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	VKCHECK(vkQueueWaitIdle(queue));
	LOG("images ready");

	int submit_errors = 0;
	for (int f = 0; f < frames; f++) {
		vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
		vr::EVRCompositorError ce = comp->WaitGetPoses(poses, vr::k_unMaxTrackedDeviceCount, nullptr, 0);
		if (ce != vr::VRCompositorError_None && submit_errors++ < 5)
			LOG("frame %d WaitGetPoses -> %d", f, ce);
		vr::VREvent_t ev;
		while (sys->PollNextEvent(&ev, sizeof(ev))) {
		}
		for (int e = 0; e < 2; e++) {
			vr::VRVulkanTextureData_t vk = {};
			vk.m_nImage = (uint64_t)img[e];
			vk.m_pDevice = dev;
			vk.m_pPhysicalDevice = pd;
			vk.m_pInstance = inst;
			vk.m_pQueue = queue;
			vk.m_nQueueFamilyIndex = qfi;
			vk.m_nWidth = w;
			vk.m_nHeight = h;
			vk.m_nFormat = VK_FORMAT_R8G8B8A8_UNORM;
			vk.m_nSampleCount = 1;
			vr::Texture_t t = { &vk, vr::TextureType_Vulkan, vr::ColorSpace_Gamma };
			ce = comp->Submit(e == 0 ? vr::Eye_Left : vr::Eye_Right, &t);
			if (ce != vr::VRCompositorError_None && submit_errors++ < 5)
				LOG("frame %d Submit(eye %d) -> %d", f, e, ce);
		}
		comp->PostPresentHandoff();
		if (f == 0 || f == frames - 1)
			LOG("frame %d HMD pose valid %d", f, poses[0].bPoseIsValid);
	}
	LOG("done: %d frames, %d errors", frames, submit_errors);
	vr::VR_Shutdown();
	vkDeviceWaitIdle(dev);
	vkDestroyCommandPool(dev, pool, nullptr);
	for (int e = 0; e < 2; e++) {
		vkDestroyImage(dev, img[e], nullptr);
		vkFreeMemory(dev, imem[e], nullptr);
	}
	vkDestroyBuffer(dev, staging, nullptr);
	vkFreeMemory(dev, smem, nullptr);
	vkDestroyDevice(dev, nullptr);
	vkDestroyInstance(inst, nullptr);
	LOG("VR_Shutdown ok");
	return 0;
}
