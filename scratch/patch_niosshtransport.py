import sys, re

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'r') as f:
    code = f.read()

# Add the actor
actor_code = '''
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

/// `Sendable` box used to hand Citadel's `TTYStdinWriter` out of the `withPTY`
'''

code = code.replace("/// `Sendable` box used to hand Citadel's `TTYStdinWriter` out of the `withPTY`", actor_code)


# Update CitadelPTYTerminalStream to use the actor
old_stream = '''final class CitadelPTYTerminalStream: PTY {
    let writer: TTYStdinWriter
    let writerBox: TTYWriterBox
    let closeCoordinator: SSHCloseCoordinator
    let pump: SSHStreamPump
    
    init(
        writer: TTYStdinWriter,
        writerBox: TTYWriterBox,
        closeCoordinator: SSHCloseCoordinator,
        pump: SSHStreamPump
    ) {
        self.writer = writer
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
    }

    func send(_ data: Data) {
        let writer = self.writer
        let writerBox = self.writerBox
        let closeCoordinator = self.closeCoordinator
        Task {
            do {
                try await writer.write(ByteBuffer(bytes: data))
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

new_stream = '''final class CitadelPTYTerminalStream: PTY {
    let writer: CitadelTerminalWriter
    let writerBox: TTYWriterBox
    let closeCoordinator: SSHCloseCoordinator
    let pump: SSHStreamPump
    
    init(
        writer: TTYStdinWriter,
        writerBox: TTYWriterBox,
        closeCoordinator: SSHCloseCoordinator,
        pump: SSHStreamPump
    ) {
        self.writer = CitadelTerminalWriter(writer: writer)
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
    }

    func send(_ data: Data) {
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

code = code.replace(old_stream, new_stream)

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'w') as f:
    f.write(code)

