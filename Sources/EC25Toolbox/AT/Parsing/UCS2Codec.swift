import Foundation

enum UCS2 {
    static func encode(_ text: String) -> String {
        text.utf16.map { String(format: "%04X", $0) }.joined()
    }

    static func decode(_ hex: String) -> String {
        let cleaned = trimmed(hex)
        guard cleaned.count >= 4, cleaned.count.isMultiple(of: 4), cleaned.allSatisfy(\.isHexDigit) else {
            return hex
        }

        var units: [UInt16] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 4)
            let chunk = cleaned[index..<next]
            guard let value = UInt16(chunk, radix: 16) else { return hex }
            units.append(value)
            index = next
        }
        return String(decoding: units, as: UTF16.self)
    }
}
