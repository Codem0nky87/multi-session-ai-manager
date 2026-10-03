#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOTypes.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
extern CFStringRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);

int main() {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return 1;

    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){0xFF00});
    CFNumberRef usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(int){5});
    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[2] = { page, usage };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    IOHIDEventSystemClientSetMatching(client, match);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    
    if (services) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            if (name) {
                IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0); // kIOHIDEventTypeTemperature = 15
                if (event) {
                    double temp = IOHIDEventGetFloatValue(event, 15 << 16);
                    char nameBuf[256];
                    CFStringGetCString(name, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
                    // Print PMU tdie or similar
                    if (strstr(nameBuf, "PMU tdie") || strstr(nameBuf, "eACC MTR Temp") || strstr(nameBuf, "pACC MTR Temp")) {
                        printf("%s: %.2f\n", nameBuf, temp);
                    }
                    CFRelease(event);
                }
                CFRelease(name);
            }
        }
        CFRelease(services);
    }
    
    CFRelease(match);
    CFRelease(page);
    CFRelease(usage);
    CFRelease(client);
    return 0;
}
