import Foundation

private let registrationStatus: [String: String] = [
    "0": "registration.not_registered",
    "1": "registration.registered_home",
    "2": "registration.searching",
    "3": "registration.denied",
    "4": "common.unknown",
    "5": "registration.registered_roaming"
]

private let accessTechnology: [Int: String] = [
    0: "GSM",
    1: "GSM Compact",
    2: "UTRAN",
    3: "GSM/EGPRS",
    4: "UTRAN/HSDPA",
    5: "UTRAN/HSUPA",
    6: "UTRAN/HSPA",
    7: "LTE",
    8: "LTE Cat-M1",
    9: "LTE Cat-NB1",
    10: "5G NSA",
    11: "5G"
]

private let bandwidthIndex: [String: String] = [
    "0": "1.4M",
    "1": "3M",
    "2": "5M",
    "3": "10M",
    "4": "15M",
    "5": "20M"
]

private let lteBands: [Int: (Double, Int)] = [
    1: (2110, 0),
    2: (1930, 600),
    3: (1805, 1200),
    4: (2110, 1950),
    5: (869, 2400),
    7: (2620, 2750),
    8: (925, 3450),
    12: (729, 5010),
    13: (746, 5180),
    17: (734, 5730),
    18: (860, 5850),
    19: (875, 6000),
    20: (791, 6150),
    25: (1930, 8040),
    26: (859, 8690),
    28: (758, 9210),
    38: (2570, 37750),
    39: (1880, 38250),
    40: (2300, 38650),
    41: (2496, 39650),
    66: (2110, 66436)
]

/// Parsed `AT+QNWINFO` payload normalized for display and derived fields.
struct NetworkTypeParse {
    var full: String
    var label: String
    var band: String
    var channel: String
}

/// Parsed LTE serving-cell fields from `AT+QENG="servingcell"`.
struct ServingCellParse {
    var plmn: String?
    var duplexMode: String?
    var band: Int?
    var earfcn: Int?
    var rsrp: Int?
    var rsrq: Int?
    var rssi: Int?
    var sinr: Int?
    var cqi: Int?
    var dlBandwidth: String?
    var ulBandwidth: String?
    var pci: Int?
    var cellId: String?
    var tac: String?
}

/// Converts LTE band and EARFCN into downlink MHz when the band table is known.
func earfcnToDlMHz(band: Int?, earfcn: Int?) -> Double? {
    guard let band, let earfcn, let tuple = lteBands[band] else { return nil }
    return ((tuple.0 + 0.1 * Double(earfcn - tuple.1)) * 10).rounded() / 10
}

/// Gives a rough modulation label from CQI for compact UI display.
func cqiToModulation(_ cqi: Int?) -> String {
    guard let cqi, cqi > 0 else { return "-" }
    if cqi <= 6 { return "QPSK (CQI \(cqi))" }
    if cqi <= 9 { return "16QAM (CQI \(cqi))" }
    return "64QAM (CQI \(cqi))"
}

/// Collapses detailed access technology names into 2G/3G/4G/5G labels.
func shortNetworkLabel(_ access: String) -> String {
    let value = access.uppercased()
    if value.contains("NR") || value.contains("5G") { return "5G" }
    if value.contains("LTE") { return "4G" }
    if value.contains("TD-SCDMA") || value.contains("WCDMA") || value.contains("HSDPA") || value.contains("HSPA") || value.contains("UMTS") { return "3G" }
    if value.contains("GSM") || value.contains("EDGE") || value.contains("GPRS") { return "2G" }
    return access.isEmpty ? "-" : access
}

/// Parses the operator name from `AT+COPS?`, decoding UCS2 when needed.
func parseOperator(_ lines: [String]) -> String {
    guard let line = firstLine(lines, containing: "+COPS:") else { return "-" }
    let parts = csvParts(line.replacingOccurrences(of: "+COPS:", with: ""))
    return UCS2.decode(trimQuotes(parts[safe: 2] ?? line))
}

/// Parses access technology from `AT+COPS?`, falling back to `QNWINFO`.
func parseTech(operatorLines: [String], fallback: String) -> String {
    if let line = firstLine(operatorLines, containing: "+COPS:") {
        let parts = csvParts(line.replacingOccurrences(of: "+COPS:", with: ""))
        if let act = Int(trimmed(parts[safe: 3])), let label = accessTechnology[act] {
            return label
        }
    }
    return fallback.isEmpty ? "-" : fallback
}

/// Converts `CREG`/`CGREG`/`CEREG` registration status into Chinese labels.
func parseRegistration(_ lines: [String], prefix: String) -> String {
    guard let line = firstLine(lines, containing: prefix) else { return "-" }
    let parts = csvParts(line.replacingOccurrences(of: prefix, with: ""))
    let stat = trimmed(parts.last)
    return registrationStatus[stat] ?? stat
}

/// Parses `AT+QNWINFO` into a concise display string, network label, band, and channel.
func parseNetworkType(_ lines: [String]) -> NetworkTypeParse {
    guard let line = firstLine(lines, containing: "+QNWINFO:") else {
        return NetworkTypeParse(full: "-", label: "-", band: "-", channel: "-")
    }
    let parts = csvParts(line.replacingOccurrences(of: "+QNWINFO:", with: ""))
    let access = trimQuotes(parts[safe: 0] ?? "-")
    let band = trimQuotes(parts[safe: 2] ?? "-")
    let channel = trimmed(parts[safe: 3] ?? "-")
    let upper = access.uppercased()
    if access == "-" || access.isEmpty || upper.contains("NONE") || upper.contains("NO SERVICE") {
        return NetworkTypeParse(full: "network.no_service", label: "network.no_service", band: "-", channel: "-")
    }
    return NetworkTypeParse(full: "\(access) · \(band) · \(channel)", label: shortNetworkLabel(access), band: band, channel: channel)
}

/// Parses the LTE form of `AT+QENG="servingcell"`.
func parseServingCell(_ lines: [String]) -> ServingCellParse {
    let empty = ServingCellParse()
    guard let line = firstLine(lines, containing: "+QENG:") else { return empty }
    let parts = csvParts(line.replacingOccurrences(of: "+QENG:", with: "")).map(trimQuotes)
    guard (parts[safe: 2] ?? "").uppercased() == "LTE" else { return empty }

    func int(_ index: Int) -> Int? {
        Int(parts[safe: index] ?? "")
    }

    return ServingCellParse(
        plmn: parsePLMN(mcc: parts[safe: 4], mnc: parts[safe: 5]),
        duplexMode: nonPlaceholder(parts[safe: 3]),
        band: int(9),
        earfcn: int(8),
        rsrp: int(13),
        rsrq: int(14),
        rssi: int(15),
        sinr: int(16),
        cqi: int(17),
        dlBandwidth: bandwidthIndex[parts[safe: 11] ?? ""],
        ulBandwidth: bandwidthIndex[parts[safe: 10] ?? ""],
        pci: int(7),
        cellId: parts[safe: 6],
        tac: parts[safe: 12]
    )
}

private func parsePLMN(mcc: String?, mnc: String?) -> String? {
    guard let mcc = nonPlaceholder(mcc), let mnc = nonPlaceholder(mnc) else { return nil }
    return "\(mcc)-\(mnc)"
}

private func nonPlaceholder(_ value: String?) -> String? {
    let clean = trimmed(value)
    guard !clean.isEmpty, clean != "-", clean != "--" else { return nil }
    return clean
}
