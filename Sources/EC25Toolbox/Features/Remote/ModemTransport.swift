import Foundation

protocol ModemTransport: Actor {
    func connect() async throws -> String
    func disconnect() async
    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String]
}

extension EC25Transport: ModemTransport {
    func connect() async throws -> String {
        try open()
    }

    func disconnect() async {
        close()
    }

    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        try send(command: command, payload: payload, timeoutMs: timeoutMs)
    }
}

actor UnavailableRemoteTransport: ModemTransport {
    private let error: RemoteManagementError

    init(error: RemoteManagementError) {
        self.error = error
    }

    func connect() async throws -> String { throw error }
    func disconnect() async {}
    func transact(command: String, payload: String?, timeoutMs: Int32) async throws -> [String] {
        throw error
    }
}
