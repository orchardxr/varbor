// Test tone for the WiVRn CoreAudio backend (docs/wivrn.md, Audio).
//   audio_tone [seconds] [--device <name substring>] [--loopback <name substring>] [--freq <hz>] [--amp <0..1>]
// Plays a sine on the default output device (or --device). With --loopback, also records that device's input
// (e.g. a virtual device that loops its output back, played to with --device) and prints its RMS once a second, so
// a muting process tap shows up as the loopback going silent.
// Built by scripts/build-wivrn.sh into build/tests/audio_tone.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

static double freq = 440, amp = 0.1, phase = 0;
static std::atomic<double> loop_sumsq{0};
static std::atomic<uint64_t> loop_n{0};

static CFStringRef find_device(const char * substr, bool input)
{
	AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
	UInt32 sz = 0;
	AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &sz);
	std::vector<AudioObjectID> ids(sz / sizeof(AudioObjectID));
	AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, ids.data());
	for (auto id: ids)
	{
		CFStringRef name = nullptr;
		UInt32 s = sizeof(name);
		AudioObjectPropertyAddress n{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
		if (AudioObjectGetPropertyData(id, &n, 0, nullptr, &s, &name) or not name)
			continue;
		AudioObjectPropertyAddress c{kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
		UInt32 cs = 0;
		AudioObjectGetPropertyDataSize(id, &c, 0, nullptr, &cs);
		if ([(__bridge NSString *)name containsString:@(substr)] and cs > sizeof(UInt32))
		{
			CFStringRef uid = nullptr;
			s = sizeof(uid);
			AudioObjectPropertyAddress u{kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
			AudioObjectGetPropertyData(id, &u, 0, nullptr, &s, &uid);
			fprintf(stderr, "%s device: %s\n", input ? "loopback" : "output", [(__bridge NSString *)name UTF8String]);
			CFRelease(name);
			return uid;
		}
		CFRelease(name);
	}
	fprintf(stderr, "no %s device matching '%s'\n", input ? "input" : "output", substr);
	exit(1);
}

static void out_cb(void *, AudioQueueRef q, AudioQueueBufferRef b)
{
	auto * f = (float *)b->mAudioData;
	size_t frames = b->mAudioDataBytesCapacity / 8;
	for (size_t i = 0; i < frames; ++i)
	{
		float v = amp * sin(phase);
		phase += 2 * M_PI * freq / 48000;
		f[2 * i] = f[2 * i + 1] = v;
	}
	b->mAudioDataByteSize = frames * 8;
	AudioQueueEnqueueBuffer(q, b, 0, nullptr);
}

static void in_cb(void *, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp *, UInt32, const AudioStreamPacketDescription *)
{
	auto * f = (const float *)b->mAudioData;
	size_t n = b->mAudioDataByteSize / 4;
	double s = 0;
	for (size_t i = 0; i < n; ++i)
		s += f[i] * f[i];
	loop_sumsq = loop_sumsq + s;
	loop_n += n;
	AudioQueueEnqueueBuffer(q, b, 0, nullptr);
}

int main(int argc, char ** argv)
{
	@autoreleasepool
	{
		int secs = 30;
		const char *dev = nullptr, *loop = nullptr;
		for (int i = 1; i < argc; ++i)
		{
			if (!strcmp(argv[i], "--device") and i + 1 < argc)
				dev = argv[++i];
			else if (!strcmp(argv[i], "--loopback") and i + 1 < argc)
				loop = argv[++i];
			else if (!strcmp(argv[i], "--freq") and i + 1 < argc)
				freq = atof(argv[++i]);
			else if (!strcmp(argv[i], "--amp") and i + 1 < argc)
				amp = atof(argv[++i]);
			else
				secs = atoi(argv[i]);
		}
		AudioStreamBasicDescription fmt{
		        .mSampleRate = 48000,
		        .mFormatID = kAudioFormatLinearPCM,
		        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		        .mBytesPerPacket = 8,
		        .mFramesPerPacket = 1,
		        .mBytesPerFrame = 8,
		        .mChannelsPerFrame = 2,
		        .mBitsPerChannel = 32,
		};
		AudioQueueRef out = nullptr, in = nullptr;
		AudioQueueNewOutput(&fmt, out_cb, nullptr, nullptr, nullptr, 0, &out);
		if (dev)
		{
			CFStringRef uid = find_device(dev, false);
			AudioQueueSetProperty(out, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
		}
		for (int i = 0; i < 3; ++i)
		{
			AudioQueueBufferRef b;
			AudioQueueAllocateBuffer(out, 480 * 8, &b);
			out_cb(nullptr, out, b);
		}
		if (loop)
		{
			AudioQueueNewInput(&fmt, in_cb, nullptr, nullptr, nullptr, 0, &in);
			CFStringRef uid = find_device(loop, true);
			AudioQueueSetProperty(in, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
			for (int i = 0; i < 4; ++i)
			{
				AudioQueueBufferRef b;
				AudioQueueAllocateBuffer(in, 4800 * 8, &b);
				AudioQueueEnqueueBuffer(in, b, 0, nullptr);
			}
			AudioQueueStart(in, nullptr);
		}
		AudioQueueStart(out, nullptr);
		printf("pid %d playing %.0f Hz amp %.2f for %d s\n", getpid(), freq, amp, secs);
		fflush(stdout);
		for (int t = 0; t < secs; ++t)
		{
			double s0 = loop_sumsq;
			uint64_t n0 = loop_n;
			sleep(1);
			if (loop)
			{
				uint64_t n = loop_n - n0;
				printf("t=%d loopback rms %.4f\n", t, n ? sqrt((loop_sumsq - s0) / n) : 0.0);
				fflush(stdout);
			}
		}
		AudioQueueStop(out, true);
		if (in)
			AudioQueueStop(in, true);
	}
}
