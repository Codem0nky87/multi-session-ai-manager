import sys, re

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'r') as f:
    code = f.read()

# Replace the actor with a class that uses AsyncStream
old_actor = '''
actor CitadelTerminalWriter {
    private let writer: TTYStdinWriter
    private var buffer: Data = Data()
    private var isWriting: Bool = false
    private var closeCoordinator: SSHCloseCoordinator?
    private var writerBox: TTYWriterBox?
    
    init(writer: TTYStdinWriter) {
        self.writer = writer
    }
    
    func setCoordinators(box: TTYWriterBox, closeCoordinator: SSHCloseCoordinator) {
        self.writerBox = box
        self.closeCoordinator = closeCoordinator
    }
    
    func enqueue(_ data: Data) {
        buffer.append(data)
        if !isWriting {
            isWriting = true
            Task {
                await flush()
            }
        }
    }
    
    private func flush() async {
        while !buffer.isEmpty {
            let chunkSize = 1024
            let chunk = buffer.prefix(chunkSize)
            buffer.removeFirst(chunk.count)
            
            do {
                try await writer.write(ByteBuffer(bytes: chunk))
                if !buffer.isEmpty {
                    try await Task.sleep(nanoseconds: 5_000_000) // 5ms delay between chunks
                }
            } catch {
                writerBox?.markClosed()
                closeCoordinator?.requestClose()
                buffer.removeAll()
                break
            }
        }
        isWriting = false
    }
}
'''

new_actor = '''
final class CitadelTerminalWriter: @unchecked Sendable {
    private let writer: TTYStdinWriter
    private let continuation: AsyncStream<Data>.Continuation
    private var closeCoordinator: SSHCloseCoordinator?
    private var writerBox: TTYWriterBox?
    
    init(writer: TTYStdinWriter) {
        self.writer = writer
        
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation in
            cont = continuation
        }
        self.continuation = cont
        
        Task {
            var buffer = Data()
            for await data in stream {
                buffer.append(data)
                
                while !buffer.isEmpty {
                    let chunkSize = 1024
                    let chunk = buffer.prefix(chunkSize)
                    buffer.removeFirst(chunk.count)
                    
                    do {
                        try await self.writer.write(ByteBuffer(bytes: chunk))
                        if !buffer.isEmpty {
                            try await Task.sleep(nanoseconds: 5_000_000) // 5ms delay between chunks
                        }
                    } catch {
                        self.writerBox?.markClosed()
                        self.closeCoordinator?.requestClose()
                        buffer.removeAll()
                        break
                    }
                }
            }
        }
    }
    
    func setCoordinators(box: TTYWriterBox, closeCoordinator: SSHCloseCoordinator) {
        self.writerBox = box
        self.closeCoordinator = closeCoordinator
    }
    
    func send(_ data: Data) {
        continuation.yield(data)
    }
}
'''

code = code.replace(old_actor.strip(), new_actor.strip())

# Update the send method to call send directly
old_send = '''    func send(_ data: Data) {
        let writer = self.writer
        Task {
            await writer.enqueue(data)
        }
    }'''

new_send = '''    func send(_ data: Data) {
        writer.send(data)
    }'''

code = code.replace(old_send, new_send)

# Update init
old_init = '''    init(
        writer: TTYStdinWriter,
        writerBox: TTYWriterBox,
        closeCoordinator: SSHCloseCoordinator,
        pump: SSHStreamPump
    ) {
        let terminalWriter = CitadelTerminalWriter(writer: writer)
        self.writer = terminalWriter
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
        
        Task {
            await terminalWriter.setCoordinators(box: writerBox, closeCoordinator: closeCoordinator)
        }
    }'''

new_init = '''    init(
        writer: TTYStdinWriter,
        writerBox: TTYWriterBox,
        closeCoordinator: SSHCloseCoordinator,
        pump: SSHStreamPump
    ) {
        let terminalWriter = CitadelTerminalWriter(writer: writer)
        terminalWriter.setCoordinators(box: writerBox, closeCoordinator: closeCoordinator)
        self.writer = terminalWriter
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
    }'''

code = code.replace(old_init, new_init)

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'w') as f:
    f.write(code)

