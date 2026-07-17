import Foundation

private let messageStatus: [String: String] = [
    "0": "REC UNREAD",
    "1": "REC READ",
    "2": "STO UNSENT",
    "3": "STO SENT",
    "4": "ALL"
]

/// Parses `AT+CMGL` output from a specific storage area into SMS messages.
func parseMessageList(_ lines: [String], storage: String) -> [SMSMessage] {
    var parsed: [SMSMessage] = []
    var index = 0

    while index < lines.count {
        let line = lines[index]
        guard line.hasPrefix("+CMGL:") else {
            index += 1
            continue
        }

        let parts = csvParts(line.replacingOccurrences(of: "+CMGL:", with: ""))
        let messageIndex = Int(trimmed(parts[safe: 0] ?? "0")) ?? 0
        let statusToken = trimQuotes(parts[safe: 1] ?? "-")
        let status = messageStatus[statusToken] ?? statusToken
        let sender = UCS2.decode(trimQuotes(parts[safe: 2] ?? "-"))
        let date = trimQuotes(parts[safe: 4] ?? "-")
        var bodyLines: [String] = []

        index += 1
        while index < lines.count && !lines[index].hasPrefix("+CMGL:") {
            bodyLines.append(UCS2.decode(lines[index]))
            index += 1
        }

        let upper = status.uppercased()
        parsed.append(
            SMSMessage(
                id: "\(storage)-\(messageIndex)",
                storage: storage,
                index: messageIndex,
                status: status,
                outgoing: upper.contains("STO") || upper.contains("SENT"),
                unread: upper.contains("UNREAD"),
                sender: sender,
                date: date,
                body: bodyLines.joined(separator: "\n")
            )
        )
    }

    return parsed
}
