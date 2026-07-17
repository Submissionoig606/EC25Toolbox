import Foundation

/// Small, application-contained TCP endpoint for IMS transports. It handles a
/// single ordered connection, retransmits the SYN/data/FIN transaction, and
/// never exposes the tunnel as a system network interface.
actor VoWiFiTCPConnection {
    private enum State: Equatable { case idle, synSent, established, finWait, closed }

    private let dataPlane: VoWiFiDataPlane
    private let remoteAddress: String
    private let remotePort: UInt16
    private let localPort: UInt16
    private var state: State = .idle
    private var handlerID: UUID?
    private var sendNext: UInt32 = 0
    private var receiveNext: UInt32 = 0
    private var lastAcknowledgement: UInt32 = 0
    private var receiveBuffer = Data()
    private var reset = false

    init(dataPlane: VoWiFiDataPlane, remoteAddress: String, remotePort: UInt16) throws {
        self.dataPlane = dataPlane
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        let random = try VoWiFiCrypto.randomData(count: 2).uint16(at: 0) ?? 0
        localPort = UInt16(49152 + Int(random) % 16000)
    }

    deinit { }

    func connect() async throws {
        guard state == .idle || state == .closed else { return }
        let initial = try VoWiFiCrypto.randomData(count: 4).uint32(at: 0) ?? 1
        sendNext = initial == UInt32.max ? 1 : initial
        receiveNext = 0
        reset = false
        if handlerID == nil {
            handlerID = await dataPlane.addTCPHandler { [weak self] segment in
                await self?.accept(segment)
            }
        }
        state = .synSent
        try await retryingSend(
            sequence: sendNext, acknowledgement: 0,
            flags: VoWiFiTCPSegment.syn, payload: Data(),
            expectedAcknowledgement: sendNext &+ 1
        )
        guard receiveNext != 0 else { throw VoWiFiError.transport(localized("vowifi.error.tcp_handshake")) }
        sendNext &+= 1
        try await transmit(flags: VoWiFiTCPSegment.ack)
        state = .established
    }

    func write(_ data: Data) async throws {
        guard state == .established else {
            throw VoWiFiError.transport(localized("vowifi.error.tcp_closed"))
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 1200, data.count)
            let chunk = Data(data[offset..<end])
            let expected = sendNext &+ UInt32(chunk.count)
            try await retryingSend(
                sequence: sendNext, acknowledgement: receiveNext,
                flags: VoWiFiTCPSegment.ack | VoWiFiTCPSegment.psh,
                payload: chunk, expectedAcknowledgement: expected
            )
            sendNext = expected
            offset = end
        }
    }

    func read(timeout: Duration = .seconds(30)) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if reset { throw VoWiFiError.transport(localized("vowifi.error.tcp_reset")) }
            if !receiveBuffer.isEmpty {
                let value = receiveBuffer
                receiveBuffer.removeAll(keepingCapacity: true)
                return value
            }
            if state == .closed { return Data() }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VoWiFiError.transport(localized("vowifi.error.timeout"))
    }

    func close() async {
        if state == .established {
            state = .finWait
            let expected = sendNext &+ 1
            try? await retryingSend(
                sequence: sendNext, acknowledgement: receiveNext,
                flags: VoWiFiTCPSegment.fin | VoWiFiTCPSegment.ack,
                payload: Data(), expectedAcknowledgement: expected
            )
            sendNext = expected
        }
        state = .closed
        if let handlerID {
            await dataPlane.removeTCPHandler(handlerID)
            self.handlerID = nil
        }
    }

    private func accept(_ segment: VoWiFiTCPSegment) async {
        guard segment.sourceAddress == remoteAddress,
              segment.sourcePort == remotePort,
              segment.destinationPort == localPort else { return }
        if segment.flags & VoWiFiTCPSegment.rst != 0 {
            reset = true
            state = .closed
            return
        }
        if state == .synSent,
           segment.flags & (VoWiFiTCPSegment.syn | VoWiFiTCPSegment.ack)
                == (VoWiFiTCPSegment.syn | VoWiFiTCPSegment.ack),
           segment.acknowledgement == sendNext &+ 1 {
            lastAcknowledgement = segment.acknowledgement
            receiveNext = segment.sequence &+ 1
            return
        }
        if segment.flags & VoWiFiTCPSegment.ack != 0 {
            lastAcknowledgement = max(lastAcknowledgement, segment.acknowledgement)
        }
        if !segment.payload.isEmpty {
            if segment.sequence == receiveNext {
                receiveBuffer.append(segment.payload)
                receiveNext &+= UInt32(segment.payload.count)
            }
            try? await transmit(flags: VoWiFiTCPSegment.ack)
        }
        if segment.flags & VoWiFiTCPSegment.fin != 0 {
            if segment.sequence == receiveNext { receiveNext &+= 1 }
            try? await transmit(flags: VoWiFiTCPSegment.ack)
            state = .closed
        }
    }

    private func retryingSend(
        sequence: UInt32,
        acknowledgement: UInt32,
        flags: UInt8,
        payload: Data,
        expectedAcknowledgement: UInt32
    ) async throws {
        for attempt in 0..<4 {
            try await dataPlane.sendTCP(
                to: remoteAddress, sourcePort: localPort, destinationPort: remotePort,
                sequence: sequence, acknowledgement: acknowledgement,
                flags: flags, payload: payload
            )
            let deadline = ContinuousClock.now + .seconds(1 << attempt)
            while ContinuousClock.now < deadline {
                if reset { throw VoWiFiError.transport(localized("vowifi.error.tcp_reset")) }
                if lastAcknowledgement >= expectedAcknowledgement { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw VoWiFiError.transport(localized("vowifi.error.tcp_timeout"))
    }

    private func transmit(flags: UInt8) async throws {
        try await dataPlane.sendTCP(
            to: remoteAddress, sourcePort: localPort, destinationPort: remotePort,
            sequence: sendNext, acknowledgement: receiveNext, flags: flags
        )
    }
}
