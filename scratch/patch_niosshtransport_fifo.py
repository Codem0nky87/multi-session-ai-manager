import sys, re

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'r') as f:
    code = f.read()

# Replace the simple actor with a FIFO queue actor
old_actor = '''
actor CitadelTerminalWriter {
    let writer: TTYStdinWriter
    
    init(writer: TTYStdinWriter) {
        self.writer = writer
    }
    
    func write(_ data: Data) async throws {
        // Chunking the data to prevent backpressure explosion or remote buffer overflow
        let chunkSize = 1024
        var offset = 0
        while offset < data.count {
            let end = Swift.min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            try await writer.write(ByteBuffer(bytes: chunk))
            offset += chunkSize
            if offset < data.count {
                try await Task.sleep(nanoseconds: 5_000_000) // 5ms delay between chunks
            }
        }
    }
}
'''

new_actor = '''
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

code = code.replace(old_actor.strip(), new_actor.strip())

# Update the send method to call enqueue synchronously
old_send = '''    func send(_ data: Data) {
        let writer = self.writer
        let writerBox = self.writerBox
        let closeCoordinator = self.closeCoordinator
        Task {
            do {
                try await writer.write(data)
            } catch {
                // A failed channel write means the connection under it is gone.
                // Marking closed is what turns "typing into a dead tab" from a
                // silently swallowed error into a stale channel the session's
                // reconciliation can actually see.
                writerBox.markClosed()
                closeCoordinator.requestClose()
            }
        }
    }'''

new_send = '''    func send(_ data: Data) {
        let writer = self.writer
        Task {
            await writer.enqueue(data)
        }
    }'''

code = code.replace(old_send, new_send)

# Also need to set the coordinators in init
old_init = '''    init(
        writer: TTYStdinWriter,
        writerBox: TTYWriterBox,
        closeCoordinator: SSHCloseCoordinator,
        pump: SSHStreamPump
    ) {
        self.writer = CitadelTerminalWriter(writer: writer)
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
    }'''

new_init = '''    init(
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

code = code.replace(old_init, new_init)

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'w') as f:
    f.write(code)

