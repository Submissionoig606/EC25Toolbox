import CVoWiFiCrypto
import CryptoKit
import Foundation
import Security

enum VoWiFiCrypto {
    static func randomData(count: Int) throws -> Data {
        guard count >= 0 else { throw VoWiFiError.transport(localized("vowifi.error.random")) }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw VoWiFiError.transport(localizedFormat("vowifi.error.random_status", status))
        }
        return data
    }

    static func hmacSHA1(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hmacMD5(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func prfPlusSHA256(key: Data, seed: Data, count: Int) throws -> Data {
        guard count >= 0, count <= 255 * 32 else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.prf_length"))
        }
        var result = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while result.count < count {
            var input = previous
            input.append(seed)
            input.append(counter)
            previous = hmacSHA256(key: key, data: input)
            result.append(previous)
            counter &+= 1
        }
        return Data(result.prefix(count))
    }

    static func aesCBCEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        try aesCBC(key: key, iv: iv, input: plaintext, encrypt: true)
    }

    static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        try aesCBC(key: key, iv: iv, input: ciphertext, encrypt: false)
    }

    private static func aesCBC(key: Data, iv: Data, input: Data, encrypt: Bool) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16,
              !input.isEmpty, input.count.isMultiple(of: 16) else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.aes_parameters"))
        }
        var output = Data(count: input.count)
        let outputCapacity = input.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        if encrypt {
                            vowifi_aes_cbc_encrypt(
                                keyBuffer.bindMemory(to: UInt8.self).baseAddress, key.count,
                                ivBuffer.bindMemory(to: UInt8.self).baseAddress,
                                inputBuffer.bindMemory(to: UInt8.self).baseAddress, input.count,
                                outputBuffer.bindMemory(to: UInt8.self).baseAddress, outputCapacity,
                                &outputLength
                            )
                        } else {
                            vowifi_aes_cbc_decrypt(
                                keyBuffer.bindMemory(to: UInt8.self).baseAddress, key.count,
                                ivBuffer.bindMemory(to: UInt8.self).baseAddress,
                                inputBuffer.bindMemory(to: UInt8.self).baseAddress, input.count,
                                outputBuffer.bindMemory(to: UInt8.self).baseAddress, outputCapacity,
                                &outputLength
                            )
                        }
                    }
                }
            }
        }
        guard status == 0 else {
            throw VoWiFiError.transport(localizedFormat("vowifi.error.crypto_status", status))
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    static func modp14KeyPair() throws -> (privateKey: Data, publicKey: Data) {
        var privateKey = try randomData(count: 32)
        privateKey[0] |= 0x80
        privateKey[31] |= 0x01
        var publicKey = Data(count: 256)
        let status = publicKey.withUnsafeMutableBytes { publicBuffer in
            privateKey.withUnsafeBytes { privateBuffer in
                vowifi_modp14_public_key(
                    privateBuffer.bindMemory(to: UInt8.self).baseAddress,
                    publicBuffer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        guard status == 0 else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.dh_key"))
        }
        return (privateKey, publicKey)
    }

    static func modp14SharedSecret(privateKey: Data, peerPublicKey: Data) throws -> Data {
        guard privateKey.count == 32, peerPublicKey.count == 256 else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.dh_key"))
        }
        var output = Data(count: 256)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            peerPublicKey.withUnsafeBytes { peerBuffer in
                privateKey.withUnsafeBytes { privateBuffer in
                    vowifi_modp14_shared_secret(
                        privateBuffer.bindMemory(to: UInt8.self).baseAddress,
                        peerBuffer.bindMemory(to: UInt8.self).baseAddress,
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }
        guard status == 0 else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.dh_key"))
        }
        return output
    }
}

enum VoWiFiDHAgreement {
    case group19(P256.KeyAgreement.PrivateKey)
    case group14(privateKey: Data, publicKey: Data)
    case group31(Curve25519.KeyAgreement.PrivateKey)

    static let preferredGroups: [UInt16] = [IKEv2.dhECP256, IKEv2.dhMODP2048, IKEv2.dhCurve25519]

    static func make(group: UInt16) throws -> VoWiFiDHAgreement {
        switch group {
        case IKEv2.dhECP256:
            return .group19(P256.KeyAgreement.PrivateKey())
        case IKEv2.dhMODP2048:
            let pair = try VoWiFiCrypto.modp14KeyPair()
            return .group14(privateKey: pair.privateKey, publicKey: pair.publicKey)
        case IKEv2.dhCurve25519:
            return .group31(Curve25519.KeyAgreement.PrivateKey())
        default:
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.dh_key"))
        }
    }

    var group: UInt16 {
        switch self {
        case .group19: IKEv2.dhECP256
        case .group14: IKEv2.dhMODP2048
        case .group31: IKEv2.dhCurve25519
        }
    }

    var publicKey: Data {
        switch self {
        case let .group19(key):
            return Data(key.publicKey.x963Representation.dropFirst())
        case let .group14(_, publicKey):
            return publicKey
        case let .group31(key):
            return key.publicKey.rawRepresentation
        }
    }

    func sharedSecret(peerPublicKey: Data) throws -> Data {
        switch self {
        case let .group19(privateKey):
            guard peerPublicKey.count == 64 else {
                throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.dh_key"))
            }
            let peer = try P256.KeyAgreement.PublicKey(
                x963Representation: Data([0x04]) + peerPublicKey
            )
            return try privateKey.sharedSecretFromKeyAgreement(with: peer)
                .withUnsafeBytes { Data($0) }
        case let .group14(privateKey, _):
            return try VoWiFiCrypto.modp14SharedSecret(
                privateKey: privateKey,
                peerPublicKey: peerPublicKey
            )
        case let .group31(privateKey):
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            return try privateKey.sharedSecretFromKeyAgreement(with: peer)
                .withUnsafeBytes { Data($0) }
        }
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(value >> 32))
        appendUInt32(UInt32(value & 0xFFFF_FFFF))
    }

    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func uint64(at offset: Int) -> UInt64? {
        guard let high = uint32(at: offset), let low = uint32(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
}
