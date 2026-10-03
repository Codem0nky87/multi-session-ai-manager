import sys, re

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'r') as f:
    code = f.read()

# Add the AsyncStream-based Writer Actor logic directly into NIOPTYChannel!
old_channel = '''private final class NIOPTYChannel: PTYChannel, @unchecked Sendable {
    private let writer: TTYStdinWriter
    private let writerBox: WriterBox
    private let closeCoordinator: PTYCloseCoordinator
    private let pump: Task<Void, Never>

    var isOpen: Bool { writerBox.isOpen }

    init(
        writer: TTYStdinWriter,
        writerBox: WriterBox,
        closeCoordinator: PTYCloseCoordinator,
        pump: Task<Void, Never>
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

new_channel = '''private final class NIOPTYChannel: PTYChannel, @unchecked Sendable {
    private let writer: TTYStdinWriter
    private let writerBox: WriterBox
    private let closeCoordinator: PTYCloseCoordinator
    private let pump: Task<Void, Never>
    private let continuation: AsyncStream<Data>.Continuation

    var isOpen: Bool { writerBox.isOpen }

    init(
        writer: TTYStdinWriter,
        writerBox: WriterBox,
        closeCoordinator: PTYCloseCoordinator,
        pump: Task<Void, Never>
    ) {
        self.writer = writer
        self.writerBox = writerBox
        self.closeCoordinator = closeCoordinator
        self.pump = pump
        
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation in
            cont = continuation
        }
        self.continuation = cont
        
        Task { [weak writerBox] in
            var buffer = Data()
            for await data in stream {
                buffer.append(data)
                
                while !buffer.isEmpty {
                    // Send smaller chunks to prevent remote PTY output queue explosion and SwiftNIO backpressure
                    let chunkSize = 1024
                    let chunk = buffer.prefix(chunkSize)
                    buffer.removeFirst(chunk.count)
                    
                    do {
                        try await writer.write(ByteBuffer(bytes: chunk))
                        if !buffer.isEmpty {
                            try await Task.sleep(nanoseconds: 5_000_000) // 5ms delay
                        }
                    } catch {
                        writerBox?.markClosed()
                        closeCoordinator.requestClose()
                        buffer.removeAll()
                        break
                    }
                }
            }
        }
    }

    func send(_ data: Data) {
        continuation.yield(data)
    }'''

code = code.replace(old_channel, new_channel)

with open('app/MultiSessionAIManager/Core/NIOSSHTransport.swift', 'w') as f:
    f.write(code)

