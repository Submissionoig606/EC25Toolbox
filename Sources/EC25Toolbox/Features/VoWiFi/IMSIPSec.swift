import Foundation

struct IMSIPSecAgreement: Equatable, Sendable {
    var localSPI: UInt32
    var remoteSPI: UInt32
    var localPort: UInt16
    var remotePort: UInt16
    var algorithm: String
    var encryptionAlgorithm: String

    var securityClientHeader: String {
        "ipsec-3gpp;alg=\(algorithm);ealg=\(encryptionAlgorithm);prot=esp;mod=trans;spi-c=\(localSPI);spi-s=\(remoteSPI);port-c=\(localPort);port-s=\(remotePort)"
    }

    static func proposed() throws -> IMSIPSecAgreement {
        let spi = try VoWiFiCrypto.randomData(count: 8)
        guard let local = spi.uint32(at: 0), let remote = spi.uint32(at: 4) else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.ims_security"))
        }
        return IMSIPSecAgreement(
            localSPI: local == 0 ? 1 : local,
            remoteSPI: remote == 0 ? 2 : remote,
            localPort: 5062,
            remotePort: 5064,
            algorithm: "hmac-md5-96",
            encryptionAlgorithm: "aes-cbc"
        )
    }

    static func negotiated(serverHeader: String, proposed: IMSIPSecAgreement) throws -> IMSIPSecAgreement {
        let candidates = serverHeader.split(separator: ",").map(String.init)
        for candidate in candidates where candidate.lowercased().contains("ipsec-3gpp") {
            var fields: [String: String] = [:]
            for part in candidate.split(separator: ";").dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    fields[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pair[1].trimmingCharacters(in: .whitespaces).lowercased()
                }
            }
            let algorithm = fields["alg"] ?? proposed.algorithm
            let encryption = fields["ealg"] ?? proposed.encryptionAlgorithm
            guard algorithm == "hmac-md5-96" || algorithm == "hmac-sha-1-96",
                  encryption == "aes-cbc",
                  let localSPI = fields["spi-c"].flatMap(UInt32.init),
                  let remoteSPI = fields["spi-s"].flatMap(UInt32.init),
                  let localPort = fields["port-c"].flatMap(UInt16.init),
                  let remotePort = fields["port-s"].flatMap(UInt16.init) else { continue }
            return IMSIPSecAgreement(
                localSPI: localSPI, remoteSPI: remoteSPI,
                localPort: localPort, remotePort: remotePort,
                algorithm: algorithm, encryptionAlgorithm: encryption
            )
        }
        throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.ims_security_server"))
    }
}

actor IMSIPSecContext {
    private let agreement: IMSIPSecAgreement
    private let encryptionKey: Data
    private let integrityKey: Data
    private var outboundSequence: UInt32 = 1
    private var highestInboundSequence: UInt32 = 0

    init(agreement: IMSIPSecAgreement, ck: Data, ik: Data) throws {
        guard ck.count == 16, ik.count == 16 else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.ims_security_keys"))
        }
        self.agreement = agreement
        encryptionKey = ck
        integrityKey = ik
    }

    func ports() -> (local: UInt16, remote: UInt16) {
        (agreement.localPort, agreement.remotePort)
    }

    func seal(udpSegment: Data) throws -> Data {
        let sequence = outboundSequence
        outboundSequence &+= 1
        guard sequence != 0 else { throw VoWiFiError.transport(localized("vowifi.error.esp_sequence")) }
        var plaintext = udpSegment
        let paddingLength = (16 - ((plaintext.count + 2) % 16)) % 16
        if paddingLength > 0 { plaintext.append(contentsOf: (1...paddingLength).map(UInt8.init)) }
        plaintext.append(UInt8(paddingLength))
        plaintext.append(17) // UDP
        let iv = try VoWiFiCrypto.randomData(count: 16)
        let ciphertext = try VoWiFiCrypto.aesCBCEncrypt(
            key: encryptionKey, iv: iv, plaintext: plaintext
        )
        var packet = Data()
        packet.appendUInt32(agreement.remoteSPI)
        packet.appendUInt32(sequence)
        packet.append(iv)
        packet.append(ciphertext)
        packet.append(integrity(packet).prefix(12))
        return packet
    }

    func open(_ packet: Data) throws -> Data {
        guard packet.count >= 8 + 16 + 16 + 12,
              packet.uint32(at: 0) == agreement.localSPI,
              let sequence = packet.uint32(at: 4), sequence > highestInboundSequence else {
            throw VoWiFiError.transport(localized("vowifi.error.ims_esp_packet"))
        }
        let received = packet.suffix(12)
        let authenticated = Data(packet.dropLast(12))
        guard Data(received) == Data(integrity(authenticated).prefix(12)) else {
            throw VoWiFiError.transport(localized("vowifi.error.ims_esp_integrity"))
        }
        let iv = Data(packet[8..<24])
        let ciphertext = Data(packet[24..<(packet.count - 12)])
        var plaintext = try VoWiFiCrypto.aesCBCDecrypt(
            key: encryptionKey, iv: iv, ciphertext: ciphertext
        )
        guard plaintext.count >= 2, plaintext.last == 17 else {
            throw VoWiFiError.transport(localized("vowifi.error.ims_esp_payload"))
        }
        plaintext.removeLast()
        guard let padLength = plaintext.last, Int(padLength) + 1 <= plaintext.count else {
            throw VoWiFiError.transport(localized("vowifi.error.ims_esp_padding"))
        }
        plaintext.removeLast(Int(padLength) + 1)
        highestInboundSequence = sequence
        return plaintext
    }

    private func integrity(_ data: Data) -> Data {
        if agreement.algorithm == "hmac-sha-1-96" {
            return VoWiFiCrypto.hmacSHA1(key: integrityKey, data: data)
        }
        return VoWiFiCrypto.hmacMD5(key: integrityKey, data: data)
    }
}
