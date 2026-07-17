import Foundation

/// Converts `+CSQ` RSSI units into dBm, percent, and menu-bar signal bars.
func signalFromRSSI(_ rssi: Int?) -> SignalInfo {
    guard let rssi, rssi != 99 else {
        return SignalInfo(dbm: nil, bars: 0, percent: 0, text: "common.unknown")
    }

    let dbm = 2 * rssi - 113
    let bars: Int
    if rssi >= 20 {
        bars = 4
    } else if rssi >= 15 {
        bars = 3
    } else if rssi >= 10 {
        bars = 2
    } else if rssi >= 2 {
        bars = 1
    } else {
        bars = 0
    }

    return SignalInfo(dbm: dbm, bars: bars, percent: max(0, min(100, Int(round(Double(rssi) / 31.0 * 100.0)))), text: "\(dbm) dBm")
}

/// Maps LTE RSRP to the same 0-4 bar scale used by the menu-bar icon.
func barsFromRSRP(_ rsrp: Int?) -> Int? {
    guard let rsrp else { return nil }
    if rsrp >= -85 { return 4 }
    if rsrp >= -95 { return 3 }
    if rsrp >= -105 { return 2 }
    if rsrp >= -115 { return 1 }
    return 0
}

/// Parses `AT+CSQ` output into a user-facing signal summary.
func parseSignal(_ lines: [String]) -> SignalInfo {
    guard let line = firstLine(lines, containing: "+CSQ:") else { return .empty }
    let payload = line.replacingOccurrences(of: "+CSQ:", with: "")
    let rssi = Int(trimmed(csvParts(payload).first))
    return signalFromRSSI(rssi ?? 99)
}

/// Extracts the BER component from `AT+CSQ` output.
func parseBER(_ lines: [String]) -> String {
    guard let line = firstLine(lines, containing: "+CSQ:") else { return "-" }
    let payload = line.replacingOccurrences(of: "+CSQ:", with: "")
    return trimmed(csvParts(payload).dropFirst().first) == "" ? "-" : trimmed(csvParts(payload).dropFirst().first)
}
