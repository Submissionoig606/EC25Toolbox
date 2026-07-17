import Foundation
import Security

struct LPACHTTPRequest {
    let url: URL
    let body: Data?
    let headers: [String: String]

    init(payload: [String: Any]) throws {
        guard let rawURL = payload["url"] as? String,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else {
            throw LPACHTTPTransportError.invalidRequest
        }

        let rawBody = payload["tx"] as? String ?? ""
        guard rawBody.count.isMultiple(of: 2), rawBody.allSatisfy(\.isHexDigit),
              let body = Self.decodeHex(rawBody) else {
            throw LPACHTTPTransportError.invalidRequest
        }

        var parsedHeaders: [String: String] = [:]
        for line in payload["headers"] as? [String] ?? [] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            parsedHeaders[name] = value
        }

        self.url = url
        self.body = rawBody.isEmpty ? nil : body
        headers = parsedHeaders
    }

    private static func decodeHex(_ value: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

struct LPACHTTPResponse {
    let statusCode: Int
    let body: Data
}

enum LPACHTTPTransportError: LocalizedError {
    case invalidRequest
    case nonHTTPResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            localized("estk.error.http_request_invalid")
        case .nonHTTPResponse:
            localized("estk.error.http_response_invalid")
        }
    }
}

/// Executes lpac's ES9+ requests through the native macOS networking stack.
/// lpac keeps ownership of the SGP.22 state machine while TLS, trust evaluation,
/// redirects and proxy support use URLSession instead of a child-process libcurl.
final class LPACHTTPTransport: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let proxyURL: URL?
    private let ignoreTLSCertificate: Bool
    private let trustedRootCertificates: [SecCertificate]

    init(proxy: String?, ignoreTLSCertificate: Bool, trustedRootKeyIDs: [String]) {
        proxyURL = proxy.flatMap(URL.init(string:))
        self.ignoreTLSCertificate = ignoreTLSCertificate
        trustedRootCertificates = ESTKRootCertificates.certificates(for: trustedRootKeyIDs)
        super.init()
    }

    func transmit(_ request: LPACHTTPRequest) async throws -> LPACHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        if let proxyURL, let host = proxyURL.host {
            let port = proxyURL.port ?? defaultProxyPort(for: proxyURL.scheme)
            configuration.connectionProxyDictionary = proxyDictionary(
                scheme: proxyURL.scheme,
                host: host,
                port: port
            )
        }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.body == nil ? "GET" : "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw LPACHTTPTransportError.nonHTTPResponse
        }
        return LPACHTTPResponse(statusCode: response.statusCode, body: body)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if ignoreTLSCertificate {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard !trustedRootCertificates.isEmpty,
              SecTrustSetAnchorCertificates(trust, trustedRootCertificates as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func defaultProxyPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https": 443
        case "socks", "socks5": 1080
        default: 8080
        }
    }

    private func proxyDictionary(scheme: String?, host: String, port: Int) -> [AnyHashable: Any] {
        switch scheme?.lowercased() {
        case "socks", "socks5":
            [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port
            ]
        default:
            [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port
            ]
        }
    }
}
