import Foundation

/// Trims whitespace and newlines from an optional AT response fragment.
func trimmed(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Removes surrounding quote characters after normalizing whitespace.
func trimQuotes(_ value: String?) -> String {
    trimmed(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

/// Splits a comma-separated AT payload while preserving commas inside quoted fields.
func csvParts(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false

    for character in line {
        if character == "\"" {
            quoted.toggle()
            current.append(character)
        } else if character == "," && !quoted {
            result.append(trimmed(current))
            current = ""
        } else {
            current.append(character)
        }
    }

    result.append(trimmed(current))
    return result
}

/// Returns the first response line containing the requested token.
func firstLine(_ lines: [String], containing needle: String) -> String? {
    lines.first { $0.contains(needle) }
}

/// Returns the first plain response line that is not an echo or prefixed result.
func firstNonCommandLine(_ lines: [String]) -> String? {
    lines.first { !$0.hasPrefix("AT") && !$0.hasPrefix("+") }?.trimmingCharacters(in: .whitespacesAndNewlines)
}

extension Collection {
    /// Safely indexes a collection, returning `nil` when the index is out of bounds.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
