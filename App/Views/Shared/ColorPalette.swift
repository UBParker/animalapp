import SwiftUI

/// Twelve preset colors for animals and buttons, plus hex helpers.
enum ColorPalette {
    static let presets: [String] = [
        "#2A78D6", "#EB6834", "#1BAF7A", "#EDA100", "#E87BA4", "#008300",
        "#4A3AA7", "#E34948", "#00A3B4", "#8B5A2B", "#6B7280", "#111827",
    ]
    static let defaultHex = presets[0]

    static func color(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return Color.gray }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    /// Black or white, whichever reads better on the given background.
    static func contrastingText(on hex: String) -> Color {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return luminance > 0.6 ? .black : .white
    }
}
