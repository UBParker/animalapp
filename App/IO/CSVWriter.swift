import Foundation

/// RFC 4180 CSV: a field holding a comma, double quote, CR or LF is quoted with inner quotes
/// doubled; lines end in `\n`, including the last.
enum CSVWriter {
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") + "\n" }.joined()
    }
}
