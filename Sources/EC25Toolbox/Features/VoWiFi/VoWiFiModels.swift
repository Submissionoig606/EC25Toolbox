import Foundation

enum VoWiFiPhase: String, Codable, CaseIterable {
    case disabled
    case waitingForSIM
    case readingIdentity
    case discoveringEPDG
    case connectingEPDG
    case authenticating
    case tunnelReady
    case registeringIMS
    case registered
    case reconnecting
    case failed

    var localizationKey: String { "vowifi.phase.\(rawValue)" }

    var isWorking: Bool {
        switch self {
        case .readingIdentity, .discoveringEPDG, .connectingEPDG, .authenticating,
             .registeringIMS, .reconnecting:
            true
        default:
            false
        }
    }
}

enum VoWiFiIdentitySource: String, Codable, Sendable {
    case isim
    case derivedUSIM
    case manual

    var localizationKey: String { "vowifi.identity.source.\(rawValue)" }
}

struct VoWiFiIdentity: Codable, Equatable, Sendable {
    var imsi = ""
    var mcc = ""
    var mnc = ""
    var impi = ""
    var impu = ""
    var realm = ""
    var source: VoWiFiIdentitySource = .derivedUSIM

    var isComplete: Bool {
        !imsi.isEmpty && !impi.isEmpty && !impu.isEmpty && !realm.isEmpty
    }
}

struct VoWiFiCarrierConfiguration: Codable, Equatable, Sendable {
    var mcc = ""
    var mnc = ""
    var epdgAddress = ""
    var pcscfAddress = ""
    var realm = ""
    var privateIdentity = ""
    var publicIdentity = ""

    static func derived(
        imsi: String,
        mncLength: Int? = nil,
        epdgOverride: String? = nil,
        pcscfOverride: String? = nil,
        realmOverride: String? = nil,
        privateIdentityOverride: String? = nil,
        publicIdentityOverride: String? = nil
    ) throws -> VoWiFiCarrierConfiguration {
        let digits = imsi.filter(\.isNumber)
        guard digits.count >= 5 else { throw VoWiFiError.invalidIMSI }
        let mcc = String(digits.prefix(3))
        // EF_AD on the USIM is authoritative for the home-network MNC length.
        // Falling back to three digits is the 3GPP-safe default when EF_AD is
        // absent; manually supplied realm/ePDG values still take precedence.
        let length = (mncLength == 2 || mncLength == 3) ? mncLength! : 3
        let rawMNC = String(digits.dropFirst(3).prefix(length))
        let mnc = String(repeating: "0", count: max(0, 3 - rawMNC.count)) + rawMNC
        let realm = normalized(realmOverride)
            ?? "ims.mnc\(mnc).mcc\(mcc).3gppnetwork.org"
        let epdg = normalized(epdgOverride)
            ?? "epdg.epc.mnc\(mnc).mcc\(mcc).pub.3gppnetwork.org"
        let impi = normalized(privateIdentityOverride)
            ?? "\(digits)@\(realm)"
        let impu = normalized(publicIdentityOverride)
            ?? "sip:\(digits)@\(realm)"
        return VoWiFiCarrierConfiguration(
            mcc: mcc,
            mnc: mnc,
            epdgAddress: epdg,
            pcscfAddress: normalized(pcscfOverride) ?? "",
            realm: realm,
            privateIdentity: impi,
            publicIdentity: impu
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

struct VoWiFiTunnelSnapshot: Codable, Equatable {
    var epdgAddress = ""
    var resolvedAddress = ""
    var innerAddress = ""
    var pcscfAddress = ""
    var natDetected = false
    var ikeSPI = ""
    var childSPI = ""
    var establishedAt: Date?
    var lastPacketAt: Date?
}

struct VoWiFiLogEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case info
        case success
        case warning
        case failure
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var message: String
}

struct VoWiFiState: Equatable {
    var phase: VoWiFiPhase = .disabled
    var identity: VoWiFiIdentity?
    var tunnel = VoWiFiTunnelSnapshot()
    var lastError: String?
    var lastConnectedAt: Date?
    var reconnectAttempt = 0
    var receivedSMSCount = 0
    var logs: [VoWiFiLogEntry] = []

    var isEnabled: Bool { phase != .disabled }
    var isRegistered: Bool { phase == .registered }
}

enum VoWiFiError: LocalizedError, Equatable {
    case modemUnavailable
    case simNotReady
    case invalidIMSI
    case incompleteIdentity
    case isimUnavailable(String)
    case malformedAPDU
    case apduStatus(String)
    case akaSyncFailure(Data)
    case akaMACFailure
    case epdgResolutionFailed(String)
    case transport(String)
    case malformedIKE(String)
    case unsupportedIKETransform(String)
    case ikeAuthenticationFailed
    case missingTunnelConfiguration
    case imsRegistrationFailed(String)
    case malformedSMS
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modemUnavailable: localized("vowifi.error.modem_unavailable")
        case .simNotReady: localized("vowifi.error.sim_not_ready")
        case .invalidIMSI: localized("vowifi.error.invalid_imsi")
        case .incompleteIdentity: localized("vowifi.error.incomplete_identity")
        case let .isimUnavailable(reason): localizedFormat("vowifi.error.isim_unavailable", reason)
        case .malformedAPDU: localized("vowifi.error.malformed_apdu")
        case let .apduStatus(status): localizedFormat("vowifi.error.apdu_status", status)
        case .akaSyncFailure: localized("vowifi.error.aka_sync")
        case .akaMACFailure: localized("vowifi.error.aka_mac")
        case let .epdgResolutionFailed(host): localizedFormat("vowifi.error.epdg_resolution", host)
        case let .transport(reason): localizedFormat("vowifi.error.transport", reason)
        case let .malformedIKE(reason): localizedFormat("vowifi.error.ike_malformed", reason)
        case let .unsupportedIKETransform(reason): localizedFormat("vowifi.error.ike_transform", reason)
        case .ikeAuthenticationFailed: localized("vowifi.error.ike_authentication")
        case .missingTunnelConfiguration: localized("vowifi.error.tunnel_configuration")
        case let .imsRegistrationFailed(reason): localizedFormat("vowifi.error.ims_registration", reason)
        case .malformedSMS: localized("vowifi.error.sms_malformed")
        case .cancelled: localized("vowifi.error.cancelled")
        }
    }
}

struct VoWiFiAKAResult: Equatable, Sendable {
    var res: Data
    var ck: Data
    var ik: Data
    var auts: Data?
}
