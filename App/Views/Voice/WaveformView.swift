import SwiftUI

/// Scrolling bar meter fed by the recorder's level in dBFS.
struct WaveformView: View {
    var levelDb: Float
    var isActive: Bool
    @State private var history: [Float] = Array(repeating: 0, count: 60)

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(history.count)
            HStack(alignment: .center, spacing: slot * 0.3) {
                ForEach(history.indices, id: \.self) { i in
                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: slot * 0.7, height: max(4, CGFloat(history[i]) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: levelDb) { _, db in
            let normalized = max(0, min(1, (db + 60) / 60)) // -60 dBFS .. 0 dBFS
            history.removeFirst()
            history.append(isActive ? normalized : 0)
        }
    }
}
