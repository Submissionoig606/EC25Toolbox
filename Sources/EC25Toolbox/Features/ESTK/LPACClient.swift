import Darwin
import Foundation

/// One request emitted by lpac's ndJSON standard-I/O APDU backend.
struct LPACAPDURequest {
    var function: String
    var parameter: String
}

/// Response returned to lpac after handling one APDU request through the modem.
struct LPACAPDUResponse {
    var errorCode: Int
    var data: String?
    var diagnostic: String?
}

/// Errors produced by executable discovery, lpac, or the APDU bridge.
enum ESTKError: LocalizedError {
    case executableNotFound
    case invalidExecutable(String)
    case invalidActivationCode
    case invalidDownloadParameters
    case qrCodeNotFound
    case invalidISDRAID
    case invalidMSS
    case malformedLPACOutput
    case lpacFailure(String)
    case processFailure(Int32, String)
    case malformedAPDURequest
    case malformedCSIMResponse
    case malformedLogicalChannelResponse
    case malformedAPDUResponse(String)
    case unsupportedAPDUFunction(String)
    case notificationBatchFailure(Int, String)
    case profileInstallFailedState
    case profileStateRefreshPending

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            localized("estk.error.lpac_not_found")
        case let .invalidExecutable(path):
            localizedFormat("estk.error.lpac_invalid", path)
        case .invalidActivationCode:
            localized("estk.error.activation_code_invalid")
        case .invalidDownloadParameters:
            localized("estk.error.download_parameters_invalid")
        case .qrCodeNotFound:
            localized("estk.error.qr_not_found")
        case .invalidISDRAID:
            localized("estk.error.aid_invalid")
        case .invalidMSS:
            localized("estk.error.mss_invalid")
        case .malformedLPACOutput:
            localized("estk.error.lpac_output_invalid")
        case let .lpacFailure(message):
            localizedFormat("estk.error.lpac_failed", message)
        case let .processFailure(status, detail):
            localizedFormat("estk.error.lpac_exit", status, detail)
        case .malformedAPDURequest:
            localized("estk.error.apdu_request_invalid")
        case .malformedCSIMResponse:
            localized("estk.error.csim_response_invalid")
        case .malformedLogicalChannelResponse:
            localized("estk.error.logical_channel_response_invalid")
        case let .malformedAPDUResponse(command):
            localizedFormat("estk.error.apdu_response_invalid", command)
        case let .unsupportedAPDUFunction(function):
            localizedFormat("estk.error.apdu_unsupported", function)
        case let .notificationBatchFailure(count, detail):
            localizedFormat("estk.error.notification_batch_failed", count, detail)
        case .profileInstallFailedState:
            localized("estk.error.profile_install_failed_state")
        case .profileStateRefreshPending:
            localized("estk.error.profile_state_refresh_pending")
        }
    }
}

/// Launches lpac and serves its standard-I/O APDU requests through a caller-provided bridge.
@MainActor
final class LPACClient {
    typealias APDUHandler = (LPACAPDURequest) async -> LPACAPDUResponse
    typealias ProgressHandler = (String) -> Void

    private let executableURL: URL
    private let isdRAID: String
    private let es10xMSS: Int
    private let httpProxy: String?
    private let ignoreTLSCertificate: Bool
    private let trustedRootKeyIDs: [String]
    private let apduHandler: APDUHandler
    private let progressHandler: ProgressHandler?

    init(
        executablePath: String?,
        isdRAID: String,
        es10xMSS: Int,
        httpProxy: String? = nil,
        ignoreTLSCertificate: Bool = false,
        trustedRootKeyIDs: [String] = [],
        progressHandler: ProgressHandler? = nil,
        apduHandler: @escaping APDUHandler
    ) throws {
        executableURL = try Self.resolveExecutable(customPath: executablePath)

        let normalizedAID = isdRAID.uppercased()
        guard normalizedAID.count.isMultiple(of: 2), normalizedAID.count >= 10,
              normalizedAID.allSatisfy(\.isHexDigit) else {
            throw ESTKError.invalidISDRAID
        }
        guard (6...255).contains(es10xMSS) else {
            throw ESTKError.invalidMSS
        }

        self.isdRAID = normalizedAID
        self.es10xMSS = es10xMSS
        self.httpProxy = firstPresent(httpProxy ?? "")
        self.ignoreTLSCertificate = ignoreTLSCertificate
        self.trustedRootKeyIDs = trustedRootKeyIDs
        self.progressHandler = progressHandler
        self.apduHandler = apduHandler
    }

    func run<T: Decodable>(_ arguments: [String], decoding type: T.Type) async throws -> T {
        let object = try await execute(arguments)
        return try decode(object, as: type)
    }

    func runWithRaw<T: Decodable>(_ arguments: [String], decoding type: T.Type) async throws -> LPACDecoded<T> {
        let object = try await execute(arguments)
        let value = try decode(object, as: type)
        let rawJSON: String
        if JSONSerialization.isValidJSONObject(object) {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            rawJSON = String(decoding: data, as: UTF8.self)
        } else {
            let data = try JSONSerialization.data(withJSONObject: ["value": object], options: [.prettyPrinted, .sortedKeys])
            let wrapped = String(decoding: data, as: UTF8.self)
            rawJSON = wrapped
        }
        return LPACDecoded(value: value, rawJSON: rawJSON)
    }

    private func decode<T: Decodable>(_ object: Any, as type: T.Type) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) || object is NSNull || object is String || object is NSNumber else {
            throw ESTKError.malformedLPACOutput
        }
        let wrapped = ["value": object]
        let data = try JSONSerialization.data(withJSONObject: wrapped)
        return try JSONDecoder().decode(DecodedValue<T>.self, from: data).value
    }

    func runVoid(_ arguments: [String]) async throws {
        _ = try await execute(arguments)
    }

    private func execute(_ arguments: [String]) async throws -> Any {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        // Convert a child stdin closure into EPIPE instead of terminating the
        // menu-bar host process with SIGPIPE.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe.fileHandleForWriting

        var environment = ProcessInfo.processInfo.environment
        environment["LPAC_APDU"] = "stdio"
        environment["LPAC_HTTP"] = "stdio"
        environment["LPAC_CUSTOM_ISD_R_AID"] = isdRAID
        environment["LPAC_CUSTOM_ES10X_MSS"] = String(es10xMSS)
        // HTTP is bridged back to URLSession below. Do not let inherited shell
        // proxy variables or the legacy curl compatibility switch affect lpac.
        for key in [
            "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy",
            "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy",
            "LPAC_HTTP_INSECURE"
        ] {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "LPAC_APDU_DEBUG")
        environment.removeValue(forKey: "LPAC_HTTP_DEBUG")
        environment.removeValue(forKey: "LIBEUICC_DEBUG_APDU")
        environment.removeValue(forKey: "LIBEUICC_DEBUG_HTTP")
        process.environment = environment

        var terminalPayload: [String: Any]?
        var diagnostics: [String] = []
        var processDiagnostics: [String] = []
        var lastAPDUError: String?
        var lastHTTPError: String?
        let httpTransport = LPACHTTPTransport(
            proxy: httpProxy,
            ignoreTLSCertificate: ignoreTLSCertificate,
            trustedRootKeyIDs: trustedRootKeyIDs
        )

        try process.run()
        outputPipe.fileHandleForWriting.closeFile()
        defer {
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            if process.isRunning {
                process.terminate()
            }
        }

        for try await line in outputPipe.fileHandleForReading.bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                if !trimmed(line).isEmpty {
                    diagnostics.append(line)
                    processDiagnostics.append(line)
                }
                continue
            }

            if type == "apdu" {
                guard let payload = json["payload"] as? [String: Any],
                      let function = payload["func"] as? String else {
                    throw ESTKError.malformedAPDURequest
                }
                let parameter = payload["param"] as? String ?? ""
                let response = await apduHandler(LPACAPDURequest(function: function, parameter: parameter))
                if response.errorCode < 0 {
                    // Preserve the first card/transport failure. euicc_fini may
                    // subsequently fail to close the channel; that cleanup
                    // error must not hide the reason BPP loading stopped.
                    lastAPDUError = lastAPDUError ?? response.diagnostic
                }
                do {
                    try write(response, to: inputPipe.fileHandleForWriting)
                } catch {
                    let detail = response.diagnostic ?? localized("estk.error.apdu_pipe_closed")
                    diagnostics.append(detail)
                    lastAPDUError = detail
                    if process.isRunning {
                        process.terminate()
                    }
                    break
                }
            } else if type == "http" {
                guard let payload = json["payload"] as? [String: Any] else {
                    throw ESTKError.malformedLPACOutput
                }
                do {
                    let request = try LPACHTTPRequest(payload: payload)
                    let response = try await httpTransport.transmit(request)
                    try writeHTTPResponse(
                        statusCode: response.statusCode,
                        body: response.body,
                        to: inputPipe.fileHandleForWriting
                    )
                } catch {
                    let detail = Self.describeHTTPError(error)
                    lastHTTPError = detail
                    diagnostics.append(detail)
                    try writeHTTPResponse(
                        statusCode: 599,
                        body: Data(detail.utf8),
                        to: inputPipe.fileHandleForWriting
                    )
                }
            } else if type == "lpa", let payload = json["payload"] as? [String: Any] {
                terminalPayload = payload
            } else if type == "progress",
                      let payload = json["payload"] as? [String: Any],
                      let message = payload["message"] as? String {
                let detail = payload["data"] as? String
                let progress = firstPresent(detail ?? "").map { "\(message) · \($0)" } ?? message
                diagnostics.append(progress)
                progressHandler?(progress)
            }
        }

        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard let terminalPayload else {
            let detail = diagnostics.suffix(8).joined(separator: " · ")
            throw ESTKError.processFailure(process.terminationStatus, detail)
        }

        let code = terminalPayload["code"] as? Int ?? -1
        if code != 0 {
            let message = terminalPayload["message"] as? String ?? localized("estk.error.unknown")
            let rawDetail = terminalPayload["data"] as? String
            let systemDetail = firstPresent(processDiagnostics.suffix(4).joined(separator: " · "))
            let detail = [message, rawDetail, systemDetail, lastHTTPError, lastAPDUError]
                .compactMap { firstPresent($0 ?? "") }
                .joined(separator: " · ")
            if detail.contains("[actual=Error_InstallFailed]") {
                throw ESTKError.profileInstallFailedState
            }
            throw ESTKError.lpacFailure(detail)
        }

        if let lastAPDUError {
            progressHandler?(lastAPDUError)
        }

        return terminalPayload["data"] ?? NSNull()
    }

    private func write(_ response: LPACAPDUResponse, to handle: FileHandle) throws {
        var payload: [String: Any] = ["ecode": response.errorCode]
        if let data = response.data {
            payload["data"] = data
        }
        let message: [String: Any] = ["type": "apdu", "payload": payload]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func writeHTTPResponse(statusCode: Int, body: Data, to handle: FileHandle) throws {
        let payload: [String: Any] = [
            "rcode": statusCode,
            "rx": body.map { String(format: "%02X", $0) }.joined()
        ]
        let message: [String: Any] = ["type": "http", "payload": payload]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func describeHTTPError(_ error: Error) -> String {
        let nsError = error as NSError
        var details = [error.localizedDescription]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.localizedDescription != nsError.localizedDescription {
            details.append(underlying.localizedDescription)
        }
        return localizedFormat("estk.error.http_transport_failed", details.joined(separator: " · "))
    }

    private static func resolveExecutable(customPath: String?) throws -> URL {
        if let rawPath = firstPresent(customPath ?? "") {
            let path = NSString(string: rawPath).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw ESTKError.invalidExecutable(path)
            }
            return URL(fileURLWithPath: path)
        }

        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "lpac", withExtension: nil) {
            candidates.append(bundled)
        }
        if let bundled = Bundle.module.url(forResource: "lpac", withExtension: nil) {
            candidates.append(bundled)
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("lpac"))
        }
        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }
        throw ESTKError.executableNotFound
    }
}

struct LPACDecoded<T> {
    var value: T
    var rawJSON: String
}

private struct DecodedValue<T: Decodable>: Decodable {
    var value: T
}
