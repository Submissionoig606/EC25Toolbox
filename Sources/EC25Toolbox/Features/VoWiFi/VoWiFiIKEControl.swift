import Foundation

/// Handles responder-initiated INFORMATIONAL exchanges on the shared UDP
/// 4500 socket. This keeps the IKE SA alive without a NetworkExtension VPN.
actor VoWiFiIKEControlContext {
    private let initiatorSPI: UInt64
    private let responderSPI: UInt64
    private let keys: IKEv2KeyMaterial

    init(initiatorSPI: UInt64, responderSPI: UInt64, keys: IKEv2KeyMaterial) {
        self.initiatorSPI = initiatorSPI
        self.responderSPI = responderSPI
        self.keys = keys
    }

    func response(to wire: Data) throws -> Data? {
        let (header, payloads) = try IKEv2ProtectedPayload.open(
            wire: wire, encryptionKey: keys.skEr, integrityKey: keys.skAr
        )
        guard header.initiatorSPI == initiatorSPI,
              header.responderSPI == responderSPI,
              header.exchange == .informational else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_information"))
        }
        if header.flags & 0x20 != 0 { return nil }
        if payloads.contains(where: { $0.type == .delete }) {
            throw VoWiFiError.transport(localized("vowifi.error.ike_deleted"))
        }
        let responseHeader = IKEv2.Header(
            initiatorSPI: initiatorSPI, responderSPI: responderSPI,
            nextPayload: .encrypted, exchange: .informational,
            flags: IKEv2.initiatorFlag | 0x20,
            messageID: header.messageID, length: 0
        )
        return try IKEv2ProtectedPayload.seal(
            payloads: [], header: responseHeader,
            encryptionKey: keys.skEi, integrityKey: keys.skAi
        )
    }
}
