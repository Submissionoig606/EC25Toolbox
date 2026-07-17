import Foundation

struct VoWiFiUDPDatagram: Equatable, Sendable {
    var sourceAddress: String
    var destinationAddress: String
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: Data
}

struct VoWiFiTCPSegment: Equatable, Sendable {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10

    var sourceAddress: String
    var destinationAddress: String
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgement: UInt32
    var flags: UInt8
    var window: UInt16
    var payload: Data
}

enum VoWiFiIPv4 {
    struct ParsedPacket: Sendable {
        var sourceAddress: String
        var destinationAddress: String
        var `protocol`: UInt8
        var payload: Data
    }

    static func udpPacket(
        sourceAddress: String,
        destinationAddress: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        identification: UInt16
    ) throws -> Data {
        guard isAddress(sourceAddress), isAddress(destinationAddress),
              payload.count + 28 <= Int(UInt16.max) else {
            throw VoWiFiError.transport(localized("vowifi.error.ip_address"))
        }
        let udp = try udpSegment(
            sourcePort: sourcePort, destinationPort: destinationPort, payload: payload
        )
        return try packet(
            sourceAddress: sourceAddress, destinationAddress: destinationAddress,
            protocol: 17, payload: udp, identification: identification
        )
    }

    static func isAddress(_ address: String) -> Bool { ipv4Bytes(address) != nil }

    static func packet(
        sourceAddress: String,
        destinationAddress: String,
        protocol protocolNumber: UInt8,
        payload: Data,
        identification: UInt16
    ) throws -> Data {
        guard let source = ipv4Bytes(sourceAddress), let destination = ipv4Bytes(destinationAddress),
              payload.count + 20 <= Int(UInt16.max) else {
            throw VoWiFiError.transport(localized("vowifi.error.ip_address"))
        }
        var header = Data([0x45, 0x00])
        header.appendUInt16(UInt16(20 + payload.count))
        header.appendUInt16(identification)
        header.appendUInt16(0x4000)
        header.append(contentsOf: [64, protocolNumber])
        header.appendUInt16(0)
        header.append(contentsOf: source)
        header.append(contentsOf: destination)
        let checksum = internetChecksum(header)
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)
        header.append(payload)
        return header
    }

    static func udpSegment(sourcePort: UInt16, destinationPort: UInt16, payload: Data) throws -> Data {
        guard payload.count + 8 <= Int(UInt16.max) else {
            throw VoWiFiError.transport(localized("vowifi.error.udp_packet"))
        }
        var udp = Data()
        udp.appendUInt16(sourcePort)
        udp.appendUInt16(destinationPort)
        udp.appendUInt16(UInt16(payload.count + 8))
        udp.appendUInt16(0)
        udp.append(payload)
        return udp
    }

    static func parseUDP(_ packet: Data) throws -> VoWiFiUDPDatagram {
        let parsed = try parse(packet)
        guard parsed.protocol == 17 else {
            throw VoWiFiError.transport(localized("vowifi.error.udp_packet"))
        }
        return try parseUDPSegment(
            parsed.payload, sourceAddress: parsed.sourceAddress,
            destinationAddress: parsed.destinationAddress
        )
    }

    static func parse(_ packet: Data) throws -> ParsedPacket {
        guard packet.count >= 20, packet[0] >> 4 == 4,
              let totalLength = packet.uint16(at: 2), Int(totalLength) <= packet.count else {
            throw VoWiFiError.transport(localized("vowifi.error.ip_packet"))
        }
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard headerLength >= 20, headerLength <= Int(totalLength) else {
            throw VoWiFiError.transport(localized("vowifi.error.ip_packet"))
        }
        return ParsedPacket(
            sourceAddress: packet[12..<16].map(String.init).joined(separator: "."),
            destinationAddress: packet[16..<20].map(String.init).joined(separator: "."),
            protocol: packet[9],
            payload: Data(packet[headerLength..<Int(totalLength)])
        )
    }

    static func parseUDPSegment(
        _ segment: Data, sourceAddress: String, destinationAddress: String
    ) throws -> VoWiFiUDPDatagram {
        guard segment.count >= 8,
              let sourcePort = segment.uint16(at: 0),
              let destinationPort = segment.uint16(at: 2),
              let udpLength = segment.uint16(at: 4),
              udpLength >= 8, Int(udpLength) <= segment.count else {
            throw VoWiFiError.transport(localized("vowifi.error.udp_packet"))
        }
        return VoWiFiUDPDatagram(
            sourceAddress: sourceAddress, destinationAddress: destinationAddress,
            sourcePort: sourcePort, destinationPort: destinationPort,
            payload: Data(segment[8..<Int(udpLength)])
        )
    }

    static func tcpPacket(
        sourceAddress: String,
        destinationAddress: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgement: UInt32,
        flags: UInt8,
        window: UInt16,
        payload: Data,
        identification: UInt16
    ) throws -> Data {
        guard let source = ipv4Bytes(sourceAddress), let destination = ipv4Bytes(destinationAddress),
              payload.count + 40 <= Int(UInt16.max) else {
            throw VoWiFiError.transport(localized("vowifi.error.tcp_packet"))
        }
        var segment = Data()
        segment.appendUInt16(sourcePort)
        segment.appendUInt16(destinationPort)
        segment.appendUInt32(sequence)
        segment.appendUInt32(acknowledgement)
        segment.append(5 << 4)
        segment.append(flags)
        segment.appendUInt16(window)
        segment.appendUInt16(0)
        segment.appendUInt16(0)
        segment.append(payload)
        var pseudo = Data(source + destination)
        pseudo.append(contentsOf: [0, 6])
        pseudo.appendUInt16(UInt16(segment.count))
        pseudo.append(segment)
        let checksum = internetChecksum(pseudo)
        segment[16] = UInt8(checksum >> 8)
        segment[17] = UInt8(checksum & 0xFF)
        return try packet(
            sourceAddress: sourceAddress, destinationAddress: destinationAddress,
            protocol: 6, payload: segment, identification: identification
        )
    }

    static func parseTCPSegment(
        _ segment: Data, sourceAddress: String, destinationAddress: String
    ) throws -> VoWiFiTCPSegment {
        guard segment.count >= 20,
              let sourcePort = segment.uint16(at: 0),
              let destinationPort = segment.uint16(at: 2),
              let sequence = segment.uint32(at: 4),
              let acknowledgement = segment.uint32(at: 8),
              let window = segment.uint16(at: 14) else {
            throw VoWiFiError.transport(localized("vowifi.error.tcp_packet"))
        }
        let headerLength = Int(segment[12] >> 4) * 4
        guard headerLength >= 20, headerLength <= segment.count else {
            throw VoWiFiError.transport(localized("vowifi.error.tcp_packet"))
        }
        return VoWiFiTCPSegment(
            sourceAddress: sourceAddress, destinationAddress: destinationAddress,
            sourcePort: sourcePort, destinationPort: destinationPort,
            sequence: sequence, acknowledgement: acknowledgement,
            flags: segment[13], window: window,
            payload: Data(segment[headerLength...])
        )
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        let components = address.split(separator: ".")
        guard components.count == 4 else { return nil }
        let bytes = components.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            sum += UInt32(data[index]) << 8 | UInt32(data[index + 1])
            index += 2
        }
        if index < data.count { sum += UInt32(data[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}

actor VoWiFiDataPlane {
    typealias DatagramHandler = @Sendable (VoWiFiUDPDatagram) async -> Void
    typealias TCPHandler = @Sendable (VoWiFiTCPSegment) async -> Void
    typealias FailureHandler = @Sendable (Error) async -> Void

    private let innerAddress: String
    private let channel: VoWiFiUDPChannel
    private let esp: VoWiFiESPContext
    private let ikeControl: VoWiFiIKEControlContext
    private var identification: UInt16 = 1
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var handlers: [UUID: DatagramHandler] = [:]
    private var tcpHandlers: [UUID: TCPHandler] = [:]
    private var failureHandler: FailureHandler?
    private var imsIPSec: IMSIPSecContext?

    init(session: VoWiFiIKESession) {
        innerAddress = session.innerAddress
        channel = session.channel
        esp = VoWiFiESPContext(sa: session.childSA)
        ikeControl = session.ikeControl
    }

    deinit {
        receiveTask?.cancel()
        keepaliveTask?.cancel()
    }

    func start(failureHandler: FailureHandler? = nil) {
        guard receiveTask == nil else { return }
        self.failureHandler = failureHandler
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                try? await self.channel.sendDatagram(Data([0xFF]))
            }
        }
    }

    func stop() async {
        receiveTask?.cancel()
        keepaliveTask?.cancel()
        receiveTask = nil
        keepaliveTask = nil
        handlers.removeAll()
        tcpHandlers.removeAll()
        await channel.close()
    }

    func addHandler(_ handler: @escaping DatagramHandler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func removeHandler(_ id: UUID) {
        handlers[id] = nil
    }

    func addTCPHandler(_ handler: @escaping TCPHandler) -> UUID {
        let id = UUID()
        tcpHandlers[id] = handler
        return id
    }

    func removeTCPHandler(_ id: UUID) {
        tcpHandlers[id] = nil
    }

    func installIMSIPSec(_ context: IMSIPSecContext?) {
        imsIPSec = context
    }

    func sendUDP(
        to address: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) async throws {
        let packet = try VoWiFiIPv4.udpPacket(
            sourceAddress: innerAddress, destinationAddress: address,
            sourcePort: sourcePort, destinationPort: destinationPort,
            payload: payload, identification: identification
        )
        identification &+= 1
        let encrypted = try await esp.seal(innerPacket: packet)
        try await channel.sendDatagram(encrypted)
    }

    func sendSecureIMSUDP(
        to address: String,
        payload: Data
    ) async throws {
        guard let imsIPSec else {
            throw VoWiFiError.transport(localized("vowifi.error.ims_security_not_ready"))
        }
        let ports = await imsIPSec.ports()
        let udp = try VoWiFiIPv4.udpSegment(
            sourcePort: ports.local, destinationPort: ports.remote, payload: payload
        )
        let imsESP = try await imsIPSec.seal(udpSegment: udp)
        let packet = try VoWiFiIPv4.packet(
            sourceAddress: innerAddress, destinationAddress: address,
            protocol: 50, payload: imsESP, identification: identification
        )
        identification &+= 1
        try await channel.sendDatagram(try await esp.seal(innerPacket: packet))
    }

    func sendTCP(
        to address: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgement: UInt32,
        flags: UInt8,
        window: UInt16 = 65_535,
        payload: Data = Data()
    ) async throws {
        let packet = try VoWiFiIPv4.tcpPacket(
            sourceAddress: innerAddress, destinationAddress: address,
            sourcePort: sourcePort, destinationPort: destinationPort,
            sequence: sequence, acknowledgement: acknowledgement,
            flags: flags, window: window, payload: payload,
            identification: identification
        )
        identification &+= 1
        try await channel.sendDatagram(try await esp.seal(innerPacket: packet))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let datagram = try await channel.receiveDatagram()
                if datagram == Data([0xFF]) { continue }
                if datagram.count >= 4, datagram.prefix(4) == Data([0, 0, 0, 0]) {
                    if let response = try await ikeControl.response(
                        to: Data(datagram.dropFirst(4))
                    ) {
                        var framed = Data([0, 0, 0, 0])
                        framed.append(response)
                        try await channel.sendDatagram(framed)
                    }
                    continue
                }
                let opened = try await esp.open(datagram)
                guard opened.nextHeader == 4 else { continue }
                let parsed = try VoWiFiIPv4.parse(opened.innerPacket)
                if parsed.protocol == 50, let imsIPSec {
                    let segment = try await imsIPSec.open(parsed.payload)
                    let udp = try VoWiFiIPv4.parseUDPSegment(
                        segment,
                        sourceAddress: parsed.sourceAddress,
                        destinationAddress: parsed.destinationAddress
                    )
                    for handler in handlers.values { await handler(udp) }
                } else if parsed.protocol == 17 {
                    let udp = try VoWiFiIPv4.parseUDPSegment(
                        parsed.payload,
                        sourceAddress: parsed.sourceAddress,
                        destinationAddress: parsed.destinationAddress
                    )
                    for handler in handlers.values { await handler(udp) }
                } else if parsed.protocol == 6 {
                    let tcp = try VoWiFiIPv4.parseTCPSegment(
                        parsed.payload,
                        sourceAddress: parsed.sourceAddress,
                        destinationAddress: parsed.destinationAddress
                    )
                    for handler in tcpHandlers.values { await handler(tcp) }
                } else {
                    continue
                }
            } catch is CancellationError {
                return
            } catch {
                if let failureHandler { await failureHandler(error) }
                return
            }
        }
    }
}
