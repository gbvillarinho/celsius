import Foundation
import Network

public enum DaikinTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
    case unsuccessfulStatus
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Daikin device returned an unreadable local response."
        case .responseTooLarge: "The Daikin device returned an unexpectedly large response."
        case .unsuccessfulStatus: "The Daikin device rejected the local request."
        case .timeout: "The Daikin device did not respond on the local network."
        }
    }
}

/// Raw bounded TCP exchange with the Daikin unit's local HTTP-like endpoint.
public struct DaikinLocalTransport: Sendable {
    public typealias Exchange = @Sendable (String, UInt16, Data, Duration) async throws -> Data
    public static let defaultPort: UInt16 = 15914
    private static let timeout: Duration = .seconds(8)
    private static let maxResponseBytes = 65_536
    private let address: String
    private let port: UInt16
    private let exchange: Exchange

    public init(address: String, port: UInt16 = defaultPort, exchange: Exchange? = nil) {
        self.address = address
        self.port = port
        self.exchange = exchange ?? Self.networkExchange
    }

    public func request(method: String, path: String, body: Data? = nil) async throws -> Data {
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: \(address)\r\nConnection: close\r\n".utf8)
        if let body {
            request.append(Data("Content-Type: text/plain\r\nContent-Length: \(body.count)\r\n".utf8))
        }
        request.append(Data("\r\n".utf8))
        if let body { request.append(body) }
        let bytes = try await exchange(address, port, request, Self.timeout)
        guard bytes.count <= Self.maxResponseBytes else { throw DaikinTransportError.responseTooLarge }
        let crlfSeparator = bytes.range(of: Data([13, 10, 13, 10]))
        let lfSeparator = bytes.range(of: Data([10, 10]))
        guard let separator = [crlfSeparator, lfSeparator].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            throw DaikinTransportError.invalidResponse
        }
        let header = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
        let statusLine = header.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard statusLine.hasPrefix("HTTP/1.") else { throw DaikinTransportError.invalidResponse }
        guard statusLine.split(separator: " ").dropFirst().first == "200" else { throw DaikinTransportError.unsuccessfulStatus }
        var responseBody = Data(bytes[separator.upperBound...])
        if let contentLengthLine = header.components(separatedBy: .newlines).first(where: { $0.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("content-length:") }),
           let expectedLength = Int(contentLengthLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
            guard responseBody.count >= expectedLength else { throw DaikinTransportError.invalidResponse }
            responseBody = Data(responseBody.prefix(expectedLength))
        }
        if responseBody.last == 10 { responseBody.removeLast() }
        if responseBody.last == 13 { responseBody.removeLast() }
        guard !responseBody.isEmpty else { throw DaikinTransportError.invalidResponse }
        return responseBody
    }

    private static let networkExchange: Exchange = { address, port, request, timeout in
        try await DaikinLocalTransport.tcpExchange(address: address, port: port, request: request, timeout: timeout)
    }

    private static func tcpExchange(address: String, port: UInt16, request: Data, timeout: Duration) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw DaikinTransportError.invalidResponse }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let exchange = DaikinTCPExchange(connection: connection, request: request, timeout: timeout, continuation: continuation)
            exchange.start()
        }
    }
}

private final class DaikinTCPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: Duration
    private let continuation: CheckedContinuation<Data, Error>
    private let queue = DispatchQueue(label: "com.gabrielvillarinho.celsius.daikin-network")
    private let lock = NSLock()
    private var received = Data()
    private var completed = false
    // NWConnection callbacks capture this exchange weakly. Keep it alive until a response or timeout
    // completes the continuation; otherwise the request can remain suspended forever after start().
    private var keepAlive: DaikinTCPExchange?
    private let maximumBytes = 65_536

    init(connection: NWConnection, request: Data, timeout: Duration, continuation: CheckedContinuation<Data, Error>) {
        self.connection = connection
        self.request = request
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        lock.withLock { keepAlive = self }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error { self.finish(.failure(error)) } else { self.receiveNext() }
                })
            case .failed(let error): self.finish(.failure(error))
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
        let timeoutSeconds = max(1, Int(timeout.components.seconds))
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
            self?.finish(.failure(DaikinTransportError.timeout))
        }
    }

    private func receiveNext() {
        let remaining = lock.withLock { maximumBytes - received.count }
        guard remaining > 0 else { finish(.failure(DaikinTransportError.responseTooLarge)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.lock.withLock { self.received.append(data) } }
            let size = self.lock.withLock { self.received.count }
            if size > self.maximumBytes { self.finish(.failure(DaikinTransportError.responseTooLarge)); return }
            if let error { self.finish(.failure(error)); return }
            if isComplete { self.finish(.success(self.lock.withLock { self.received })); return }
            if self.hasReceivedCompleteBody { self.finish(.success(self.lock.withLock { self.received })); return }
            self.receiveNext()
        }
    }

    private var hasReceivedCompleteBody: Bool {
        lock.withLock {
            let bytes = received
            let separator = bytes.range(of: Data([13, 10, 13, 10])) ?? bytes.range(of: Data([10, 10]))
            guard let separator else { return false }
            let header = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
            guard let lengthLine = header.components(separatedBy: .newlines).first(where: { $0.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("content-length:") }),
                  let length = Int(lengthLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else { return false }
            return bytes.count >= separator.upperBound + length
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let shouldFinish = lock.withLock {
            guard !completed else { return false }
            completed = true
            keepAlive = nil
            return true
        }
        guard shouldFinish else { return }
        connection.cancel()
        continuation.resume(with: result)
    }
}
