#include "app/GpuStats.h"
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

namespace choreo {
int gpuUtilizationPercent() {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return -1;
    int result = -1;
    for (io_object_t s; result < 0 && (s = IOIteratorNext(it));) {
        CFTypeRef stats = IORegistryEntryCreateCFProperty(s, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
            auto v = static_cast<CFNumberRef>(CFDictionaryGetValue(static_cast<CFDictionaryRef>(stats), CFSTR("Device Utilization %")));
            int pct = 0;
            if (v && CFNumberGetValue(v, kCFNumberIntType, &pct)) result = pct;
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return result;
}
} // namespace choreo
#else
namespace choreo { int gpuUtilizationPercent() { return -1; } }
#endif
