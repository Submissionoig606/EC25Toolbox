import Foundation
@preconcurrency import Network

final class RemoteManagementServer: @unchecked Sendable {
    typealias ErrorHandler = @Sendable (String) -> Void

    private let transport: EC25Transport
    private let replayGuard = RemoteReplayGuard()
    private let queue = DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.remote.server", qos: .userInitiated)
    private var listeners: [NWListener] = []
    private var secret = Data()
    private var errorHandler: ErrorHandler?

    init(transport: EC25Transport) {
        self.transport = transport
    }

    func start(
        lanPort: Int,
        tailscalePort: Int,
        secret: Data,
        errorHandler: ErrorHandler? = nil
    ) throws -> [String] {
        stop()
        guard secret.count == 32 else { throw RemoteManagementError.invalidPairingKey }
        self.secret = secret
        self.errorHandler = errorHandler
        let connectionSecret = secret

        var endpoints: [String] = []
        for address in remoteBindAddresses() {
            let port = address.kind == .lan ? lanPort : tailscalePort
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                throw RemoteManagementError.invalidPort
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(address.host),
                port: nwPort
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                Task { await self.handle(connection, secret: connectionSecret) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.errorHandler?(error.localizedDescription)
                }
            }
            listener.start(queue: queue)
            listeners.append(listener)
            endpoints.append("\(address.host):\(port)")
        }
        guard !listeners.isEmpty else { throw RemoteManagementError.serverUnavailable }
        return endpoints
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        secret.removeAll()
        errorHandler = nil
    }

    private func handle(_ connection: NWConnection, secret: Data) async {
        defer { connection.cancel() }
        do {
            try await RemoteSocket.accept(connection)
            let frame = try await RemoteSocket.receiveFrame(from: connection)
            let request = try RemoteCrypto.open(RemoteRequest.self, data: frame, secret: secret)
            do {
                try await replayGuard.accept(request)
                let response = try await process(request)
                let responseFrame = try RemoteCrypto.seal(response, secret: secret)
                try await RemoteSocket.sendFrame(responseFrame, through: connection)
            } catch {
                let response = RemoteResponse(
                    requestID: request.requestID,
                    success: false,
                    error: error.localizedDescription
                )
                let responseFrame = try RemoteCrypto.seal(response, secret: secret)
                try await RemoteSocket.sendFrame(responseFrame, through: connection)
            }
        } catch {
            // Authentication failures intentionally receive no plaintext response.
        }
    }

    private func process(_ request: RemoteRequest) async throws -> RemoteResponse {
        switch request.kind {
        case .probe:
            let description = await transport.description()
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                description: description
            )
        case .at:
            guard let command = request.command,
                  !command.isEmpty,
                  command.count <= 4_096,
                  (request.payload?.utf8.count ?? 0) <= 1_048_576 else {
                throw RemoteManagementError.protocolFailure
            }
            let timeout = min(max(request.timeoutMs ?? 4_000, 500), 120_000)
            let lines = try await transport.send(
                command: command,
                payload: request.payload,
                timeoutMs: timeout
            )
            return RemoteResponse(
                requestID: request.requestID,
                success: true,
                lines: lines
            )
        }
    }
}
