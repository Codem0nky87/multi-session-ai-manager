import Foundation

typealias IOServiceMatchingCallback = @convention(c) (UnsafePointer<CChar>) -> CFDictionary
typealias IOServiceGetMatchingServiceCallback = @convention(c) (mach_port_t, CFDictionary) -> mach_port_t
typealias IOServiceOpenCallback = @convention(c) (mach_port_t, mach_port_t, UInt32, UnsafeMutablePointer<mach_port_t>) -> Int32
typealias IOConnectCallStructMethodCallback = @convention(c) (mach_port_t, UInt32, UnsafeRawPointer, Int, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> Int32
typealias IOServiceCloseCallback = @convention(c) (mach_port_t) -> Int32
typealias IOObjectReleaseCallback = @convention(c) (mach_port_t) -> Int32

let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
let IOServiceMatching = unsafeBitCast(dlsym(handle, "IOServiceMatching"), to: IOServiceMatchingCallback.self)
let IOServiceGetMatchingService = unsafeBitCast(dlsym(handle, "IOServiceGetMatchingService"), to: IOServiceGetMatchingServiceCallback.self)
let IOServiceOpen = unsafeBitCast(dlsym(handle, "IOServiceOpen"), to: IOServiceOpenCallback.self)
let IOConnectCallStructMethod = unsafeBitCast(dlsym(handle, "IOConnectCallStructMethod"), to: IOConnectCallStructMethodCallback.self)
let IOServiceClose = unsafeBitCast(dlsym(handle, "IOServiceClose"), to: IOServiceCloseCallback.self)
let IOObjectRelease = unsafeBitCast(dlsym(handle, "IOObjectRelease"), to: IOObjectReleaseCallback.self)

struct SMCVersion {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

func fourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for char in str.utf8 {
        result = (result << 8) + UInt32(char)
    }
    return result
}

let kIOMasterPortDefault: mach_port_t = 0
let matchDict = IOServiceMatching("AppleSMC")
let service = IOServiceGetMatchingService(kIOMasterPortDefault, matchDict)
if service != 0 {
    var conn: mach_port_t = 0
    if IOServiceOpen(service, mach_task_self_, 0, &conn) == 0 {
        var inputStruct = SMCParamStruct()
        inputStruct.key = fourCharCode("Tp09")
        inputStruct.data8 = 9 // kSMCReadKeyInfo
        var outputStruct = SMCParamStruct()
        var outSize: Int = MemoryLayout<SMCParamStruct>.size
        
        // Call read key info
        let kSMCHandleYPCEvent = 2
        var status = IOConnectCallStructMethod(conn, UInt32(kSMCHandleYPCEvent), &inputStruct, MemoryLayout<SMCParamStruct>.size, &outputStruct, &outSize)
        
        if status == 0 {
            inputStruct.keyInfo.dataSize = outputStruct.keyInfo.dataSize
            inputStruct.data8 = 5 // kSMCReadValue
            
            status = IOConnectCallStructMethod(conn, UInt32(kSMCHandleYPCEvent), &inputStruct, MemoryLayout<SMCParamStruct>.size, &outputStruct, &outSize)
            
            if status == 0 {
                // Parse sp78 or similar
                let bytes = outputStruct.bytes
                let val = (Double(bytes.0) * 256.0 + Double(bytes.1)) / 256.0
                print("Tp09 Temp: \(val)")
            } else {
                print("Failed to read value")
            }
        } else {
            print("Failed to read key info")
        }
        IOServiceClose(conn)
    }
    IOObjectRelease(service)
}
