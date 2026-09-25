import Foundation

/// The Supabase project the app talks to. The anon key is public and is committed in
/// `Supabase.plist` (spec Addendum v7.1). The placeholder string still exists as a tripwire: a
/// build that somehow ships with it produces `nil` here, which DEBUG turns into offline mode and
/// Release turns into a blocking "not configured" screen.
struct SupabaseConfig: Equatable {
    /// The tripwire value. Anything equal to this is "not configured".
    static let placeholderKey = "REPLACE_WITH_ANON_KEY"

    let url: URL
    let anonKey: String

    /// The bundle that carries `Supabase.plist`. Resolved through a type defined in the app target,
    /// so a test host resolves to the app bundle rather than the test bundle.
    static var appBundle: Bundle { Bundle(for: SupabaseConfigBundleToken.self) }

    static func make(url: String?, anonKey: String?) -> SupabaseConfig? {
        let trimmedKey = (anonKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey != placeholderKey else { return nil }
        let trimmedURL = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmedURL), parsed.scheme == "https", parsed.host != nil else { return nil }
        return SupabaseConfig(url: parsed, anonKey: trimmedKey)
    }

    static func load(bundle: Bundle = SupabaseConfig.appBundle) -> SupabaseConfig? {
        guard let path = bundle.path(forResource: "Supabase", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return make(url: dict["SupabaseURL"] as? String, anonKey: dict["SupabaseAnonKey"] as? String)
    }
}

/// Anchor for `Bundle(for:)`. Has no other purpose.
final class SupabaseConfigBundleToken: NSObject {}
