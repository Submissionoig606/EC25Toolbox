import Foundation
import Testing
@testable import EC25Toolbox

@Suite("VoWiFi protocol primitives")
struct VoWiFiTests {
    @Test("USIM MNC length controls 3GPP realm construction")
    func carrierConfiguration() throws {
        let twoDigit = try VoWiFiCarrierConfiguration.derived(
            imsi: "460011234567890", mncLength: 2
        )
        #expect(twoDigit.mcc == "460")
        #expect(twoDigit.mnc == "001")
        #expect(twoDigit.epdgAddress == "epdg.epc.mnc001.mcc460.pub.3gppnetwork.org")
        let threeDigit = try VoWiFiCarrierConfiguration.derived(
            imsi: "310260123456789", mncLength: 3
        )
        #expect(threeDigit.mnc == "260")
    }

    @Test("USIM AKA success response is decoded")
    func akaResponse() throws {
        let res = Data(hexString: "0102030405060708")!
        let ck = Data(hexString: "00112233445566778899AABBCCDDEEFF")!
        let ik = Data(hexString: "FFEEDDCCBBAA99887766554433221100")!
        var response = Data([0xDB, UInt8(res.count)])
        response.append(res)
        response.append(UInt8(ck.count)); response.append(ck)
        response.append(UInt8(ik.count)); response.append(ik)
        let decoded = try parseVoWiFiAKAResponse(response)
        #expect(decoded.res == res)
        #expect(decoded.ck == ck)
        #expect(decoded.ik == ik)
    }

    @Test("AES-CBC wrapper matches the NIST vector")
    func aesCBC() throws {
        let key = Data(hexString: "2B7E151628AED2A6ABF7158809CF4F3C")!
        let iv = Data(hexString: "000102030405060708090A0B0C0D0E0F")!
        let plaintext = Data(hexString: "6BC1BEE22E409F96E93D7E117393172A")!
        let expected = Data(hexString: "7649ABAC8119B246CEE98E9B12E9197D")!
        let encrypted = try VoWiFiCrypto.aesCBCEncrypt(key: key, iv: iv, plaintext: plaintext)
        #expect(encrypted == expected)
        #expect(try VoWiFiCrypto.aesCBCDecrypt(key: key, iv: iv, ciphertext: encrypted) == plaintext)
    }

    @Test("IKE payload chains preserve their generic headers")
    func ikePayloadChain() throws {
        let message = IKEv2.Message(
            header: IKEv2.Header(
                initiatorSPI: 1, responderSPI: 2, nextPayload: .none,
                exchange: .informational, flags: 0x28, messageID: 7, length: 0
            ),
            payloads: [IKEv2.noncePayload(Data([1, 2, 3, 4]))]
        )
        let parsed = try IKEv2.Message.parse(message.encoded())
        #expect(parsed.payloads.count == 1)
        #expect(parsed.payloads[0].type == .nonce)
        #expect(parsed.payloads[0].body == Data([1, 2, 3, 4]))
    }

    @Test("Internal IPv4 stack encodes UDP and TCP")
    func internalIPStack() throws {
        let udpPacket = try VoWiFiIPv4.udpPacket(
            sourceAddress: "10.0.0.1", destinationAddress: "10.0.0.2",
            sourcePort: 5060, destinationPort: 5060,
            payload: Data("SIP".utf8), identification: 1
        )
        let udp = try VoWiFiIPv4.parseUDP(udpPacket)
        #expect(udp.payload == Data("SIP".utf8))

        let tcpPacket = try VoWiFiIPv4.tcpPacket(
            sourceAddress: "10.0.0.1", destinationAddress: "10.0.0.2",
            sourcePort: 51000, destinationPort: 5060,
            sequence: 10, acknowledgement: 20,
            flags: VoWiFiTCPSegment.ack | VoWiFiTCPSegment.psh,
            window: 4096, payload: Data("IMS".utf8), identification: 2
        )
        let parsedIP = try VoWiFiIPv4.parse(tcpPacket)
        let tcp = try VoWiFiIPv4.parseTCPSegment(
            parsedIP.payload,
            sourceAddress: parsedIP.sourceAddress,
            destinationAddress: parsedIP.destinationAddress
        )
        #expect(tcp.payload == Data("IMS".utf8))
        #expect(tcp.sequence == 10)
    }

    @Test("SIP binary body and IMS UCS2 SMS round-trip")
    func sipAndSMS() throws {
        var tpdu = Data([0x00, 0x03, 0x91, 0x21, 0xF3, 0x00, 0x08])
        tpdu.append(contentsOf: [0x62, 0x70, 0x61, 0x21, 0x00, 0x00, 0x00])
        tpdu.append(contentsOf: [0x04, 0x00, 0x48, 0x00, 0x69])
        var rpdu = Data([0x01, 0x2A, 0x00, 0x00, UInt8(tpdu.count)])
        rpdu.append(tpdu)
        let sip = SIPMessage(
            startLine: "MESSAGE sip:user@example.invalid SIP/2.0",
            headers: [("Content-Type", "application/vnd.3gpp.sms")],
            body: rpdu
        )
        let parsed = try SIPMessage.parse(sip.encoded())
        #expect(parsed.startLine == sip.startLine)
        #expect(parsed.header("Content-Type") == "application/vnd.3gpp.sms")
        #expect(parsed.body == sip.body)
        let sms = try IMSSMSCodec.decodeRPData(parsed.body)
        #expect(sms.sender == "+123")
        #expect(sms.body == "Hi")
        #expect(IMSSMSCodec.rpAck(messageReference: sms.messageReference) == Data([0x02, 0x2A]))
    }
}
