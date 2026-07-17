import CryptoKit
import Foundation

struct EAPAKAPacket: Equatable, Sendable {
    struct Attribute: Equatable, Sendable {
        var type: UInt8
        var data: Data

        func encoded() throws -> Data {
            let rawLength = 2 + data.count
            let padding = (4 - rawLength % 4) % 4
            let total = rawLength + padding
            guard total >= 4, total <= 1020 else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_attribute")) }
            var output = Data([type, UInt8(total / 4)])
            output.append(data)
            output.append(Data(repeating: 0, count: padding))
            return output
        }
    }

    var code: UInt8
    var identifier: UInt8
    var type: UInt8
    var subtype: UInt8
    var attributes: [Attribute]
    var opaqueData = Data()

    func encoded() throws -> Data {
        if code == 3 || code == 4 {
            return Data([code, identifier, 0, 4])
        }
        var body = Data([type])
        if !opaqueData.isEmpty {
            body.append(opaqueData)
        } else {
            body.append(contentsOf: [subtype, 0, 0])
            for attribute in attributes { body.append(try attribute.encoded()) }
        }
        guard body.count + 4 <= Int(UInt16.max) else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_length")) }
        var output = Data([code, identifier])
        output.appendUInt16(UInt16(body.count + 4))
        output.append(body)
        return output
    }

    static func parse(_ data: Data) throws -> EAPAKAPacket {
        guard data.count >= 4, let length = data.uint16(at: 2), length >= 4,
              Int(length) <= data.count else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_packet"))
        }
        let code = data[0]
        let identifier = data[1]
        if code == 3 || code == 4 {
            guard length == 4 else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_terminal")) }
            return EAPAKAPacket(code: code, identifier: identifier, type: 0, subtype: 0, attributes: [])
        }
        guard length >= 5 else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_packet")) }
        let type = data[4]
        if type != 23 && type != 50 {
            return EAPAKAPacket(
                code: code, identifier: identifier, type: type, subtype: 0, attributes: [],
                opaqueData: Data(data[5..<Int(length)])
            )
        }
        guard length >= 8 else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_packet")) }
        var attributes: [Attribute] = []
        var offset = 8
        while offset < Int(length) {
            guard offset + 4 <= Int(length) else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_attribute")) }
            let attributeLength = Int(data[offset + 1]) * 4
            guard attributeLength >= 4, offset + attributeLength <= Int(length) else {
                throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_attribute"))
            }
            attributes.append(Attribute(
                type: data[offset],
                data: Data(data[(offset + 2)..<(offset + attributeLength)])
            ))
            offset += attributeLength
        }
        return EAPAKAPacket(
            code: code, identifier: identifier, type: type, subtype: data[5], attributes: attributes
        )
    }
}

struct EAPAKAKeys: Equatable, Sendable {
    var masterKey: Data
    var encryptionKey: Data
    var authenticationKey: Data
    var msk: Data
    var emsk: Data

    static func derive(identity: String, aka: VoWiFiAKAResult) throws -> EAPAKAKeys {
        guard aka.ck.count == 16, aka.ik.count == 16 else { throw VoWiFiError.malformedAPDU }
        var masterInput = Data(identity.utf8)
        masterInput.append(aka.ik)
        masterInput.append(aka.ck)
        let masterKey = Data(Insecure.SHA1.hash(data: masterInput))
        let stream = fips1862PRF(seed: masterKey, count: 160)
        return EAPAKAKeys(
            masterKey: masterKey,
            encryptionKey: Data(stream[0..<16]),
            authenticationKey: Data(stream[16..<32]),
            msk: Data(stream[32..<96]),
            emsk: Data(stream[96..<160])
        )
    }
}

enum EAPAKA {
    static let typeIdentity: UInt8 = 1
    static let typeAKA: UInt8 = 23
    static let subtypeChallenge: UInt8 = 1
    static let subtypeSynchronizationFailure: UInt8 = 4
    static let subtypeIdentity: UInt8 = 5
    static let subtypeNotification: UInt8 = 12
    static let attributeRAND: UInt8 = 1
    static let attributeAUTN: UInt8 = 2
    static let attributeRES: UInt8 = 3
    static let attributeAUTS: UInt8 = 4
    static let attributeMAC: UInt8 = 11
    static let attributeIdentity: UInt8 = 14
    static let attributeResultInd: UInt8 = 135

    static func identityResponse(to request: EAPAKAPacket, identity: String) throws -> EAPAKAPacket {
        guard request.code == 1 else { throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_identity")) }
        if request.type == typeIdentity {
            return EAPAKAPacket(
                code: 2, identifier: request.identifier, type: typeIdentity,
                subtype: 0, attributes: [], opaqueData: Data(identity.utf8)
            )
        }
        var identityData = Data()
        identityData.appendUInt16(UInt16(identity.utf8.count))
        identityData.append(Data(identity.utf8))
        return EAPAKAPacket(
            code: 2, identifier: request.identifier, type: request.type,
            subtype: subtypeIdentity,
            attributes: [EAPAKAPacket.Attribute(type: attributeIdentity, data: identityData)]
        )
    }

    static func challengeVector(from request: EAPAKAPacket) throws -> (rand: Data, autn: Data) {
        guard request.code == 1, request.type == typeAKA, request.subtype == subtypeChallenge else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_challenge"))
        }
        guard let randAttribute = request.attributes.first(where: { $0.type == attributeRAND }),
              let autnAttribute = request.attributes.first(where: { $0.type == attributeAUTN }),
              randAttribute.data.count >= 18, autnAttribute.data.count >= 18 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_challenge"))
        }
        return (
            Data(randAttribute.data[2..<18]),
            Data(autnAttribute.data[2..<18])
        )
    }

    static func challengeResponse(
        to request: EAPAKAPacket,
        identity: String,
        aka: VoWiFiAKAResult
    ) throws -> (packet: EAPAKAPacket, keys: EAPAKAKeys) {
        guard (4...16).contains(aka.res.count) else { throw VoWiFiError.malformedAPDU }
        let keys = try EAPAKAKeys.derive(identity: identity, aka: aka)
        try verifyMAC(packet: request, key: keys.authenticationKey)
        var resData = Data()
        resData.appendUInt16(UInt16(aka.res.count * 8))
        resData.append(aka.res)
        var attributes = [EAPAKAPacket.Attribute(type: attributeRES, data: resData)]
        if request.attributes.contains(where: { $0.type == attributeResultInd }) {
            attributes.append(EAPAKAPacket.Attribute(type: attributeResultInd, data: Data([0, 0])))
        }
        attributes.append(EAPAKAPacket.Attribute(type: attributeMAC, data: Data(repeating: 0, count: 18)))
        var response = EAPAKAPacket(
            code: 2, identifier: request.identifier, type: request.type,
            subtype: subtypeChallenge, attributes: attributes
        )
        let mac = try calculateMAC(packet: response, key: keys.authenticationKey)
        response.attributes[response.attributes.count - 1] = EAPAKAPacket.Attribute(
            type: attributeMAC, data: Data([0, 0]) + mac
        )
        return (response, keys)
    }

    static func synchronizationFailureResponse(
        to request: EAPAKAPacket,
        auts: Data
    ) throws -> EAPAKAPacket {
        guard auts.count == 14 else { throw VoWiFiError.malformedAPDU }
        return EAPAKAPacket(
            code: 2, identifier: request.identifier, type: request.type,
            subtype: subtypeSynchronizationFailure,
            attributes: [EAPAKAPacket.Attribute(type: attributeAUTS, data: Data([0, 0]) + auts)]
        )
    }

    static func notificationResponse(to request: EAPAKAPacket, key: Data?) throws -> EAPAKAPacket {
        var attributes = request.attributes.filter { $0.type == 12 }
        if key != nil {
            attributes.append(EAPAKAPacket.Attribute(type: attributeMAC, data: Data(repeating: 0, count: 18)))
        }
        var response = EAPAKAPacket(
            code: 2, identifier: request.identifier, type: request.type,
            subtype: subtypeNotification, attributes: attributes
        )
        if let key {
            let mac = try calculateMAC(packet: response, key: key)
            response.attributes[response.attributes.count - 1] = EAPAKAPacket.Attribute(
                type: attributeMAC, data: Data([0, 0]) + mac
            )
        }
        return response
    }

    private static func verifyMAC(packet: EAPAKAPacket, key: Data) throws {
        guard let attribute = packet.attributes.first(where: { $0.type == attributeMAC }),
              attribute.data.count >= 18 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_mac"))
        }
        let received = Data(attribute.data[2..<18])
        let expected = try calculateMAC(packet: packet, key: key)
        guard received == expected else { throw VoWiFiError.ikeAuthenticationFailed }
    }

    private static func calculateMAC(packet: EAPAKAPacket, key: Data) throws -> Data {
        var zeroed = packet
        guard let index = zeroed.attributes.firstIndex(where: { $0.type == attributeMAC }) else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.eap_mac"))
        }
        zeroed.attributes[index].data = Data(repeating: 0, count: zeroed.attributes[index].data.count)
        return Data(VoWiFiCrypto.hmacSHA1(key: key, data: try zeroed.encoded()).prefix(16))
    }
}

private func fips1862PRF(seed: Data, count: Int) -> Data {
    var xKey = [UInt8](repeating: 0, count: 20)
    let seedBytes = [UInt8](seed.prefix(20))
    xKey.replaceSubrange(0..<seedBytes.count, with: seedBytes)
    var output = Data()
    while output.count < count {
        for _ in 0..<2 where output.count < count {
            let w = fips1862G(xKey)
            output.append(contentsOf: w)
            xKey = add160(xKey, w, carry: 1)
        }
    }
    return Data(output.prefix(count))
}

private func fips1862G(_ xValue: [UInt8]) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 64)
    block.replaceSubrange(0..<min(20, xValue.count), with: xValue.prefix(20))
    var words = [UInt32](repeating: 0, count: 80)
    for index in 0..<16 {
        let offset = index * 4
        words[index] = UInt32(block[offset]) << 24 | UInt32(block[offset + 1]) << 16
            | UInt32(block[offset + 2]) << 8 | UInt32(block[offset + 3])
    }
    for index in 16..<80 {
        words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]).rotatedLeft(1)
    }
    var a: UInt32 = 0x67452301
    var b: UInt32 = 0xEFCDAB89
    var c: UInt32 = 0x98BADCFE
    var d: UInt32 = 0x10325476
    var e: UInt32 = 0xC3D2E1F0
    for index in 0..<80 {
        let f: UInt32
        let k: UInt32
        switch index {
        case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
        case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
        case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
        default: f = b ^ c ^ d; k = 0xCA62C1D6
        }
        let temporary = a.rotatedLeft(5) &+ f &+ e &+ k &+ words[index]
        e = d; d = c; c = b.rotatedLeft(30); b = a; a = temporary
    }
    let hashes = [
        UInt32(0x67452301) &+ a, UInt32(0xEFCDAB89) &+ b,
        UInt32(0x98BADCFE) &+ c, UInt32(0x10325476) &+ d,
        UInt32(0xC3D2E1F0) &+ e
    ]
    var output = Data()
    hashes.forEach { output.appendUInt32($0) }
    return [UInt8](output)
}

private func add160(_ lhs: [UInt8], _ rhs: [UInt8], carry initialCarry: UInt16) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 20)
    var carry = initialCarry
    for index in stride(from: 19, through: 0, by: -1) {
        let sum = UInt16(lhs[index]) + UInt16(rhs[index]) + carry
        result[index] = UInt8(sum & 0xFF)
        carry = sum >> 8
    }
    return result
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 {
        (self << count) | (self >> (32 - count))
    }
}
