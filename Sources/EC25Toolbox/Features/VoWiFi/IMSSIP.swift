import CryptoKit
import Foundation

struct SIPMessage: Equatable, Sendable {
    var startLine: String
    var headers: [(String, String)]
    var body: Data

    static func == (lhs: SIPMessage, rhs: SIPMessage) -> Bool {
        lhs.startLine == rhs.startLine
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy {
                $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
            }
            && lhs.body == rhs.body
    }

    var statusCode: Int? {
        guard startLine.hasPrefix("SIP/2.0 ") else { return nil }
        return Int(startLine.split(separator: " ").dropFirst().first ?? "")
    }

    var method: String? {
        guard !startLine.hasPrefix("SIP/2.0 ") else { return nil }
        return startLine.split(separator: " ").first.map(String.init)
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func headers(named name: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }

    func encoded() -> Data {
        var normalized = headers.filter { $0.0.caseInsensitiveCompare("Content-Length") != .orderedSame }
        normalized.append(("Content-Length", String(body.count)))
        var text = startLine + "\r\n"
        for (name, value) in normalized { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var output = Data(text.utf8)
        output.append(body)
        return output
    }

    static func parse(_ data: Data) throws -> SIPMessage {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_message"))
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let startLine = lines.first, !startLine.isEmpty else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_message"))
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((
                String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ))
        }
        let declaredLength = headers.first {
            $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.1) } ?? 0
        let bodyStart = separator.upperBound
        guard declaredLength >= 0, bodyStart + declaredLength <= data.endIndex else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_content_length"))
        }
        return SIPMessage(
            startLine: startLine, headers: headers,
            body: Data(data[bodyStart..<(bodyStart + declaredLength)])
        )
    }
}

struct SIPDigestChallenge: Equatable, Sendable {
    var realm: String
    var nonce: String
    var algorithm: String
    var opaque: String?
    var qop: String?

    static func parse(_ value: String) throws -> SIPDigestChallenge {
        let clean = value.trimmingCharacters(in: .whitespaces)
        guard clean.lowercased().hasPrefix("digest ") else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_digest"))
        }
        var fields: [String: String] = [:]
        for component in splitDigestFields(String(clean.dropFirst(7))) {
            guard let equals = component.firstIndex(of: "=") else { continue }
            let key = component[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = component[component.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            fields[key] = value
        }
        guard let realm = fields["realm"], let nonce = fields["nonce"] else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.sip_digest"))
        }
        return SIPDigestChallenge(
            realm: realm, nonce: nonce, algorithm: fields["algorithm"] ?? "MD5",
            opaque: fields["opaque"], qop: fields["qop"]
        )
    }

    private static func splitDigestFields(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" { quoted.toggle(); current.append(character) }
            else if character == ",", !quoted { result.append(current); current = "" }
            else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum IMSAKA {
    static func challengeVector(nonce: String) throws -> (rand: Data, autn: Data) {
        guard let data = Data(base64Encoded: nonce), data.count >= 32 else {
            throw VoWiFiError.imsRegistrationFailed(localized("vowifi.error.ims_nonce"))
        }
        return (Data(data[0..<16]), Data(data[16..<32]))
    }

    static func authorization(
        challenge: SIPDigestChallenge,
        username: String,
        uri: String,
        method: String,
        res: Data,
        cnonce: String,
        nonceCount: Int = 1
    ) -> String {
        let password = res.hexString.lowercased()
        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        let nc = String(format: "%08x", nonceCount)
        let qop = challenge.qop?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.first(where: { $0.caseInsensitiveCompare("auth") == .orderedSame })
        let response: String
        if let qop {
            response = md5Hex("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }
        var fields = [
            "username=\"\(username)\"", "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"", "uri=\"\(uri)\"",
            "response=\"\(response)\"", "algorithm=\(challenge.algorithm)"
        ]
        if let qop { fields.append(contentsOf: ["qop=\(qop)", "nc=\(nc)", "cnonce=\"\(cnonce)\""]) }
        if let opaque = challenge.opaque { fields.append("opaque=\"\(opaque)\"") }
        return "Digest " + fields.joined(separator: ", ")
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct IMSRegistrationBinding: Equatable, Sendable {
    var publicIdentity: String
    var privateIdentity: String
    var localURI: String
    var pcscfAddress: String
    var localPort: UInt16
    var expiresAt: Date
    var callID: String
    var nextCSeq: Int
}
