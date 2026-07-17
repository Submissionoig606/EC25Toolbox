import Foundation

struct IMSDecodedSMS: Equatable, Sendable {
    var messageReference: UInt8
    var sender: String
    var timestamp: Date
    var body: String
    var concatenationReference: UInt16?
    var partNumber: Int?
    var partCount: Int?
}

enum IMSSMSCodec {
    static func decodeRPData(_ data: Data) throws -> IMSDecodedSMS {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == 0x00 || bytes[0] == 0x01 else {
            throw VoWiFiError.malformedSMS
        }
        let reference = bytes[1]
        var offset = 2
        let originatorLength = Int(bytes[offset]); offset += 1
        guard offset + originatorLength < bytes.count else { throw VoWiFiError.malformedSMS }
        offset += originatorLength
        let destinationLength = Int(bytes[offset]); offset += 1
        guard offset + destinationLength < bytes.count else { throw VoWiFiError.malformedSMS }
        offset += destinationLength
        let tpduLength = Int(bytes[offset]); offset += 1
        guard tpduLength > 0, offset + tpduLength == bytes.count else { throw VoWiFiError.malformedSMS }
        let deliver = try decodeDeliver(Data(bytes[offset..<(offset + tpduLength)]))
        return IMSDecodedSMS(
            messageReference: reference, sender: deliver.sender,
            timestamp: deliver.timestamp, body: deliver.body,
            concatenationReference: deliver.concatenation?.reference,
            partNumber: deliver.concatenation?.part,
            partCount: deliver.concatenation?.total
        )
    }

    static func rpAck(messageReference: UInt8) -> Data {
        Data([0x02, messageReference])
    }

    private struct Concatenation: Equatable {
        var reference: UInt16
        var total: Int
        var part: Int
    }

    private static func decodeDeliver(
        _ data: Data
    ) throws -> (sender: String, timestamp: Date, body: String, concatenation: Concatenation?) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] & 0x03 == 0 else { throw VoWiFiError.malformedSMS }
        let hasUDH = bytes[0] & 0x40 != 0
        var offset = 1
        let addressDigits = Int(bytes[offset]); offset += 1
        guard offset < bytes.count else { throw VoWiFiError.malformedSMS }
        let toa = bytes[offset]; offset += 1
        let addressBytes = (addressDigits + 1) / 2
        guard offset + addressBytes + 10 <= bytes.count else { throw VoWiFiError.malformedSMS }
        let sender = try decodeAddress(
            digits: addressDigits, toa: toa,
            bytes: Array(bytes[offset..<(offset + addressBytes)])
        )
        offset += addressBytes
        offset += 1 // PID
        let dcs = bytes[offset]; offset += 1
        let timestamp = decodeTimestamp(Array(bytes[offset..<(offset + 7)]))
        offset += 7
        let userDataLength = Int(bytes[offset]); offset += 1
        guard offset <= bytes.count else { throw VoWiFiError.malformedSMS }
        let decoded = try decodeUserData(
            Array(bytes[offset...]), length: userDataLength, dcs: dcs, hasUDH: hasUDH
        )
        return (sender, timestamp, decoded.body, decoded.concatenation)
    }

    private static func decodeAddress(digits: Int, toa: UInt8, bytes: [UInt8]) throws -> String {
        var result = toa & 0x70 == 0x10 ? "+" : ""
        var count = 0
        for byte in bytes {
            for nibble in [byte & 0x0F, byte >> 4] where count < digits {
                guard nibble <= 9 else {
                    if nibble == 0x0F { return result }
                    throw VoWiFiError.malformedSMS
                }
                result.append(String(nibble))
                count += 1
            }
        }
        guard count == digits else { throw VoWiFiError.malformedSMS }
        return result
    }

    private static func decodeTimestamp(_ bytes: [UInt8]) -> Date {
        guard bytes.count == 7 else { return Date() }
        func swapped(_ byte: UInt8) -> Int { Int(byte & 0x0F) * 10 + Int(byte >> 4) }
        var components = DateComponents()
        let year = swapped(bytes[0])
        components.year = year >= 70 ? 1900 + year : 2000 + year
        components.month = swapped(bytes[1])
        components.day = swapped(bytes[2])
        components.hour = swapped(bytes[3])
        components.minute = swapped(bytes[4])
        components.second = swapped(bytes[5])
        let tzByte = bytes[6]
        let quarters = swapped(tzByte & 0xF7)
        let seconds = quarters * 15 * 60 * (tzByte & 0x08 != 0 ? -1 : 1)
        components.timeZone = TimeZone(secondsFromGMT: seconds)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private static func decodeUserData(
        _ bytes: [UInt8], length: Int, dcs: UInt8, hasUDH: Bool
    ) throws -> (body: String, concatenation: Concatenation?) {
        var payload = bytes
        var headerSeptets = 0
        var fillBits = 0
        var headerOctets = 0
        var concatenation: Concatenation?
        if hasUDH {
            guard let headerLengthByte = payload.first else { throw VoWiFiError.malformedSMS }
            let headerLength = Int(headerLengthByte) + 1
            guard headerLength <= payload.count else { throw VoWiFiError.malformedSMS }
            headerOctets = headerLength
            headerSeptets = (headerLength * 8 + 6) / 7
            fillBits = (7 - (headerLength * 8) % 7) % 7
            concatenation = parseConcatenationHeader(Array(payload.prefix(headerLength)))
            payload.removeFirst(headerLength)
        }
        switch alphabet(for: dcs) {
        case 2:
            let octets = length - headerOctets
            guard octets >= 0, octets <= payload.count, octets.isMultiple(of: 2) else {
                throw VoWiFiError.malformedSMS
            }
            var units: [UInt16] = []
            for index in stride(from: 0, to: octets, by: 2) {
                units.append(UInt16(payload[index]) << 8 | UInt16(payload[index + 1]))
            }
            return (String(decoding: units, as: UTF16.self), concatenation)
        case 1:
            let octets = length - headerOctets
            guard octets >= 0, octets <= payload.count else { throw VoWiFiError.malformedSMS }
            return (String(decoding: payload.prefix(octets), as: UTF8.self), concatenation)
        default:
            let septetCount = length - headerSeptets
            guard septetCount >= 0 else { throw VoWiFiError.malformedSMS }
            return (
                decodeGSM7(unpackSeptets(payload, count: septetCount, bitOffset: fillBits)),
                concatenation
            )
        }
    }

    private static func alphabet(for dcs: UInt8) -> UInt8 {
        if dcs & 0xC0 == 0 { return (dcs >> 2) & 0x03 }
        switch dcs & 0xF0 {
        case 0xE0: return 2
        case 0xF0: return dcs & 0x04 == 0 ? 0 : 1
        default: return 0
        }
    }

    private static func parseConcatenationHeader(_ header: [UInt8]) -> Concatenation? {
        guard !header.isEmpty, Int(header[0]) + 1 <= header.count else { return nil }
        var offset = 1
        let end = Int(header[0]) + 1
        while offset + 2 <= end {
            let identifier = header[offset]
            let length = Int(header[offset + 1])
            offset += 2
            guard offset + length <= end else { return nil }
            if identifier == 0x00, length == 3 {
                return Concatenation(
                    reference: UInt16(header[offset]),
                    total: Int(header[offset + 1]), part: Int(header[offset + 2])
                )
            }
            if identifier == 0x08, length == 4 {
                return Concatenation(
                    reference: UInt16(header[offset]) << 8 | UInt16(header[offset + 1]),
                    total: Int(header[offset + 2]), part: Int(header[offset + 3])
                )
            }
            offset += length
        }
        return nil
    }

    private static func unpackSeptets(_ data: [UInt8], count: Int, bitOffset: Int) -> [UInt8] {
        var output: [UInt8] = []
        for index in 0..<count {
            let bitPosition = bitOffset + index * 7
            let bytePosition = bitPosition / 8
            let shift = bitPosition % 8
            guard bytePosition < data.count else { break }
            var value = (data[bytePosition] >> shift) & 0x7F
            if shift > 1, bytePosition + 1 < data.count {
                value |= (data[bytePosition + 1] << (8 - shift)) & 0x7F
            }
            output.append(value)
        }
        return output
    }

    private static func decodeGSM7(_ septets: [UInt8]) -> String {
        let alphabet: [Character] = Array(
            "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{1B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
        )
        var output = ""
        var escaped = false
        let extensionTable: [UInt8: Character] = [
            0x0A: "\u{000C}", 0x14: "^", 0x28: "{", 0x29: "}",
            0x2F: "\\", 0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€"
        ]
        for value in septets {
            if escaped {
                output.append(extensionTable[value] ?? "�")
                escaped = false
            } else if value == 0x1B {
                escaped = true
            } else if Int(value) < alphabet.count {
                output.append(alphabet[Int(value)])
            }
        }
        return output
    }
}
