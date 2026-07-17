import Foundation
import IOKit
import IOUSBHost

/// Errors surfaced by the native USB AT transport.
enum EC25TransportError: LocalizedError {
    /// A command was attempted before a USB session was opened.
    case notOpen
    /// No suitable modem interface could be opened.
    case openFailed(String)
    /// An AT transaction failed.
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOpen:
            localized("transport.not_open")
        case let .openFailed(message), let .sendFailed(message):
            message
        }
    }
}

/// Serializes direct USB access through Apple's native IOUSBHost framework.
actor EC25Transport {
    private var hostInterface: IOUSBHostInterface?
    private var inputPipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var sessionDescription = ""

    /// Opens the first bulk interface on the target modem that responds to `AT`.
    func open(vid: UInt16 = 0x2c7c, pid: UInt16 = 0x0125) throws -> String {
        close()

        var iterator: io_iterator_t = 0
        let matching = Self.matchingDictionary(vid: vid, pid: pid)
        let consumedMatching = Unmanaged.passRetained(matching)
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            consumedMatching.takeUnretainedValue(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw EC25TransportError.openFailed(localizedFormat("transport.enumeration_failed", Self.ioMessage(result)))
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            services.append(service)
        }
        defer { services.forEach { IOObjectRelease($0) } }

        // Quectel's 2c7c:0125 composition normally exposes AT on interface 2,
        // with interface 3 as the modem-command fallback. Probe those before
        // diagnostic/GNSS interfaces so a healthy device connects immediately.
        services.sort {
            let lhs = Self.interfaceNumber(for: $0)
            let rhs = Self.interfaceNumber(for: $1)
            let lhsPriority = Self.probePriority(interfaceNumber: lhs)
            let rhsPriority = Self.probePriority(interfaceNumber: rhs)
            return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
        }

        var foundInterface = false
        var lastFailure = ""

        for service in services {
            do {
                foundInterface = true

                let interface: IOUSBHostInterface
                do {
                    interface = try IOUSBHostInterface(
                        __ioService: service,
                        options: [],
                        queue: DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.usb"),
                        interestHandler: nil
                    )
                } catch {
                    lastFailure = error.localizedDescription
                    continue
                }

                guard let addresses = Self.bulkEndpointAddresses(for: interface) else {
                    interface.destroy()
                    continue
                }

                do {
                    let input = try interface.copyPipe(withAddress: Int(addresses.input))
                    let output = try interface.copyPipe(withAddress: Int(addresses.output))
                    let interfaceNumber = Int(interface.interfaceDescriptor.pointee.bInterfaceNumber)
                    do {
                        _ = try Self.transact(
                            command: "AT",
                            payload: nil,
                            timeout: 3,
                            inputPipe: input,
                            outputPipe: output
                        )
                    } catch {
                        let initialFailure = Self.detailedError(error)
                        let recoveryFailures = Self.clearStalls(
                            inputPipe: input,
                            inputAddress: addresses.input,
                            outputPipe: output,
                            outputAddress: addresses.output
                        )

                        do {
                            _ = try Self.transact(
                                command: "AT",
                                payload: nil,
                                timeout: 3,
                                inputPipe: input,
                                outputPipe: output
                            )
                        } catch {
                            let recoverySuffix = recoveryFailures.isEmpty
                                ? ""
                                : localizedFormat(
                                    "transport.stall_recovery_failed",
                                    recoveryFailures.joined(separator: ", ")
                                )
                            lastFailure = localizedFormat(
                                "transport.interface_probe_failed",
                                interfaceNumber,
                                Int(addresses.output),
                                Int(addresses.input),
                                initialFailure,
                                Self.detailedError(error),
                                recoverySuffix
                            )
                            interface.destroy()
                            continue
                        }
                    }

                    let description = String(
                        format: "USB %04x:%04x if%d out=0x%02x in=0x%02x",
                        Int(vid),
                        Int(pid),
                        interfaceNumber,
                        Int(addresses.output),
                        Int(addresses.input)
                    )

                    hostInterface = interface
                    inputPipe = input
                    outputPipe = output
                    sessionDescription = description
                    return description
                } catch {
                    lastFailure = error.localizedDescription
                    interface.destroy()
                }
            }
        }

        if !foundInterface {
            throw EC25TransportError.openFailed(localizedFormat(
                "transport.interface_not_found",
                String(format: "%04x:%04x", Int(vid), Int(pid))
            ))
        }

        let suffix = lastFailure.isEmpty ? "" : "：\(lastFailure)"
        throw EC25TransportError.openFailed(localizedFormat("transport.at_interface_not_found", suffix))
    }

    /// Stable probe order for the standard EC25 USB composition.
    static func probePriority(interfaceNumber: Int) -> Int {
        switch interfaceNumber {
        case 2: 0
        case 3: 1
        case 1: 2
        case 0: 3
        default: interfaceNumber == Int.max ? Int.max : 4 + max(0, interfaceNumber)
        }
    }

    /// Releases the native interface and all endpoint pipes.
    func close() {
        inputPipe = nil
        outputPipe = nil
        hostInterface?.destroy()
        hostInterface = nil
        sessionDescription = ""
    }

    /// Current USB session description, or an empty string when closed.
    func description() -> String {
        sessionDescription
    }

    /// Sends one AT command through the native USB pipes.
    func send(command: String, payload: String? = nil, timeoutMs: Int32 = 4_000) throws -> [String] {
        guard let inputPipe, let outputPipe else { throw EC25TransportError.notOpen }

        do {
            return try Self.transact(
                command: command,
                payload: payload,
                timeout: max(0.001, Double(timeoutMs) / 1_000),
                inputPipe: inputPipe,
                outputPipe: outputPipe
            )
        } catch let error as EC25TransportError {
            throw error
        } catch {
            throw EC25TransportError.sendFailed(error.localizedDescription)
        }
    }

    private static func matchingDictionary(vid: UInt16, pid: UInt16) -> CFMutableDictionary {
        let matching = IOServiceMatching("IOUSBHostInterface")!
        let key = "IOPropertyMatch" as CFString
        let properties = NSDictionary(dictionary: [
            "idVendor": NSNumber(value: vid),
            "idProduct": NSNumber(value: pid)
        ])
        CFDictionarySetValue(
            matching,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(properties).toOpaque()
        )
        return matching
    }

    private static func interfaceNumber(for service: io_service_t) -> Int {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "bInterfaceNumber" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else { return Int.max }
        return value.intValue
    }

    private static func clearStalls(
        inputPipe: IOUSBHostPipe,
        inputAddress: UInt8,
        outputPipe: IOUSBHostPipe,
        outputAddress: UInt8
    ) -> [String] {
        var failures: [String] = []
        do {
            try inputPipe.clearStall()
        } catch {
            failures.append(String(format: "0x%02x=%@", Int(inputAddress), detailedError(error)))
        }
        do {
            try outputPipe.clearStall()
        } catch {
            failures.append(String(format: "0x%02x=%@", Int(outputAddress), detailedError(error)))
        }
        return failures
    }

    private static func detailedError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private static func bulkEndpointAddresses(for interface: IOUSBHostInterface) -> (input: UInt8, output: UInt8)? {
        let configuration = interface.configurationDescriptor
        let descriptor = interface.interfaceDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        var input: UInt8?
        var output: UInt8?

        for _ in 0..<Int(descriptor.pointee.bNumEndpoints) {
            guard let endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, current) else { break }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)

            guard IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) else { continue }
            let address = IOUSBGetEndpointAddress(endpoint)
            if address & 0x80 == 0 {
                output = address
            } else {
                input = address
            }
        }

        guard let input, let output else { return nil }
        return (input, output)
    }

    private static func transact(
        command: String,
        payload: String?,
        timeout: TimeInterval,
        inputPipe: IOUSBHostPipe,
        outputPipe: IOUSBHostPipe
    ) throws -> [String] {
        try drain(inputPipe)
        try write(Data((command + "\r").utf8), to: outputPipe, timeout: timeout)

        if let payload {
            try waitForPrompt(on: inputPipe, timeout: min(timeout, 5))
            try write(Data(payload.utf8), to: outputPipe, timeout: timeout)
            return try readResponse(on: inputPipe, echo: nil, timeout: timeout)
        }

        return try readResponse(on: inputPipe, echo: command, timeout: timeout)
    }

    private static func drain(_ pipe: IOUSBHostPipe) throws {
        for _ in 0..<16 {
            guard let data = try readChunk(from: pipe, timeout: 0.02), !data.isEmpty else { return }
        }
    }

    private static func write(_ data: Data, to pipe: IOUSBHostPipe, timeout: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let buffer = NSMutableData(data: data.subdata(in: offset..<data.count))
            var transferred = 0
            try pipe.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
            guard transferred > 0 else {
                throw EC25TransportError.sendFailed(localized("transport.write_stalled"))
            }
            offset += transferred
        }
    }

    private static func waitForPrompt(on pipe: IOUSBHostPipe, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let data = try readChunk(from: pipe, timeout: min(remaining, 0.25)), data.contains(0x3E) {
                return
            }
        }
        throw EC25TransportError.sendFailed(localized("transport.prompt_timeout"))
    }

    private static func readResponse(
        on pipe: IOUSBHostPipe,
        echo: String?,
        timeout: TimeInterval
    ) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var partial: [UInt8] = []
        var lines: [String] = []

        func consumePartial() throws -> Bool {
            guard !partial.isEmpty else { return false }
            let line = String(decoding: partial, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            partial.removeAll(keepingCapacity: true)

            guard !line.isEmpty, line != echo else { return false }
            if line == "OK" { return true }
            if line == "ERROR" || line.hasPrefix("+CME ERROR:") || line.hasPrefix("+CMS ERROR:") {
                throw EC25TransportError.sendFailed(line)
            }
            lines.append(line)
            return false
        }

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let data = try readChunk(from: pipe, timeout: min(remaining, 0.25)) else { continue }

            for byte in data {
                if byte == 0x0D || byte == 0x0A {
                    if try consumePartial() { return lines }
                } else {
                    partial.append(byte)
                    if partial.count > 1_048_576 {
                        throw EC25TransportError.sendFailed(localized("transport.response_too_large"))
                    }
                }
            }
        }

        if try consumePartial() { return lines }
        throw EC25TransportError.sendFailed(localized("transport.command_timeout"))
    }

    private static func readChunk(from pipe: IOUSBHostPipe, timeout: TimeInterval) throws -> Data? {
        let buffer = NSMutableData(length: 512)!
        var transferred = 0
        do {
            try pipe.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
        } catch let error as NSError where Int32(truncatingIfNeeded: error.code) == kIOReturnTimeout {
            return nil
        }

        guard transferred > 0 else { return Data() }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    private static func ioMessage(_ result: kern_return_t) -> String {
        String(cString: mach_error_string(result))
    }
}
