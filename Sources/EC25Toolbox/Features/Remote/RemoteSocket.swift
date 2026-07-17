import Foundation
@preconcurrency import Network

enum RemoteSocket {
    private static let queue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.remote.socket", qos: .userInitiated)

    static func connect(host: String, port: Int) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RemoteManagementError.invalidPort
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await waitUntilReady(connection)
        return connection
    }

    static func accept(_ connection: NWConnection) async throws {
        try await waitUntilReady(connection)
    }

    static func sendFrame(_ data: Data, through connection: NWConnection) async throws {
        guard !data.isEmpty, data.count <= RemoteDefaults.maximumFrameBytes else {
            throw RemoteManagementError.protocolFailure
        }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RemoteManagementError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    static func receiveFrame(from connection: NWConnection) async throws -> Data {
        let prefix = try await receiveExactly(4, from: connection)
        let length = prefix.withUnsafeBytes { rawBuffer -> UInt32 in
            rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0, length <= RemoteDefaults.maximumFrameBytes else {
            throw RemoteManagementError.protocolFailure
        }
        return try await receiveExactly(Int(length), from: connection)
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        let gate = RemoteContinuationGate<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resolve(.success(()))
                case let .failed(error), let .waiting(error):
                    gate.resolve(.failure(RemoteManagementError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    gate.resolve(.failure(RemoteManagementError.serverUnavailable))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    private static func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RemoteManagementError.connectionFailed(error.localizedDescription))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: RemoteManagementError.protocolFailure)
                } else {
                    continuation.resume(throwing: RemoteManagementError.protocolFailure)
                }
            }
        }
    }
}

private final class RemoteContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
