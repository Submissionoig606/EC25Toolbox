import Darwin
import EC25IKEHelperProtocol
import Foundation
import Security

private final class EC25IKEHelperService: NSObject, EC25IKEHelperXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [String: Int32] = [:]

    func protocolVersion(withReply reply: @escaping (Int) -> Void) {
        reply(EC25IKEHelperConstants.protocolVersion)
    }

    func openChannel(
        host: String,
        remotePort: Int,
        localPort: Int,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        guard remotePort == localPort, [500, 4500].contains(remotePort) else {
            reply(nil, "Only matching local/remote IKE ports 500 and 4500 are allowed.")
            return
        }
        do {
            let descriptor = try makeConnectedSocket(
                host: host,
                remotePort: UInt16(remotePort),
                localPort: UInt16(localPort)
            )
            let channelID = UUID().uuidString
            lock.lock()
            sockets[channelID] = descriptor
            lock.unlock()
            reply(channelID, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func send(
        channelID: String,
        payload: Data,
        withReply reply: @escaping (String?) -> Void
    ) {
        guard !payload.isEmpty, payload.count <= 65_535 else {
            reply("Invalid IKE datagram length.")
            return
        }
        guard let descriptor = socket(for: channelID) else {
            reply("IKE channel is closed.")
            return
        }
        let sent = payload.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == payload.count else {
            reply(posixError("send"))
            return
        }
        reply(nil)
    }

    func receive(
        channelID: String,
        timeout: Double,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        guard let descriptor = socket(for: channelID) else {
            reply(nil, "IKE channel is closed.")
            return
        }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(1, min(timeout, 300)) * 1_000)
        let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0 else {
            reply(nil, pollResult == 0 ? "IKE receive timed out." : posixError("poll"))
            return
        }
        var bytes = [UInt8](repeating: 0, count: 65_535)
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard received > 0 else {
            reply(nil, received == 0 ? "ePDG returned an empty datagram." : posixError("recv"))
            return
        }
        reply(Data(bytes.prefix(received)), nil)
    }

    func close(channelID: String, withReply reply: @escaping () -> Void) {
        lock.lock()
        let descriptor = sockets.removeValue(forKey: channelID)
        lock.unlock()
        if let descriptor { Darwin.close(descriptor) }
        reply()
    }

    func closeAll() {
        lock.lock()
        let descriptors = Array(sockets.values)
        sockets.removeAll()
        lock.unlock()
        for descriptor in descriptors { Darwin.close(descriptor) }
    }

    private func socket(for channelID: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return sockets[channelID]
    }

    private func makeConnectedSocket(
        host: String,
        remotePort: UInt16,
        localPort: UInt16
    ) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: Int32(IPPROTO_UDP),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(remotePort), &hints, &results)
        guard status == 0, let first = results else {
            throw HelperError.message("Invalid numeric ePDG address.")
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            guard isPublicRemoteAddress(entry.pointee.ai_addr) else { continue }
            let descriptor = Darwin.socket(
                entry.pointee.ai_family,
                entry.pointee.ai_socktype,
                entry.pointee.ai_protocol
            )
            guard descriptor >= 0 else { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            guard bindLocal(descriptor, family: entry.pointee.ai_family, port: localPort),
                  Darwin.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 else {
                Darwin.close(descriptor)
                continue
            }
            return descriptor
        }
        throw HelperError.message(posixError("bind/connect UDP \(localPort)"))
    }

    private func bindLocal(_ descriptor: Int32, family: Int32, port: UInt16) -> Bool {
        if family == AF_INET {
            var address = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: port.bigEndian,
                sin_addr: in_addr(s_addr: INADDR_ANY),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        if family == AF_INET6 {
            var address = sockaddr_in6(
                sin6_len: UInt8(MemoryLayout<sockaddr_in6>.size),
                sin6_family: sa_family_t(AF_INET6),
                sin6_port: port.bigEndian,
                sin6_flowinfo: 0,
                sin6_addr: in6addr_any,
                sin6_scope_id: 0
            )
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        return false
    }

    private func isPublicRemoteAddress(_ address: UnsafePointer<sockaddr>?) -> Bool {
        guard let address else { return false }
        if Int32(address.pointee.sa_family) == AF_INET {
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            return value != 0 && value >> 24 != 127
        }
        if Int32(address.pointee.sa_family) == AF_INET6 {
            let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return !bytes.allSatisfy { $0 == 0 }
                && !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        }
        return false
    }

    private func posixError(_ operation: String) -> String {
        "\(operation): \(String(cString: strerror(errno)))"
    }
}

private enum HelperError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

private final class EC25IKEHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorizedClient(connection) else { return false }
        let service = EC25IKEHelperService()
        connection.exportedInterface = NSXPCInterface(with: EC25IKEHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.closeAll() }
        connection.resume()
        return true
    }

    private func isAuthorizedClient(_ connection: NSXPCConnection) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return false }
        var requirement: SecRequirement?
        let expression = "identifier \"ing.fuyaoskyrocket.ec25toolbox\"" as CFString
        guard SecRequirementCreateWithString(expression, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
    }
}

private let delegate = EC25IKEHelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: EC25IKEHelperConstants.label)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
