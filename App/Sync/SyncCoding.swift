import Foundation

/// The JSON coding used on the wire. Task 4 passes these to `SupabaseClient` as
/// `SupabaseClientOptions.DatabaseOptions(encoder:decoder:)`, so the row structs are encoded and
/// decoded by exactly the coders the tests exercise, and `updated_at` keeps its sub-second part
/// end to end rather than depending on whatever the SDK's defaults happen to be.
enum SyncCoding {
    /// What this app writes: UTC, fractional seconds, Z suffix.
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// What Postgres sometimes writes back: no fractional part when it is exactly zero.
    static let formatterWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func date(from text: String) -> Date? {
        formatter.date(from: text) ?? formatterWithoutFraction.date(from: text)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let parsed = date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return parsed
        }
        return decoder
    }()
}
