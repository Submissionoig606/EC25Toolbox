import CryptoKit
import Foundation
import Security

enum RemoteAccessKeychain {
    static let service = "ing.fuyaoskyrocket.ec25toolbox.remote-access"
    static let legacyServices = ["one.nickspace.ec25-manager.remote-access"]
    private static let serverAccount = "server-pairing-secret"

    static func serverSecret() throws -> Data {
        if let existing = try read(account: serverAccount) {
            guard existing.count == 32 else { throw RemoteManagementError.invalidPairingKey }
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw RemoteManagementError.authenticationFailed
        }
        let secret = Data(bytes)
        try save(secret, account: serverAccount)
        return secret
    }

    static func rotateServerSecret() throws -> Data {
        try delete(account: serverAccount)
        return try serverSecret()
    }

    static func clientSecret(host: String, port: Int) throws -> Data? {
        try read(account: clientAccount(host: host, port: port))
    }

    static func saveClientSecret(_ secret: Data, host: String, port: Int) throws {
        guard secret.count == 32 else { throw RemoteManagementError.invalidPairingKey }
        try save(secret, account: clientAccount(host: host, port: port))
    }

    static func encodedPairingKey(_ secret: Data) -> String {
        secret.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodedPairingKey(_ value: String) throws -> Data {
        var base64 = trimmed(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw RemoteManagementError.invalidPairingKey
        }
        return data
    }

    private static func clientAccount(host: String, port: Int) -> String {
        "client:\(host.lowercased()):\(port)"
    }

    private static func read(account: String) throws -> Data? {
        if let current = try read(service: service, account: account) {
            return current
        }
        for legacyService in legacyServices {
            guard let legacy = try read(service: legacyService, account: account) else { continue }
            try save(legacy, account: account)
            return legacy
        }
        return nil
    }

    private static func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteManagementError.keychain(status) }
        return result as? Data
    }

    private static func save(_ data: Data, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw RemoteManagementError.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RemoteManagementError.keychain(addStatus) }
    }

    private static func delete(account: String) throws {
        for serviceName in [service] + legacyServices {
            let status = SecItemDelete(
                baseQuery(service: serviceName, account: account) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw RemoteManagementError.keychain(status)
            }
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum RemoteCrypto {
    private static let authenticatedContext = Data("EC25 Toolbox Remote v1".utf8)

    static func seal<T: Encodable>(_ value: T, secret: Data) throws -> Data {
        guard secret.count == 32 else { throw RemoteManagementError.invalidPairingKey }
        let plaintext = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: secret),
            authenticating: authenticatedContext
        )
        guard let combined = box.combined else { throw RemoteManagementError.protocolFailure }
        return combined
    }

    static func open<T: Decodable>(_ type: T.Type, data: Data, secret: Data) throws -> T {
        guard secret.count == 32 else { throw RemoteManagementError.invalidPairingKey }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: secret),
                authenticating: authenticatedContext
            )
            return try JSONDecoder().decode(type, from: plaintext)
        } catch {
            throw RemoteManagementError.authenticationFailed
        }
    }
}

actor RemoteReplayGuard {
    private var accepted: [UUID: Int64] = [:]

    func accept(_ request: RemoteRequest, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard request.version == RemoteDefaults.protocolVersion else {
            throw RemoteManagementError.protocolFailure
        }
        guard abs(now - request.timestamp) <= RemoteDefaults.requestLifetimeSeconds else {
            throw RemoteManagementError.requestExpired
        }
        accepted = accepted.filter { now - $0.value <= RemoteDefaults.requestLifetimeSeconds * 2 }
        guard accepted[request.requestID] == nil else { throw RemoteManagementError.replayedRequest }
        accepted[request.requestID] = now
    }
}
