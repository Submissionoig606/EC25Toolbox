import CryptoKit
import Foundation
import Network

struct VoWiFiChildSA: Equatable, Sendable {
    var localSPI: UInt32
    var remoteSPI: UInt32
    var encryptionKeyInitiator: Data
    var integrityKeyInitiator: Data
    var encryptionKeyResponder: Data
    var integrityKeyResponder: Data
}

struct VoWiFiIKESession: Sendable {
    var initiatorSPI: UInt64
    var responderSPI: UInt64
    var keys: IKEv2KeyMaterial
    var childSA: VoWiFiChildSA
    var innerAddress: String
    var pcscfAddresses: [String]
    var dnsAddresses: [String]
    var natDetected: Bool
    var channel: VoWiFiUDPChannel
    var ikeControl: VoWiFiIKEControlContext
    var nextMessageID: UInt32
    var establishedAt: Date
}

@MainActor
struct VoWiFiIKEClient {
    let simAccess: VoWiFiSIMAccess

    func connect(
        remoteAddress: String,
        identity: VoWiFiIdentity,
        progress: @escaping (VoWiFiPhase, String) -> Void
    ) async throws -> VoWiFiIKESession {
        var lastError: Error = VoWiFiError.transport(localized("vowifi.error.timeout"))
        for group in VoWiFiDHAgreement.preferredGroups {
            do {
                return try await connect(
                    remoteAddress: remoteAddress,
                    identity: identity,
                    dhGroup: group,
                    progress: progress
                )
            } catch is CancellationError {
                throw VoWiFiError.cancelled
            } catch let error as VoWiFiError where error == .cancelled {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func connect(
        remoteAddress: String,
        identity: VoWiFiIdentity,
        dhGroup: UInt16,
        progress: @escaping (VoWiFiPhase, String) -> Void
    ) async throws -> VoWiFiIKESession {
        let permanentNAI = "0\(identity.imsi)@nai.epc.mnc\(identity.mnc).mcc\(identity.mcc).3gppnetwork.org"
        progress(.connectingEPDG, localizedFormat("vowifi.log.ike_init_group", dhGroup))
        let channel = VoWiFiUDPChannel()
        var keepChannelOpen = false
        defer {
            if !keepChannelOpen {
                Task { await channel.close() }
            }
        }
        try await channel.connect(host: remoteAddress, port: 500)

        let agreement = try VoWiFiDHAgreement.make(group: dhGroup)
        let nonceI = try VoWiFiCrypto.randomData(count: 32)
        let spiBytes = try VoWiFiCrypto.randomData(count: 8)
        guard let initiatorSPI = spiBytes.uint64(at: 0), initiatorSPI != 0 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_spi"))
        }
        let sourceNATHash = natDetectionHash(
            initiatorSPI: initiatorSPI, responderSPI: 0,
            addressBytes: Data([0, 0, 0, 0]), port: 0
        )
        let remoteIPBytes: Data
        if let ipv4 = IPv4Address(remoteAddress) {
            remoteIPBytes = ipv4.rawValue
        } else if let ipv6 = IPv6Address(remoteAddress) {
            remoteIPBytes = ipv6.rawValue
        } else {
            throw VoWiFiError.epdgResolutionFailed(remoteAddress)
        }
        let destinationNATHash = natDetectionHash(
            initiatorSPI: initiatorSPI, responderSPI: 0,
            addressBytes: remoteIPBytes, port: 500
        )
        let initRequest = IKEv2.Message(
            header: IKEv2.Header(
                initiatorSPI: initiatorSPI, responderSPI: 0,
                nextPayload: .none, exchange: .ikeSAInit,
                flags: IKEv2.initiatorFlag, messageID: 0, length: 0
            ),
            payloads: [
                try IKEv2.securityAssociationPayload([IKEv2.defaultIKEProposal(dhGroup: dhGroup)]),
                IKEv2.keyExchangePayload(group: dhGroup, publicKey: agreement.publicKey),
                IKEv2.noncePayload(nonceI),
                IKEv2.notifyPayload(type: 16388, data: sourceNATHash),
                IKEv2.notifyPayload(type: 16389, data: destinationNATHash)
            ]
        )
        let initRequestWire = try initRequest.encoded()
        let initResponseWire = try await channel.exchange(initRequestWire, nonESPMarker: false)
        let initResponse = try IKEv2.Message.parse(initResponseWire)
        guard initResponse.header.initiatorSPI == initiatorSPI,
              initResponse.header.responderSPI != 0,
              initResponse.header.exchange == .ikeSAInit,
              initResponse.header.flags & 0x20 != 0 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_init_response"))
        }
        try validateNotifyErrors(initResponse.payloads)
        guard let selectedSAPayload = initResponse.payloads.first(where: { $0.type == .securityAssociation }),
              let keyExchange = initResponse.payloads.first(where: { $0.type == .keyExchange }),
              keyExchange.body.count > 4, keyExchange.body.uint16(at: 0) == dhGroup,
              let nonceRPayload = initResponse.payloads.first(where: { $0.type == .nonce }),
              nonceRPayload.body.count >= 16 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_init_payloads"))
        }
        let selectedProposals = try IKEv2.parseSecurityAssociation(selectedSAPayload)
        try validateIKEProposal(selectedProposals, dhGroup: dhGroup)
        let sharedSecret = try agreement.sharedSecret(peerPublicKey: Data(keyExchange.body.dropFirst(4)))
        let nonceR = nonceRPayload.body
        let responderSPI = initResponse.header.responderSPI
        let keys = try IKEv2KeyMaterial.derive(
            nonceI: nonceI, nonceR: nonceR, sharedSecret: sharedSecret,
            initiatorSPI: initiatorSPI, responderSPI: responderSPI
        )

        // RFC 3948 NAT-T framing is used for all IKE_AUTH and ESP datagrams.
        await channel.close()
        try await channel.connect(host: remoteAddress, port: 4500)
        progress(.authenticating, localized("vowifi.log.eap_start"))
        let childSPIData = try VoWiFiCrypto.randomData(count: 4)
        guard let localChildSPI = childSPIData.uint32(at: 0), localChildSPI != 0 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.child_spi"))
        }

        let initiatorIdentityPayload = IKEv2.identificationPayload(permanentNAI)
        var initialPayloads: [IKEv2.Payload] = [
            initiatorIdentityPayload,
            IKEv2.configurationRequestPayload(),
            try IKEv2.securityAssociationPayload([IKEv2.defaultESPProposal(spi: childSPIData)]),
            IKEv2.trafficSelectorPayload(initiator: true),
            IKEv2.trafficSelectorPayload(initiator: false)
        ]
        // Advertise EAP-only authentication when supported by the ePDG.
        initialPayloads.append(IKEv2.notifyPayload(type: 16417))
        var messageID: UInt32 = 1
        var responsePayloads = try await exchangeProtected(
            payloads: initialPayloads, messageID: messageID,
            initiatorSPI: initiatorSPI, responderSPI: responderSPI,
            keys: keys, channel: channel
        )
        messageID += 1
        var eapKeys: EAPAKAKeys?
        var responderIdentityBody: Data?
        var sentEAPAUTH = false

        for _ in 0..<12 {
            try validateNotifyErrors(responsePayloads)
            if let idr = responsePayloads.first(where: { $0.type == .identificationResponder }) {
                responderIdentityBody = idr.body
            }
            if let child = try parseChildSA(
                payloads: responsePayloads, localSPI: localChildSPI,
                nonceI: nonceI, nonceR: nonceR, skD: keys.skD
            ) {
                guard sentEAPAUTH, let eapKeys,
                      let responderIdentityBody,
                      let responderAUTH = responsePayloads.first(where: { $0.type == .authentication }) else {
                    throw VoWiFiError.ikeAuthenticationFailed
                }
                try verifyEAPResponderAUTH(
                    payload: responderAUTH, msk: eapKeys.msk,
                    initResponseWire: initResponseWire, nonceI: nonceI,
                    responderIdentityBody: responderIdentityBody, skPr: keys.skPr
                )
                let configuration = parseConfiguration(responsePayloads)
                guard let innerAddress = configuration.innerAddress else {
                    throw VoWiFiError.missingTunnelConfiguration
                }
                progress(.tunnelReady, localized("vowifi.log.tunnel_ready"))
                keepChannelOpen = true
                return VoWiFiIKESession(
                    initiatorSPI: initiatorSPI, responderSPI: responderSPI,
                    keys: keys, childSA: child, innerAddress: innerAddress,
                    pcscfAddresses: configuration.pcscf,
                    dnsAddresses: configuration.dns,
                    natDetected: true,
                    channel: channel,
                    ikeControl: VoWiFiIKEControlContext(
                        initiatorSPI: initiatorSPI, responderSPI: responderSPI,
                        keys: keys
                    ),
                    nextMessageID: messageID, establishedAt: Date()
                )
            }
            guard let eapPayload = responsePayloads.first(where: { $0.type == .eap }) else {
                throw VoWiFiError.ikeAuthenticationFailed
            }
            let request = try EAPAKAPacket.parse(eapPayload.body)
            if request.code == 4 { throw VoWiFiError.ikeAuthenticationFailed }
            if request.code == 3 {
                guard let eapKeys else { throw VoWiFiError.ikeAuthenticationFailed }
                let auth = makeEAPInitiatorAUTH(
                    msk: eapKeys.msk, initRequestWire: initRequestWire,
                    nonceR: nonceR, initiatorIdentityBody: initiatorIdentityPayload.body,
                    skPi: keys.skPi
                )
                responsePayloads = try await exchangeProtected(
                    payloads: [IKEv2.authenticationPayload(sharedKeyMIC: auth)],
                    messageID: messageID,
                    initiatorSPI: initiatorSPI, responderSPI: responderSPI,
                    keys: keys, channel: channel
                )
                sentEAPAUTH = true
                messageID += 1
                continue
            }

            let response: EAPAKAPacket
            if request.type == EAPAKA.typeIdentity || request.subtype == EAPAKA.subtypeIdentity {
                response = try EAPAKA.identityResponse(to: request, identity: permanentNAI)
            } else if request.type == EAPAKA.typeAKA, request.subtype == EAPAKA.subtypeChallenge {
                let vector = try EAPAKA.challengeVector(from: request)
                do {
                    let aka = try await simAccess.authenticate(
                        application: identity.source == .isim ? .isim : .usim,
                        rand: vector.rand, autn: vector.autn
                    )
                    let challenge = try EAPAKA.challengeResponse(
                        to: request, identity: permanentNAI, aka: aka
                    )
                    response = challenge.packet
                    eapKeys = challenge.keys
                } catch let VoWiFiError.akaSyncFailure(auts) {
                    response = try EAPAKA.synchronizationFailureResponse(to: request, auts: auts)
                }
            } else if request.type == EAPAKA.typeAKA, request.subtype == EAPAKA.subtypeNotification {
                response = try EAPAKA.notificationResponse(to: request, key: eapKeys?.authenticationKey)
            } else {
                throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.eap_request"))
            }
            responsePayloads = try await exchangeProtected(
                payloads: [IKEv2.Payload(type: .eap, body: try response.encoded())],
                messageID: messageID,
                initiatorSPI: initiatorSPI, responderSPI: responderSPI,
                keys: keys, channel: channel
            )
            messageID += 1
        }
        throw VoWiFiError.ikeAuthenticationFailed
    }

    private func natDetectionHash(
        initiatorSPI: UInt64,
        responderSPI: UInt64,
        addressBytes: Data,
        port: UInt16
    ) -> Data {
        var input = Data()
        input.appendUInt64(initiatorSPI)
        input.appendUInt64(responderSPI)
        input.append(addressBytes)
        input.appendUInt16(port)
        return Data(Insecure.SHA1.hash(data: input))
    }

    private func makeEAPInitiatorAUTH(
        msk: Data,
        initRequestWire: Data,
        nonceR: Data,
        initiatorIdentityBody: Data,
        skPi: Data
    ) -> Data {
        let identityMAC = VoWiFiCrypto.hmacSHA256(key: skPi, data: initiatorIdentityBody)
        return VoWiFiCrypto.hmacSHA256(
            key: msk, data: initRequestWire + nonceR + identityMAC
        )
    }

    private func verifyEAPResponderAUTH(
        payload: IKEv2.Payload,
        msk: Data,
        initResponseWire: Data,
        nonceI: Data,
        responderIdentityBody: Data,
        skPr: Data
    ) throws {
        guard payload.body.count == 36, payload.body[0] == 2 else {
            throw VoWiFiError.ikeAuthenticationFailed
        }
        let identityMAC = VoWiFiCrypto.hmacSHA256(key: skPr, data: responderIdentityBody)
        let expected = VoWiFiCrypto.hmacSHA256(
            key: msk, data: initResponseWire + nonceI + identityMAC
        )
        guard Data(payload.body.dropFirst(4)) == expected else {
            throw VoWiFiError.ikeAuthenticationFailed
        }
    }

    private func exchangeProtected(
        payloads: [IKEv2.Payload], messageID: UInt32,
        initiatorSPI: UInt64, responderSPI: UInt64,
        keys: IKEv2KeyMaterial, channel: VoWiFiUDPChannel
    ) async throws -> [IKEv2.Payload] {
        let header = IKEv2.Header(
            initiatorSPI: initiatorSPI, responderSPI: responderSPI,
            nextPayload: .encrypted, exchange: .ikeAuth,
            flags: IKEv2.initiatorFlag, messageID: messageID, length: 0
        )
        let request = try IKEv2ProtectedPayload.seal(
            payloads: payloads, header: header,
            encryptionKey: keys.skEi, integrityKey: keys.skAi
        )
        let responseWire = try await channel.exchange(request, nonESPMarker: true)
        let (responseHeader, responsePayloads) = try IKEv2ProtectedPayload.open(
            wire: responseWire, encryptionKey: keys.skEr, integrityKey: keys.skAr
        )
        guard responseHeader.initiatorSPI == initiatorSPI,
              responseHeader.responderSPI == responderSPI,
              responseHeader.exchange == .ikeAuth,
              responseHeader.messageID == messageID,
              responseHeader.flags & 0x20 != 0 else {
            throw VoWiFiError.malformedIKE(localized("vowifi.error.ike_auth_header"))
        }
        return responsePayloads
    }

    private func validateIKEProposal(_ proposals: [IKEv2.Proposal], dhGroup: UInt16) throws {
        guard proposals.count == 1, let proposal = proposals.first,
              proposal.protocolID == IKEv2.protocolIKE,
              proposal.transforms.contains(where: { $0.type == .encryption && $0.identifier == IKEv2.encrAESCBC }),
              proposal.transforms.contains(where: { $0.type == .prf && $0.identifier == IKEv2.prfHMACSHA256 }),
              proposal.transforms.contains(where: { $0.type == .integrity && $0.identifier == IKEv2.integHMACSHA256_128 }),
              proposal.transforms.contains(where: { $0.type == .dh && $0.identifier == dhGroup }) else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.ike_selected_proposal"))
        }
    }

    private func validateNotifyErrors(_ payloads: [IKEv2.Payload]) throws {
        for payload in payloads where payload.type == .notify {
            guard payload.body.count >= 4, let type = payload.body.uint16(at: 2) else { continue }
            if type < 16384 {
                if type == 24 { throw VoWiFiError.ikeAuthenticationFailed }
                throw VoWiFiError.malformedIKE(localizedFormat("vowifi.error.ike_notify", type))
            }
        }
    }

    private func parseChildSA(
        payloads: [IKEv2.Payload], localSPI: UInt32,
        nonceI: Data, nonceR: Data, skD: Data
    ) throws -> VoWiFiChildSA? {
        guard let saPayload = payloads.first(where: { $0.type == .securityAssociation }) else { return nil }
        let proposals = try IKEv2.parseSecurityAssociation(saPayload)
        guard proposals.count == 1, let selected = proposals.first,
              selected.protocolID == IKEv2.protocolESP, selected.spi.count == 4,
              let remoteSPI = selected.spi.uint32(at: 0),
              selected.transforms.contains(where: { $0.type == .encryption && $0.identifier == IKEv2.encrAESCBC }),
              selected.transforms.contains(where: { $0.type == .integrity && $0.identifier == IKEv2.integHMACSHA256_128 }) else {
            throw VoWiFiError.unsupportedIKETransform(localized("vowifi.error.child_proposal"))
        }
        let material = try VoWiFiCrypto.prfPlusSHA256(key: skD, seed: nonceI + nonceR, count: 96)
        return VoWiFiChildSA(
            localSPI: localSPI, remoteSPI: remoteSPI,
            encryptionKeyInitiator: Data(material[0..<16]),
            integrityKeyInitiator: Data(material[16..<48]),
            encryptionKeyResponder: Data(material[48..<64]),
            integrityKeyResponder: Data(material[64..<96])
        )
    }

    private func parseConfiguration(
        _ payloads: [IKEv2.Payload]
    ) -> (innerAddress: String?, pcscf: [String], dns: [String]) {
        guard let payload = payloads.first(where: { $0.type == .configuration }), payload.body.count >= 4 else {
            return (nil, [], [])
        }
        var offset = 4
        var innerAddress: String?
        var pcscf: [String] = []
        var dns: [String] = []
        while offset + 4 <= payload.body.count {
            guard let rawType = payload.body.uint16(at: offset), let length = payload.body.uint16(at: offset + 2),
                  offset + 4 + Int(length) <= payload.body.count else { break }
            let type = rawType & 0x7FFF
            let value = Data(payload.body[(offset + 4)..<(offset + 4 + Int(length))])
            if value.count == 4 {
                let address = value.map(String.init).joined(separator: ".")
                if type == 1 { innerAddress = address }
                if type == 3, !dns.contains(address) { dns.append(address) }
                if type == 20, !pcscf.contains(address) { pcscf.append(address) }
            }
            offset += 4 + Int(length)
        }
        return (innerAddress, pcscf, dns)
    }
}
