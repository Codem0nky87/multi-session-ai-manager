import subprocess
import time
import threading

def burn_gpu():
    # Use system_profiler to repeatedly query graphics (minor load)
    # Or just use an infinite loop of something Metal-based?
    # Better: run a small swift script that burns Metal!
    swift_code = '''
    import Metal
    import Foundation

    guard let device = MTLCreateSystemDefaultDevice() else { exit(1) }
    guard let commandQueue = device.makeCommandQueue() else { exit(1) }

    let length = 1024 * 1024 * 10
    let buffer = device.makeBuffer(length: length, options: .storageModeShared)!

    while true {
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.fill(buffer: buffer, range: 0..<length, value: 0xFF)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    '''
    with open('/tmp/gpu_burn.swift', 'w') as f:
        f.write(swift_code)
    subprocess.Popen(['swift', '/tmp/gpu_burn.swift'])

burn_gpu()
