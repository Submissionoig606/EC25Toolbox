import Foundation

actor VoWiFiDNSResolver {
    private let dataPlane: VoWiFiDataPlane
    private var responses: [UInt16: Data] = [:]

    init(dataPlane: VoWiFiDataPlane) {
        self.dataPlane = dataPlane
    }

    func resolveIPv4(host: String, server: String) async throws -> String {
        if VoWiFiIPv4.isAddress(host) { return host }
        let identifierData = try VoWiFiCrypto.randomData(count: 2)
        guard let identifier = identifierData.uint16(at: 0) else {
            throw VoWiFiError.transport(localized("vowifi.error.dns_response"))
        }
        let sourcePort = UInt16(49152 + Int(identifier) % 16000)
        let handler = await dataPlane.addHandler { [weak self] datagram in
            guard datagram.destinationPort == sourcePort,
                  datagram.sourceAddress == server else { return }
            await self?.accept(datagram.payload, identifier: identifier)
        }
        do {
            try await dataPlane.sendUDP(
                to: server, sourcePort: sourcePort, destinationPort: 53,
                payload: try Self.query(identifier: identifier, host: host)
            )
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if let response = responses.removeValue(forKey: identifier) {
                    let address = try Self.firstIPv4(response, identifier: identifier)
                    await dataPlane.removeHandler(handler)
                    return address
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw VoWiFiError.transport(localizedFormat("vowifi.error.dns_timeout", host))
        } catch {
            await dataPlane.removeHandler(handler)
            throw error
        }
    }

    private func accept(_ data: Data, identifier: UInt16) {
        guard data.uint16(at: 0) == identifier else { return }
        responses[identifier] = data
    }

    private static func query(identifier: UInt16, host: String) throws -> Data {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else {
            throw VoWiFiError.transport(localized("vowifi.error.dns_name"))
        }
        var output = Data()
        output.appendUInt16(identifier)
        output.appendUInt16(0x0100)
        output.appendUInt16(1)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0)
        for label in labels {
            output.append(UInt8(label.utf8.count))
            output.append(contentsOf: label.utf8)
        }
        output.append(0)
        output.appendUInt16(1)
        output.appendUInt16(1)
        return output
    }

    private static func firstIPv4(_ data: Data, identifier: UInt16) throws -> String {
        guard data.count >= 12, data.uint16(at: 0) == identifier,
              let flags = data.uint16(at: 2), flags & 0x8000 != 0, flags & 0x000F == 0,
              let questions = data.uint16(at: 4), let answers = data.uint16(at: 6) else {
            throw VoWiFiError.transport(localized("vowifi.error.dns_response"))
        }
        var offset = 12
        for _ in 0..<questions {
            offset = try skipName(data, offset: offset)
            guard offset + 4 <= data.count else { throw VoWiFiError.transport(localized("vowifi.error.dns_response")) }
            offset += 4
        }
        for _ in 0..<answers {
            offset = try skipName(data, offset: offset)
            guard offset + 10 <= data.count,
                  let type = data.uint16(at: offset),
                  let dnsClass = data.uint16(at: offset + 2),
                  let length = data.uint16(at: offset + 8),
                  offset + 10 + Int(length) <= data.count else {
                throw VoWiFiError.transport(localized("vowifi.error.dns_response"))
            }
            let valueOffset = offset + 10
            if type == 1, dnsClass == 1, length == 4 {
                return data[valueOffset..<(valueOffset + 4)].map(String.init).joined(separator: ".")
            }
            offset = valueOffset + Int(length)
        }
        throw VoWiFiError.transport(localized("vowifi.error.dns_no_address"))
    }

    private static func skipName(_ data: Data, offset start: Int) throws -> Int {
        var offset = start
        var labels = 0
        while offset < data.count, labels < 128 {
            let length = Int(data[offset])
            if length & 0xC0 == 0xC0 {
                guard offset + 2 <= data.count else { break }
                return offset + 2
            }
            offset += 1
            if length == 0 { return offset }
            guard length <= 63, offset + length <= data.count else { break }
            offset += length
            labels += 1
        }
        throw VoWiFiError.transport(localized("vowifi.error.dns_response"))
    }
}
