import Darwin
import Foundation
import Network

struct VoWiFiEPDGResolver {
    func resolve(configuration: VoWiFiCarrierConfiguration) async throws -> [String] {
        let host = configuration.epdgAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw VoWiFiError.epdgResolutionFailed(host) }
        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            guard Self.isUsableRemoteAddress(host) else {
                throw VoWiFiError.epdgResolutionFailed(host)
            }
            return [host]
        }

        for attempt in 0..<3 {
            let addresses = try await Self.resolveSystemAddresses(host: host)
                .filter(Self.isUsableRemoteAddress)
            if !addresses.isEmpty { return addresses }
            if attempt < 2 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw VoWiFiError.epdgResolutionFailed(host)
    }

    private static func resolveSystemAddresses(host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_DGRAM,
                ai_protocol: Int32(IPPROTO_UDP),
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            guard status == 0, let first = result else {
                throw VoWiFiError.epdgResolutionFailed(host)
            }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let entry = current {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                    &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    let address = String(
                        decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    if !addresses.contains(address) { addresses.append(address) }
                }
                current = entry.pointee.ai_next
            }
            guard !addresses.isEmpty else { throw VoWiFiError.epdgResolutionFailed(host) }
            return addresses
        }.value
    }

    /// A public or operator ePDG must never resolve to this Mac itself.
    /// Local DNS proxies can briefly return loopback placeholders while their
    /// upstream resolver is unavailable, so reject those values before IKE.
    private static func isUsableRemoteAddress(_ address: String) -> Bool {
        if let ipv4 = IPv4Address(address) {
            let octets = [UInt8](ipv4.rawValue)
            return octets.count == 4
                && octets != [0, 0, 0, 0]
                && octets[0] != 127
        }
        if let ipv6 = IPv6Address(address) {
            let octets = [UInt8](ipv6.rawValue)
            let isUnspecified = octets.allSatisfy { $0 == 0 }
            let isLoopback = octets.dropLast().allSatisfy { $0 == 0 }
                && octets.last == 1
            return !isUnspecified && !isLoopback
        }
        return false
    }
}

actor VoWiFiUDPChannel {
    private let helper = VoWiFiIKEHelperClient()
    private var channelID: String?
    private(set) var remoteHost = ""
    private(set) var remotePort: UInt16 = 0

    func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws {
        await close()
        guard [500, 4500].contains(port) else {
            throw VoWiFiError.transport(localized("vowifi.error.invalid_port"))
        }
        channelID = try await helper.open(host: host, port: port)
        remoteHost = host
        remotePort = port
    }

    func exchange(_ payload: Data, nonESPMarker: Bool, timeout: TimeInterval = 10) async throws -> Data {
        guard let channelID else { throw VoWiFiError.transport(localized("vowifi.error.udp_closed")) }
        var wire = Data()
        if nonESPMarker { wire.append(contentsOf: [0, 0, 0, 0]) }
        wire.append(payload)
        try await helper.send(channelID: channelID, payload: wire)
        let response = try await helper.receive(channelID: channelID, timeout: timeout)
        if response.count >= 4, response.prefix(4) == Data([0, 0, 0, 0]) {
            return Data(response.dropFirst(4))
        }
        return response
    }

    func sendDatagram(_ payload: Data) async throws {
        guard let channelID else { throw VoWiFiError.transport(localized("vowifi.error.udp_closed")) }
        try await helper.send(channelID: channelID, payload: payload)
    }

    func receiveDatagram(timeout: TimeInterval = 60) async throws -> Data {
        guard let channelID else { throw VoWiFiError.transport(localized("vowifi.error.udp_closed")) }
        return try await helper.receive(channelID: channelID, timeout: timeout)
    }

    func receiveDatagram() async throws -> Data {
        try await receiveDatagram(timeout: 300)
    }

    func close() async {
        if let channelID { await helper.close(channelID: channelID) }
        channelID = nil
        remoteHost = ""
        remotePort = 0
    }
}
