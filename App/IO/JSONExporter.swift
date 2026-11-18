import Foundation

enum JSONExporter {
    /// Pretty-printed with sorted keys, so the same bundle always produces the same bytes.
    static func data(_ bundle: ExportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }
}
