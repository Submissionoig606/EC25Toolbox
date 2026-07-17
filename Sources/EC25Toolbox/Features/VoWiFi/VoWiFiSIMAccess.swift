import Foundation

enum VoWiFiSIMApplication: String, Sendable {
    case usim
    case isim

    var aid: String {
        switch self {
        case .usim: "A0000000871002"
        case .isim: "A0000000871004"
        }
    }
}

struct VoWiFiAPDUResponse: Equatable, Sendable {
    var body: Data
    var sw1: UInt8
    var sw2: UInt8

    var succeeds: Bool { sw1 == 0x90 && sw2 == 0x00 }
    var status: String { String(format: "%02X%02X", sw1, sw2) }
}

/// Logical-channel SIM access used by both ISIM identity reads and AKA.
/// Every operation is routed through the existing native EC25 USB transport.
@MainActor
struct VoWiFiSIMAccess {
    unowned let store: ModemStore

    func withApplication<T>(
        _ application: VoWiFiSIMApplication,
        operation: (UInt8) async throws -> T
    ) async throws -> T {
        let lines = try await store.sendUnlogged("AT+CCHO=\"\(application.aid)\"", timeout: 10_000)
        let channel: UInt8
        do {
            channel = try parseESTKCCHOChannel(lines)
        } catch {
            throw VoWiFiError.isimUnavailable(error.localizedDescription)
        }
        do {
            let value = try await operation(channel)
            _ = try? await store.sendUnlogged("AT+CCHC=\(channel)", timeout: 5_000)
            return value
        } catch {
            _ = try? await store.sendUnlogged("AT+CCHC=\(channel)", timeout: 5_000)
            throw error
        }
    }

    func transmit(channel: UInt8, command: Data) async throws -> VoWiFiAPDUResponse {
        guard command.count >= 4 else { throw VoWiFiError.malformedAPDU }
        var bytes = [UInt8](command)
        bytes[0] = logicalChannelCLA(bytes[0], channel: channel)
        let hex = bytes.hexString
        let lines = try await store.sendUnlogged(
            "AT+CGLA=\(channel),\(hex.count),\"\(hex)\"",
            timeout: 12_000
        )
        let responseHex: String
        do {
            responseHex = try parseESTKAPDUResponse(lines, prefix: "+CGLA:")
        } catch {
            throw VoWiFiError.malformedAPDU
        }
        guard let responseData = Data(hexString: responseHex), responseData.count >= 2 else {
            throw VoWiFiError.malformedAPDU
        }
        let body = responseData.dropLast(2)
        var response = VoWiFiAPDUResponse(
            body: Data(body),
            sw1: responseData[responseData.count - 2],
            sw2: responseData[responseData.count - 1]
        )
        if response.sw1 == 0x6C {
            var corrected = bytes
            if corrected.count == 4 { corrected.append(response.sw2) }
            else { corrected[corrected.count - 1] = response.sw2 }
            return try await transmit(channel: channel, command: Data(corrected))
        }
        if response.sw1 == 0x61 || response.sw1 == 0x9F {
            let le = response.sw2
            let next = try await transmit(
                channel: channel,
                command: Data([bytes[0], 0xC0, 0x00, 0x00, le])
            )
            response.body.append(next.body)
            response.sw1 = next.sw1
            response.sw2 = next.sw2
        }
        return response
    }

    func readISIMIdentity() async throws -> VoWiFiIdentity {
        try await withApplication(.isim) { channel in
            let impi = try await readTransparentString(channel: channel, fileID: 0x6F02)
            let domain = try await readTransparentString(channel: channel, fileID: 0x6F03)
            let impus = try await readLinearFixedStrings(channel: channel, fileID: 0x6F04)
            guard !impi.isEmpty || !domain.isEmpty || !impus.isEmpty else {
                throw VoWiFiError.incompleteIdentity
            }
            return VoWiFiIdentity(
                impi: impi,
                impu: impus.first ?? "",
                realm: domain,
                source: .isim
            )
        }
    }

    /// Reads EF_AD (TS 31.102) so two-digit home-network MNCs are not
    /// incorrectly converted into a three-digit ePDG/IMS realm.
    func readMNCLength() async throws -> Int? {
        try await withApplication(.usim) { channel in
            _ = try await select(channel: channel, fileID: 0x6FAD)
            let response = try await transmit(
                channel: channel,
                command: Data([0x00, 0xB0, 0x00, 0x00, 0x00])
            )
            guard response.succeeds else { throw VoWiFiError.apduStatus(response.status) }
            guard response.body.count >= 4 else { return nil }
            let value = Int(response.body[3] & 0x0F)
            return value == 2 || value == 3 ? value : nil
        }
    }

    func authenticate(
        application: VoWiFiSIMApplication,
        rand: Data,
        autn: Data
    ) async throws -> VoWiFiAKAResult {
        guard rand.count == 16, autn.count == 16 else { throw VoWiFiError.malformedAPDU }
        return try await withApplication(application) { channel in
            var payload = Data([0x10])
            payload.append(rand)
            payload.append(0x10)
            payload.append(autn)
            var command = Data([0x00, 0x88, 0x00, 0x81, UInt8(payload.count)])
            command.append(payload)
            var response = try await transmit(channel: channel, command: command)
            if !response.succeeds {
                command.append(0x00)
                response = try await transmit(channel: channel, command: command)
            }
            guard response.succeeds else { throw VoWiFiError.apduStatus(response.status) }
            return try parseAKAResponse(response.body)
        }
    }

    private func readTransparentString(channel: UInt8, fileID: UInt16) async throws -> String {
        let selected = try await select(channel: channel, fileID: fileID)
        let size = fcpFileSize(selected.body) ?? 255
        let length = UInt8(size >= 256 ? 0 : size)
        let response = try await transmit(
            channel: channel,
            command: Data([0x00, 0xB0, 0x00, 0x00, length])
        )
        guard response.succeeds else { throw VoWiFiError.apduStatus(response.status) }
        return decodeISIMString(response.body)
    }

    private func readLinearFixedStrings(channel: UInt8, fileID: UInt16) async throws -> [String] {
        let selected = try await select(channel: channel, fileID: fileID)
        let recordLength = fcpRecordLength(selected.body) ?? 255
        var values: [String] = []
        for record in 1...16 {
            let response = try await transmit(
                channel: channel,
                command: Data([0x00, 0xB2, UInt8(record), 0x04, UInt8(recordLength >= 256 ? 0 : recordLength)])
            )
            if response.sw1 == 0x6A && (response.sw2 == 0x82 || response.sw2 == 0x83) { break }
            guard response.succeeds else { throw VoWiFiError.apduStatus(response.status) }
            let value = decodeISIMString(response.body)
            if !value.isEmpty, !values.contains(value) { values.append(value) }
        }
        return values
    }

    private func select(channel: UInt8, fileID: UInt16) async throws -> VoWiFiAPDUResponse {
        let response = try await transmit(
            channel: channel,
            command: Data([0x00, 0xA4, 0x00, 0x04, 0x02, UInt8(fileID >> 8), UInt8(fileID & 0xFF)])
        )
        guard response.succeeds else { throw VoWiFiError.apduStatus(response.status) }
        return response
    }
}

private func logicalChannelCLA(_ cla: UInt8, channel: UInt8) -> UInt8 {
    if channel < 4 { return (cla & 0xFC) | channel }
    return (cla & 0xB0) | 0x40 | (channel - 4)
}

private func decodeISIMString(_ data: Data) -> String {
    var bytes = [UInt8](data)
    while bytes.last == 0xFF || bytes.last == 0x00 { bytes.removeLast() }
    guard !bytes.isEmpty else { return "" }
    if let length = berLength(bytes), length.header + length.value <= bytes.count {
        bytes = Array(bytes[length.header..<(length.header + length.value)])
    }
    return String(bytes: bytes, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func berLength(_ bytes: [UInt8]) -> (header: Int, value: Int)? {
    guard let first = bytes.first else { return nil }
    if first < 0x80 { return (1, Int(first)) }
    let count = Int(first & 0x7F)
    guard count > 0, count <= 2, bytes.count > count else { return nil }
    var value = 0
    for byte in bytes[1...count] { value = (value << 8) | Int(byte) }
    return (count + 1, value)
}

private func fcpFileSize(_ data: Data) -> Int? {
    let bytes = [UInt8](data)
    for index in bytes.indices where bytes[index] == 0x80 || bytes[index] == 0x81 {
        guard index + 1 < bytes.count else { continue }
        let length = Int(bytes[index + 1])
        guard (1...2).contains(length), index + 2 + length <= bytes.count else { continue }
        return bytes[(index + 2)..<(index + 2 + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
    return nil
}

private func fcpRecordLength(_ data: Data) -> Int? {
    let bytes = [UInt8](data)
    guard let index = bytes.firstIndex(of: 0x82), index + 4 < bytes.count else { return nil }
    let length = Int(bytes[index + 1])
    guard length >= 5, index + 2 + length <= bytes.count else { return nil }
    let descriptor = Array(bytes[(index + 2)..<(index + 2 + length)])
    return Int(descriptor[descriptor.count - 3]) << 8 | Int(descriptor[descriptor.count - 2])
}

func parseVoWiFiAKAResponse(_ data: Data) throws -> VoWiFiAKAResult {
    try parseAKAResponse(data)
}

private func parseAKAResponse(_ data: Data) throws -> VoWiFiAKAResult {
    // CK, IK and RES are opaque key material and may legitimately contain
    // 0xFF. Never strip bytes from the authentication response.
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { throw VoWiFiError.malformedAPDU }
    let tag = bytes[0]
    if tag == 0xDC {
        let length = Int(bytes[1])
        guard length == 14, bytes.count >= 2 + length else { throw VoWiFiError.malformedAPDU }
        throw VoWiFiError.akaSyncFailure(Data(bytes[2..<(2 + length)]))
    }
    if tag == 0xDD { throw VoWiFiError.akaMACFailure }
    guard tag == 0xDB else { throw VoWiFiError.malformedAPDU }
    var offset = 1
    func takeField(expectedLength: Int? = nil) throws -> Data {
        guard offset < bytes.count else { throw VoWiFiError.malformedAPDU }
        let length = Int(bytes[offset])
        offset += 1
        guard length > 0, expectedLength == nil || length == expectedLength,
              offset + length <= bytes.count else { throw VoWiFiError.malformedAPDU }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }
    let res = try takeField()
    guard (4...16).contains(res.count) else { throw VoWiFiError.malformedAPDU }
    if bytes.count - offset == 32 {
        return VoWiFiAKAResult(
            res: res,
            ck: Data(bytes[offset..<(offset + 16)]),
            ik: Data(bytes[(offset + 16)..<(offset + 32)]),
            auts: nil
        )
    }
    let ck = try takeField(expectedLength: 16)
    let ik = try takeField(expectedLength: 16)
    return VoWiFiAKAResult(res: res, ck: ck, ik: ik, auts: nil)
}

extension Data {
    init?(hexString: String) {
        let clean = hexString.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2), clean.allSatisfy(\.isHexDigit) else { return nil }
        var output = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<end], radix: 16) else { return nil }
            output.append(byte)
            index = end
        }
        self = output
    }
}

extension Collection where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
