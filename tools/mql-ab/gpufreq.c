// gpufreq [secs] [group subgroup] : P-state residency over a window from IOReport, no sudo. Default
// "GPU Stats"/"GPU Performance States"; CPUs: "CPU Stats" "CPU Core Performance States".
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);
int main(int argc, char **argv)
{
	CFStringRef g = CFStringCreateWithCString(NULL, argc > 3 ? argv[2] : "GPU Stats", kCFStringEncodingUTF8);
	CFStringRef sg = CFStringCreateWithCString(NULL, argc > 3 ? argv[3] : "GPU Performance States", kCFStringEncodingUTF8);
	CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(g, sg, 0, 0, 0);
	CFMutableDictionaryRef sub = NULL;
	IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, ch, &sub, 0, NULL);
	CFDictionaryRef a = IOReportCreateSamples(s, sub, NULL);
	sleep(argc > 1 ? atoi(argv[1]) : 5);
	CFDictionaryRef b = IOReportCreateSamples(s, sub, NULL);
	CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
	CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
	for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
		CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
		char name[128];
		CFStringGetCString(IOReportChannelGetChannelName(c), name, sizeof name, kCFStringEncodingUTF8);
		int n = IOReportStateGetCount(c);
		int64_t tot = 0;
		for (int k = 0; k < n; k++) tot += IOReportStateGetResidency(c, k);
		if (!tot) continue;
		printf("%s:", name);
		for (int k = 0; k < n; k++) {
			char st[64];
			CFStringGetCString(IOReportStateGetNameForIndex(c, k), st, sizeof st, kCFStringEncodingUTF8);
			int64_t r = IOReportStateGetResidency(c, k);
			if (getenv("ALL") || r * 100 >= tot) printf(" %s %.0f%%", st, 100.0 * r / tot);
		}
		printf("\n");
	}
	return 0;
}
