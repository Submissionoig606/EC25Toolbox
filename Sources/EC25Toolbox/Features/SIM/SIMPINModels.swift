import Foundation
import Security

/// Live SIM security information reported by CPIN, CLCK, and QPINC.
struct SIMSecurityState: Equatable {
    var status = "-"
    var lockEnabled: Bool?
    var pinRetries: Int?
    var pukRetries: Int?
    var iccid = ""
    var storedPINAvailable = false
    var lastError: String?

    var isReady: Bool {
        status.caseInsensitiveCompare("READY") == .orderedSame
    }

    var requiresPIN: Bool {
        status.caseInsensitiveCompare("SIM PIN") == .orderedSame
    }

    var requiresPUK: Bool {
        status.caseInsensitiveCompare("SIM PUK") == .orderedSame
    }
}

enum SIMPINError: LocalizedError, Equatable {
    case invalidPIN
    case pinMismatch
    case simNotReady
    case simIdentityUnavailable
    case automaticAttemptBlocked
    case unlockFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPIN:
            localized("sim_pin.error.invalid_pin")
        case .pinMismatch:
            localized("sim_pin.error.pin_mismatch")
        case .simNotReady:
            localized("sim_pin.error.sim_not_ready")
        case .simIdentityUnavailable:
            localized("sim_pin.error.iccid_unavailable")
        case .automaticAttemptBlocked:
            localized("sim_pin.error.last_attempt_blocked")
        case .unlockFailed:
            localized("sim_pin.error.unlock_failed")
        case let .keychain(status):
            localizedFormat("sim_pin.error.keychain", status)
        }
    }
}

/// Accepts only the numeric 4...8 digit PIN format supported by the modem.
func normalizedSIMPIN(_ input: String) throws -> String {
    let pin = trimmed(input)
    guard (4...8).contains(pin.count), pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw SIMPINError.invalidPIN
    }
    return pin
}

func parseSIMStatus(_ lines: [String]) -> String {
    guard let line = lines.first(where: { $0.uppercased().hasPrefix("+CPIN:") }),
          let colon = line.firstIndex(of: ":") else { return "-" }
    return trimmed(String(line[line.index(after: colon)...]))
}

func parseSIMLockEnabled(_ lines: [String]) -> Bool? {
    guard let line = lines.first(where: { $0.uppercased().hasPrefix("+CLCK:") }),
          let colon = line.firstIndex(of: ":") else { return nil }
    switch trimmed(String(line[line.index(after: colon)...])).split(separator: ",").first {
    case "0": return false
    case "1": return true
    default: return nil
    }
}

func parseSIMRetries(_ lines: [String]) -> (pin: Int?, puk: Int?) {
    guard let line = lines.first(where: { $0.uppercased().hasPrefix("+QPINC:") }),
          let colon = line.firstIndex(of: ":") else { return (nil, nil) }
    let fields = line[line.index(after: colon)...]
        .split(separator: ",")
        .map { trimmed(String($0)).replacingOccurrences(of: "\"", with: "") }
    guard fields.count >= 3, fields[0].caseInsensitiveCompare("SC") == .orderedSame else {
        return (nil, nil)
    }
    return (Int(fields[1]), Int(fields[2]))
}

func normalizedSIMICCID(_ lines: [String]) -> String {
    let candidates = lines.flatMap { line -> [Substring] in
        if let colon = line.firstIndex(of: ":") {
            return line[line.index(after: colon)...].split(whereSeparator: { !$0.isNumber })
        }
        return line.split(whereSeparator: { !$0.isNumber })
    }
    return candidates.map(String.init).first(where: { $0.count >= 10 }) ?? ""
}

/// Stores one PIN per ICCID so a saved PIN is never tried against another SIM.
enum SIMPINKeychain {
    static let service = "ing.fuyaoskyrocket.ec25toolbox.sim-pin"
    static let legacyServices = ["one.nickspace.ec25-manager.sim-pin"]

    static func read(for iccid: String) throws -> String? {
        let account = account(for: iccid)
        if let data = try read(service: service, account: account) {
            return String(data: data, encoding: .utf8)
        }
        for legacyService in legacyServices {
            guard let data = try read(service: legacyService, account: account) else { continue }
            try save(data, account: account)
            return String(data: data, encoding: .utf8)
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
        guard status == errSecSuccess else { throw SIMPINError.keychain(status) }
        return result as? Data
    }

    static func save(_ pin: String, for iccid: String) throws {
        try save(Data(pin.utf8), account: account(for: iccid))
    }

    private static func save(_ data: Data, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SIMPINError.keychain(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SIMPINError.keychain(addStatus) }
    }

    static func delete(for iccid: String) throws {
        let account = account(for: iccid)
        for serviceName in [service] + legacyServices {
            let status = SecItemDelete(
                baseQuery(service: serviceName, account: account) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SIMPINError.keychain(status)
            }
        }
    }

    static func account(for iccid: String) -> String {
        iccid.filter(\.isNumber)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
