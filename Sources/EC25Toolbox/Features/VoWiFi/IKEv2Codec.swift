import CryptoKit
import Foundation

enum IKEv2 {
    static let version: UInt8 = 0x20
    static let initiatorFlag: UInt8 = 0x08

    enum Exchange: UInt8, Sendable {
        case ikeSAInit = 34
        case ikeAuth = 35
        case createChildSA = 36
        case informational = 37
    }

    enum PayloadType: UInt8, Sendable {
        case none = 0
        case securityAssociation = 33
        case keyExchange = 34
        case identificationInitiator = 35
        case identificationResponder = 36
        case certificate = 37
        case certificateRequest = 38
        case authentication = 39
        case nonce = 40
        case notify = 41
        case delete = 42
        case vendorID = 43
        case trafficSelectorInitiator = 44
        case trafficSelectorResponder = 45
        case encrypted = 46
        case configuration = 47
        case eap = 48
    }

    struct Header: Equatable, Sendable {
        var initiatorSPI: UInt64
        var responderSPI: UInt64
        var nextPayload: PayloadType
        var exchange: Exchange
        var flags: UInt8
        var messageID: UInt32
        var length: UInt32

        func encoded() -> Data {
            var data = Data()
            data.appendUInt64(initiatorSPI)
            data.appendUInt64(responderSPI)
            data.append(nextPayload.rawValue)
            data.append(IKEv2.version)
            data.append(exchange.rawValue)
            data.append(flags)
            data.appendUInt32(messageID)
            data.appendUInt32(length)
            return data
        }

        static func parse(_ data: Data) throws -> Header {
            guard data.count >= 28,
                  let spiI = data.uint64(at: 0), let spiR = data.uint64(at: 8),
                  let next = PayloadType(rawValue: data[16]), data[17] >> 4 == 2,
                  let exchange = Exchange(rawValue: data[18]),
                  let messageID = data.uint32(at: 20), let length = data.uint32(at: 24),
                  length >= 28, Int(length) <= data.count else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_header"))
            }
            return Header(
                initiatorSPI: spiI, responderSPI: spiR, nextPayload: next,
                exchange: exchange, flags: data[19], messageID: messageID, length: length
            )
        }
    }

    struct Payload: Equatable, Sendable {
        var type: PayloadType
        var critical = false
        var body: Data
        var nextPayloadOverride: PayloadType? = nil
    }

    struct Message: Equatable, Sendable {
        var header: Header
        var payloads: [Payload]

        func encoded() throws -> Data {
            var payloadData = Data()
            for (index, payload) in payloads.enumerated() {
                let next = payload.nextPayloadOverride
                    ?? (index + 1 < payloads.count ? payloads[index + 1].type : .none)
                guard payload.body.count + 4 <= Int(UInt16.max) else {
                    throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_payload_length"))
                }
                payloadData.append(next.rawValue)
                payloadData.append(payload.critical ? 0x80 : 0x00)
                payloadData.appendUInt16(UInt16(payload.body.count + 4))
                payloadData.append(payload.body)
            }
            var outputHeader = header
            outputHeader.nextPayload = payloads.first?.type ?? .none
            outputHeader.length = UInt32(28 + payloadData.count)
            var output = outputHeader.encoded()
            output.append(payloadData)
            return output
        }

        static func parse(_ data: Data) throws -> Message {
            let header = try Header.parse(data)
            var type = header.nextPayload
            var offset = 28
            var payloads: [Payload] = []
            while type != .none {
                guard offset + 4 <= Int(header.length),
                      let length = data.uint16(at: offset + 2), length >= 4,
                      offset + Int(length) <= Int(header.length),
                      let next = PayloadType(rawValue: data[offset]) else {
                    throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_payload"))
                }
                payloads.append(Payload(
                    type: type,
                    critical: data[offset + 1] & 0x80 != 0,
                    body: Data(data[(offset + 4)..<(offset + Int(length))]),
                    nextPayloadOverride: type == .encrypted ? next : nil
                ))
                offset += Int(length)
                if type == .encrypted {
                    type = .none
                } else {
                    type = next
                }
            }
            guard offset == Int(header.length) else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_trailing"))
            }
            return Message(header: header, payloads: payloads)
        }
    }

    enum TransformType: UInt8, Sendable {
        case encryption = 1
        case prf = 2
        case integrity = 3
        case dh = 4
        case extendedSequenceNumbers = 5
    }

    struct Transform: Equatable, Sendable {
        var type: TransformType
        var identifier: UInt16
        var keyLength: UInt16?
    }

    struct Proposal: Equatable, Sendable {
        var protocolID: UInt8
        var spi = Data()
        var transforms: [Transform]
    }

    static let encrAESCBC: UInt16 = 12
    static let prfHMACSHA256: UInt16 = 5
    static let integHMACSHA256_128: UInt16 = 12
    static let dhMODP2048: UInt16 = 14
    static let dhECP256: UInt16 = 19
    static let dhCurve25519: UInt16 = 31
    static let protocolIKE: UInt8 = 1
    static let protocolESP: UInt8 = 3

    static func defaultIKEProposal(dhGroup: UInt16) -> Proposal {
        Proposal(protocolID: protocolIKE, transforms: [
            Transform(type: .encryption, identifier: encrAESCBC, keyLength: 128),
            Transform(type: .prf, identifier: prfHMACSHA256, keyLength: nil),
            Transform(type: .integrity, identifier: integHMACSHA256_128, keyLength: nil),
            Transform(type: .dh, identifier: dhGroup, keyLength: nil)
        ])
    }

    static func defaultESPProposal(spi: Data) -> Proposal {
        Proposal(protocolID: protocolESP, spi: spi, transforms: [
            Transform(type: .encryption, identifier: encrAESCBC, keyLength: 128),
            Transform(type: .integrity, identifier: integHMACSHA256_128, keyLength: nil),
            Transform(type: .extendedSequenceNumbers, identifier: 0, keyLength: nil)
        ])
    }

    static func securityAssociationPayload(_ proposals: [Proposal]) throws -> Payload {
        guard !proposals.isEmpty else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_no_proposal"))
        }
        var body = Data()
        for (proposalIndex, proposal) in proposals.enumerated() {
            var proposalBody = Data([
                UInt8(proposalIndex + 1), proposal.protocolID, UInt8(proposal.spi.count),
                UInt8(proposal.transforms.count)
            ])
            proposalBody.append(proposal.spi)
            for (index, transform) in proposal.transforms.enumerated() {
                var transformBody = Data([transform.type.rawValue, 0x00])
                transformBody.appendUInt16(transform.identifier)
                if let keyLength = transform.keyLength {
                    transformBody.appendUInt16(0x800E)
                    transformBody.appendUInt16(keyLength)
                }
                proposalBody.append(index + 1 < proposal.transforms.count ? 3 : 0)
                proposalBody.append(0)
                proposalBody.appendUInt16(UInt16(transformBody.count + 4))
                proposalBody.append(transformBody)
            }
            body.append(proposalIndex + 1 < proposals.count ? 2 : 0)
            body.append(0)
            body.appendUInt16(UInt16(proposalBody.count + 4))
            body.append(proposalBody)
        }
        return Payload(type: .securityAssociation, body: body)
    }

    static func parseSecurityAssociation(_ payload: Payload) throws -> [Proposal] {
        guard payload.type == .securityAssociation else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_sa"))
        }
        let data = payload.body
        var offset = 0
        var proposals: [Proposal] = []
        while offset < data.count {
            guard offset + 8 <= data.count, let length = data.uint16(at: offset + 2),
                  length >= 8, offset + Int(length) <= data.count else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_sa_proposal"))
            }
            let protocolID = data[offset + 5]
            let spiLength = Int(data[offset + 6])
            let transformCount = Int(data[offset + 7])
            var cursor = offset + 8
            guard cursor + spiLength <= offset + Int(length) else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_sa_spi"))
            }
            let spi = Data(data[cursor..<(cursor + spiLength)])
            cursor += spiLength
            var transforms: [Transform] = []
            while cursor < offset + Int(length) {
                guard cursor + 8 <= offset + Int(length),
                      let transformLength = data.uint16(at: cursor + 2), transformLength >= 8,
                      cursor + Int(transformLength) <= offset + Int(length),
                      let type = TransformType(rawValue: data[cursor + 4]),
                      let identifier = data.uint16(at: cursor + 6) else {
                    throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_transform_parse"))
                }
                var keyLength: UInt16?
                var attributeOffset = cursor + 8
                while attributeOffset + 4 <= cursor + Int(transformLength) {
                    let rawType = data.uint16(at: attributeOffset) ?? 0
                    if rawType == 0x800E { keyLength = data.uint16(at: attributeOffset + 2) }
                    attributeOffset += 4
                }
                transforms.append(Transform(type: type, identifier: identifier, keyLength: keyLength))
                cursor += Int(transformLength)
            }
            guard transforms.count == transformCount else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_transform_count"))
            }
            proposals.append(Proposal(protocolID: protocolID, spi: spi, transforms: transforms))
            offset += Int(length)
        }
        return proposals
    }

    static func keyExchangePayload(group: UInt16, publicKey: Data) -> Payload {
        var body = Data()
        body.appendUInt16(group)
        body.appendUInt16(0)
        body.append(publicKey)
        return Payload(type: .keyExchange, body: body)
    }

    static func noncePayload(_ nonce: Data) -> Payload {
        Payload(type: .nonce, body: nonce)
    }

    static func notifyPayload(type: UInt16, protocolID: UInt8 = 0, spi: Data = Data(), data: Data = Data()) -> Payload {
        var body = Data([protocolID, UInt8(spi.count)])
        body.appendUInt16(type)
        body.append(spi)
        body.append(data)
        return Payload(type: .notify, body: body)
    }

    static func identificationPayload(_ identity: String) -> Payload {
        var body = Data([3, 0, 0, 0]) // ID_RFC822_ADDR
        body.append(Data(identity.utf8))
        return Payload(type: .identificationInitiator, body: body)
    }

    static func authenticationPayload(sharedKeyMIC: Data) -> Payload {
        var body = Data([2, 0, 0, 0]) // Shared Key Message Integrity Code
        body.append(sharedKeyMIC)
        return Payload(type: .authentication, body: body)
    }

    static func configurationRequestPayload() -> Payload {
        var body = Data([1, 0, 0, 0])
        for attribute: UInt16 in [1, 3, 8, 10, 13, 20] {
            body.appendUInt16(attribute)
            body.appendUInt16(0)
        }
        return Payload(type: .configuration, body: body)
    }

    static func trafficSelectorPayload(initiator: Bool) -> Payload {
        var body = Data([1, 0, 0, 0])
        body.append(7) // TS_IPV4_ADDR_RANGE
        body.append(0)
        body.appendUInt16(16)
        body.appendUInt16(0)
        body.appendUInt16(UInt16.max)
        body.append(contentsOf: [0, 0, 0, 0, 255, 255, 255, 255])
        return Payload(type: initiator ? .trafficSelectorInitiator : .trafficSelectorResponder, body: body)
    }
}

struct IKEv2KeyMaterial: Equatable, Sendable {
    var skD: Data
    var skAi: Data
    var skAr: Data
    var skEi: Data
    var skEr: Data
    var skPi: Data
    var skPr: Data

    static func derive(
        nonceI: Data, nonceR: Data, sharedSecret: Data,
        initiatorSPI: UInt64, responderSPI: UInt64
    ) throws -> IKEv2KeyMaterial {
        let skeyseed = VoWiFiCrypto.hmacSHA256(key: nonceI + nonceR, data: sharedSecret)
        var seed = nonceI + nonceR
        seed.appendUInt64(initiatorSPI)
        seed.appendUInt64(responderSPI)
        // SHA-256 PRF: SK_d 32, SK_ai/ar 32 each, SK_ei/er 16 each, SK_pi/pr 32 each.
        var material = try VoWiFiCrypto.prfPlusSHA256(key: skeyseed, seed: seed, count: 208)
        func take(_ count: Int) -> Data {
            defer { material.removeFirst(count) }
            return Data(material.prefix(count))
        }
        return IKEv2KeyMaterial(
            skD: take(32), skAi: take(32), skAr: take(32),
            skEi: take(16), skEr: take(16), skPi: take(32), skPr: take(32)
        )
    }
}

struct IKEv2ProtectedPayload {
    static func seal(
        payloads: [IKEv2.Payload], header: IKEv2.Header,
        encryptionKey: Data, integrityKey: Data
    ) throws -> Data {
        let inner = try encodeInner(payloads)
        let padLength = (16 - ((inner.count + 1) % 16)) % 16
        var plaintext = inner
        if padLength > 0 { plaintext.append(contentsOf: (0..<padLength).map(UInt8.init)) }
        plaintext.append(UInt8(padLength))
        let iv = try VoWiFiCrypto.randomData(count: 16)
        let ciphertext = try VoWiFiCrypto.aesCBCEncrypt(key: encryptionKey, iv: iv, plaintext: plaintext)
        var encryptedBody = iv + ciphertext
        var outer = IKEv2.Message(
            header: header,
            payloads: [IKEv2.Payload(
                type: .encrypted,
                body: encryptedBody,
                nextPayloadOverride: payloads.first?.type ?? IKEv2.PayloadType.none
            )]
        )
        var wireWithoutICV = try outer.encoded()
        // SK payload length and IKE length include the 16-byte truncated SHA-256 ICV.
        let skLength = UInt16(encryptedBody.count + 4 + 16)
        wireWithoutICV.replaceSubrange(30..<32, with: [UInt8(skLength >> 8), UInt8(skLength & 0xFF)])
        let total = UInt32(wireWithoutICV.count + 16)
        wireWithoutICV.replaceSubrange(24..<28, with: [
            UInt8(total >> 24), UInt8((total >> 16) & 0xFF), UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)
        ])
        let icv = VoWiFiCrypto.hmacSHA256(key: integrityKey, data: wireWithoutICV).prefix(16)
        encryptedBody.append(icv)
        outer.payloads[0].body = encryptedBody
        return try outer.encoded()
    }

    static func open(
        wire: Data, encryptionKey: Data, integrityKey: Data
    ) throws -> (IKEv2.Header, [IKEv2.Payload]) {
        let message = try IKEv2.Message.parse(wire)
        guard message.payloads.count == 1, message.payloads[0].type == .encrypted,
              message.payloads[0].body.count >= 16 + 16 + 16 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_sk"))
        }
        let body = message.payloads[0].body
        let receivedICV = body.suffix(16)
        let authenticated = wire.dropLast(16)
        let expectedICV = VoWiFiCrypto.hmacSHA256(key: integrityKey, data: authenticated).prefix(16)
        guard Data(receivedICV) == Data(expectedICV) else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_integrity"))
        }
        let iv = Data(body.prefix(16))
        let ciphertext = Data(body.dropFirst(16).dropLast(16))
        var plaintext = try VoWiFiCrypto.aesCBCDecrypt(key: encryptionKey, iv: iv, ciphertext: ciphertext)
        guard let padLength = plaintext.last, Int(padLength) + 1 <= plaintext.count else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_padding"))
        }
        plaintext.removeLast(Int(padLength) + 1)
        return (message.header, try decodeInner(plaintext, firstType: innerFirstType(from: wire)))
    }

    private static func encodeInner(_ payloads: [IKEv2.Payload]) throws -> Data {
        var data = Data()
        for (index, payload) in payloads.enumerated() {
            let next = index + 1 < payloads.count ? payloads[index + 1].type : .none
            data.append(next.rawValue)
            data.append(payload.critical ? 0x80 : 0)
            data.appendUInt16(UInt16(payload.body.count + 4))
            data.append(payload.body)
        }
        return data
    }

    private static func decodeInner(_ data: Data, firstType: IKEv2.PayloadType) throws -> [IKEv2.Payload] {
        var offset = 0
        var type = firstType
        var payloads: [IKEv2.Payload] = []
        while type != .none {
            guard offset + 4 <= data.count, let length = data.uint16(at: offset + 2),
                  length >= 4, offset + Int(length) <= data.count,
                  let next = IKEv2.PayloadType(rawValue: data[offset]) else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_inner"))
            }
            payloads.append(IKEv2.Payload(
                type: type, critical: data[offset + 1] & 0x80 != 0,
                body: Data(data[(offset + 4)..<(offset + Int(length))])
            ))
            type = next
            offset += Int(length)
        }
        guard offset == data.count else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_inner_trailing"))
        }
        return payloads
    }

    private static func innerFirstType(from wire: Data) -> IKEv2.PayloadType {
        guard wire.count > 28, let type = IKEv2.PayloadType(rawValue: wire[28]) else { return .none }
        return type
    }
}
