import Foundation

/// RFC 4180 CSV: a field holding a comma, double quote, CR or LF is quoted with inner quotes
/// doubled; lines end in `\n`, including the last.
enum CSVWriter {
    static func field(_ value: String) -> String {
        // Scalars, not Characters: a delimiter followed by a combining mark is one Character that
        // equals none of these, and "\r\n" is one Character too. Every delimiter is one scalar.
        guard value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        // Doubled scalar by scalar for the same reason: `replacingOccurrences` compares composed
        // sequences, so it leaves a quote followed by a combining mark undoubled.
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in value.unicodeScalars {
            quoted.append(scalar)
            if scalar == "\"" { quoted.append("\"") }
        }
        quoted.append("\"")
        return String(quoted)
    }

    static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") + "\n" }.joined()
    }
}
