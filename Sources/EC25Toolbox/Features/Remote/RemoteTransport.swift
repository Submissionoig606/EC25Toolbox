import Foundation

actor RemoteModemTransport: ModemTransport {
    private let host: String
    private let port: Int
    private let secret: Data
    private var open = false
    private var remoteDescription = ""

    init(host: String, port: Int, secret: Data) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    func connect() async throws -> String {
        let response = try await request(RemoteRequest(kind: .probe))
        guard response.success else {
            throw RemoteManagementError.remoteFailure(response.error ?? localized("remote.error.unknown"))
        }
        open = true
        remoteDescription = response.description ?? ""
        return localizedFormat("remote.device_description", host, port, remoteDescription)
    }

    func disconnect() async {
        open = false
        remoteDescription = ""
    }

    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        guard open else { throw EC25TransportError.notOpen }
        let request = RemoteRequest(
            kind: .at,
            command: command,
            payload: payload,
            timeoutMs: timeoutMs
        )
        let response = try await self.request(request)
        guard response.requestID == request.requestID,
              response.version == RemoteDefaults.protocolVersion else {
            throw RemoteManagementError.protocolFailure
        }
        guard response.success else {
            throw RemoteManagementError.remoteFailure(response.error ?? localized("remote.error.unknown"))
        }
        return response.lines ?? []
    }

    private func request(_ request: RemoteRequest) async throws -> RemoteResponse {
        let connection = try await RemoteSocket.connect(host: host, port: port)
        defer { connection.cancel() }
        let frame = try RemoteCrypto.seal(request, secret: secret)
        try await RemoteSocket.sendFrame(frame, through: connection)
        let responseFrame = try await RemoteSocket.receiveFrame(from: connection)
        let response = try RemoteCrypto.open(RemoteResponse.self, data: responseFrame, secret: secret)
        let now = Int64(Date().timeIntervalSince1970)
        guard response.requestID == request.requestID,
              response.version == RemoteDefaults.protocolVersion,
              abs(now - response.timestamp) <= RemoteDefaults.requestLifetimeSeconds else {
            throw RemoteManagementError.protocolFailure
        }
        return response
    }
}
