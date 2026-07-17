import Foundation

public enum EC25IKEHelperConstants {
    public static let label = "ing.fuyaoskyrocket.ec25toolbox.ike-helper"
    public static let executableName = "EC25IKEHelper"
    public static let protocolVersion = 1
    public static let installedExecutablePath = "/Library/PrivilegedHelperTools/\(label)"
    public static let installedPlistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let bundledPlistName = "\(label).plist"
}

/// Narrow XPC surface exposed by the root helper. It only permits connected
/// UDP sockets whose local and remote ports are IKE/NAT-T ports 500 or 4500.
@objc(EC25IKEHelperXPCProtocol)
public protocol EC25IKEHelperXPCProtocol {
    func protocolVersion(withReply reply: @escaping (Int) -> Void)
    func openChannel(
        host: String,
        remotePort: Int,
        localPort: Int,
        withReply reply: @escaping (String?, String?) -> Void
    )
    func send(
        channelID: String,
        payload: Data,
        withReply reply: @escaping (String?) -> Void
    )
    func receive(
        channelID: String,
        timeout: Double,
        withReply reply: @escaping (Data?, String?) -> Void
    )
    func close(channelID: String, withReply reply: @escaping () -> Void)
}
