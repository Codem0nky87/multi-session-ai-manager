import Foundation

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Response = (HTTPURLResponse, Data)
    typealias Handler = @Sendable (URLRequest) throws -> Response
    typealias Completion = @Sendable (Result<Response, Error>) -> Bool
    typealias AsyncHandler = @Sendable (URLRequest, @escaping Completion) -> Void
    typealias StopHandler = @Sendable () -> Void

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registrations: [String: Registration] = [:]

    private let stateLock = NSLock()
    private var isStopped = false
    private var isFinished = false
    private var stopHandler: StopHandler?

    static func install(host: String, handler: @escaping Handler) {
        install(host: host, asyncHandler: { request, completion in
            do {
                _ = completion(.success(try handler(request)))
            } catch {
                _ = completion(.failure(error))
            }
        })
    }

    static func install(
        host: String,
        asyncHandler: @escaping AsyncHandler,
        onStop: @escaping StopHandler = {}
    ) {
        lock.withLock {
            registrations[host.lowercased()] = Registration(
                start: asyncHandler,
                stop: onStop
            )
        }
    }

    static func remove(host: String) {
        _ = lock.withLock {
            registrations.removeValue(forKey: host.lowercased())
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return lock.withLock { registrations[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host?.lowercased(),
              let registration = Self.lock.withLock({ Self.registrations[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let canStart = stateLock.withLock {
            guard !isStopped, !isFinished else { return false }
            stopHandler = registration.stop
            return true
        }
        guard canStart else { return }

        registration.start(request) { [weak self] result in
            self?.deliver(result) ?? false
        }
    }

    override func stopLoading() {
        let handler = stateLock.withLock { () -> StopHandler? in
            guard !isStopped, !isFinished else { return nil }
            isStopped = true
            defer { stopHandler = nil }
            return stopHandler
        }
        handler?()
    }

    private func deliver(_ result: Result<Response, Error>) -> Bool {
        let shouldDeliver = stateLock.withLock {
            guard !isStopped, !isFinished else { return false }
            isFinished = true
            stopHandler = nil
            return true
        }
        guard shouldDeliver else { return false }

        switch result {
        case let .success((response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
        return true
    }

    private struct Registration: @unchecked Sendable {
        let start: AsyncHandler
        let stop: StopHandler
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.withLock { value }
    }

    func update(_ transform: (inout Value) -> Void) {
        lock.withLock { transform(&value) }
    }
}
