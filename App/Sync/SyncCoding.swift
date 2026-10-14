import Foundation

/// The JSON **date** coding used on the wire. Task 4 passes these to `SupabaseClient` as
/// `SupabaseClientOptions.DatabaseOptions(encoder:decoder:)`, so `updated_at` keeps its sub-second
/// part end to end rather than depending on whatever the SDK's defaults happen to be.
///
/// Dates are all these coders handle. They set no key strategy and no UUID strategy, so a plain
/// encode of a row would emit camelCase keys and an UPPERCASE `uuidString`. Neither is this
/// type's problem to solve: Task 8's row structs hand-write `encode(to:)` and emit snake_case
/// keys explicitly, and adding a key strategy here would fight that. UUID casing matters in one
/// place, the Storage object path, where the bucket policy compares a lowercase `auth.uid()::text`
/// against the first path segment; `RemoteAudioPath.make` lowercases for that reason.
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
