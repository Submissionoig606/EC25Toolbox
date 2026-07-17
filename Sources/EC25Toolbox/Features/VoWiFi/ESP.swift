import Foundation

actor VoWiFiESPContext {
    private let sa: VoWiFiChildSA
    private var outboundSequence: UInt32 = 1
    private var highestInboundSequence: UInt32 = 0

    init(sa: VoWiFiChildSA) {
        self.sa = sa
    }

    func seal(innerPacket: Data, nextHeader: UInt8 = 4) throws -> Data {
        guard outboundSequence != 0 else {
            throw VoWiFiError.transport(localized("vowifi.error.esp_sequence"))
        }
        let sequence = outboundSequence
        outboundSequence &+= 1
        var plaintext = innerPacket
        let paddingLength = (16 - ((plaintext.count + 2) % 16)) % 16
        if paddingLength > 0 {
            plaintext.append(contentsOf: (1...paddingLength).map(UInt8.init))
        }
        plaintext.append(UInt8(paddingLength))
        plaintext.append(nextHeader)
        let iv = try VoWiFiCrypto.randomData(count: 16)
        let ciphertext = try VoWiFiCrypto.aesCBCEncrypt(
            key: sa.encryptionKeyInitiator, iv: iv, plaintext: plaintext
        )
        var packet = Data()
        packet.appendUInt32(sa.remoteSPI)
        packet.appendUInt32(sequence)
        packet.append(iv)
        packet.append(ciphertext)
        packet.append(VoWiFiCrypto.hmacSHA256(key: sa.integrityKeyInitiator, data: packet).prefix(16))
        return packet
    }

    func open(_ packet: Data) throws -> (innerPacket: Data, nextHeader: UInt8) {
        guard packet.count >= 8 + 16 + 16 + 16,
              let spi = packet.uint32(at: 0), spi == sa.localSPI,
              let sequence = packet.uint32(at: 4), sequence > highestInboundSequence else {
            throw VoWiFiError.transport(localized("vowifi.error.esp_packet"))
        }
        let receivedICV = packet.suffix(16)
        let authenticated = packet.dropLast(16)
        let expectedICV = VoWiFiCrypto.hmacSHA256(
            key: sa.integrityKeyResponder, data: Data(authenticated)
        ).prefix(16)
        guard Data(receivedICV) == Data(expectedICV) else {
            throw VoWiFiError.transport(localized("vowifi.error.esp_integrity"))
        }
        let iv = Data(packet[8..<24])
        let ciphertext = Data(packet[24..<(packet.count - 16)])
        var plaintext = try VoWiFiCrypto.aesCBCDecrypt(
            key: sa.encryptionKeyResponder, iv: iv, ciphertext: ciphertext
        )
        guard plaintext.count >= 2, let nextHeader = plaintext.last else {
            throw VoWiFiError.transport(localized("vowifi.error.esp_padding"))
        }
        plaintext.removeLast()
        guard let paddingLength = plaintext.last, Int(paddingLength) + 1 <= plaintext.count else {
            throw VoWiFiError.transport(localized("vowifi.error.esp_padding"))
        }
        plaintext.removeLast(Int(paddingLength) + 1)
        highestInboundSequence = sequence
        return (plaintext, nextHeader)
    }
}
