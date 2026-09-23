import SwiftUI

/// Twelve preset colors for animals and buttons, plus hex helpers.
enum ColorPalette {
    static let presets: [String] = [
        "#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300",
        "#4A3AA7", "#E34948", "#00A3B4", "#8B5A2B", "#6B7280", "#111827",
    ]
    static let defaultHex = presets[0]

    static func color(_ hex: String) -> Color {
        guard let c = components(from: hex) else { return Color.gray }
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func hex(_ color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // A pattern or non-RGB color answers false and leaves the components untouched.
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return defaultHex }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Black or white, whichever reads better on the given background.
    static func contrastingText(on hex: String) -> Color {
        guard let c = components(from: hex) else { return .white }
        let luminance = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        return luminance > 0.6 ? .black : .white
    }

    /// Parses "#RRGGBB" or "RRGGBB" into 0...1 components; nil when the string is not six hex digits.
    private static func components(from hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Extended-range color spaces allow components outside 0...1; clamp so the byte never wraps.
    private static func byte(_ component: CGFloat) -> Int {
        Int(round(min(max(component, 0), 1) * 255))
    }
}
