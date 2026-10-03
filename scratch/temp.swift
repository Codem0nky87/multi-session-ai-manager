import Foundation

typealias IOHIDEventSystemClientCreateType = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
typealias IOHIDEventSystemClientSetMatchingType = @convention(c) (UnsafeMutableRawPointer, CFDictionary?) -> Int32
typealias IOHIDEventSystemClientCopyServicesType = @convention(c) (UnsafeMutableRawPointer) -> CFArray?
typealias IOHIDServiceClientCopyPropertyType = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFString>?
typealias IOHIDServiceClientCopyEventType = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
typealias IOHIDEventGetFloatValueType = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
if let handle = handle {
    let sym1 = dlsym(handle, "IOHIDEventSystemClientCreate")
    let sym2 = dlsym(handle, "IOHIDEventSystemClientSetMatching")
    let sym3 = dlsym(handle, "IOHIDEventSystemClientCopyServices")
    let sym4 = dlsym(handle, "IOHIDServiceClientCopyProperty")
    let sym5 = dlsym(handle, "IOHIDServiceClientCopyEvent")
    let sym6 = dlsym(handle, "IOHIDEventGetFloatValue")
    
    if let sym1 = sym1, let sym2 = sym2, let sym3 = sym3, let sym4 = sym4, let sym5 = sym5, let sym6 = sym6 {
        let IOHIDEventSystemClientCreate = unsafeBitCast(sym1, to: IOHIDEventSystemClientCreateType.self)
        let IOHIDEventSystemClientSetMatching = unsafeBitCast(sym2, to: IOHIDEventSystemClientSetMatchingType.self)
        let IOHIDEventSystemClientCopyServices = unsafeBitCast(sym3, to: IOHIDEventSystemClientCopyServicesType.self)
        let IOHIDServiceClientCopyProperty = unsafeBitCast(sym4, to: IOHIDServiceClientCopyPropertyType.self)
        let IOHIDServiceClientCopyEvent = unsafeBitCast(sym5, to: IOHIDServiceClientCopyEventType.self)
        let IOHIDEventGetFloatValue = unsafeBitCast(sym6, to: IOHIDEventGetFloatValueType.self)
        
        if let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) {
            _ = IOHIDEventSystemClientSetMatching(client, nil)
            if let services = IOHIDEventSystemClientCopyServices(client) as? [UnsafeMutableRawPointer] {
                print("Found \(services.count) services")
                for service in services {
                    if let prop = IOHIDServiceClientCopyProperty(service, "Product" as CFString) {
                        let name = prop.takeRetainedValue() as String
                        if let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) {
                            let temp = IOHIDEventGetFloatValue(event, 15 << 16)
                            print("\(name): \(temp)")
                        }
                    }
                }
            } else {
                print("No services found.")
            }
        }
    }
}
