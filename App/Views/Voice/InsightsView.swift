import Charts
import AnimalVoiceStats
import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.selectedAnimal) private var animal
    @Query private var recordings: [VoiceRecording]   // observed so the view refreshes when data changes
    /// Cached rather than computed in `body`: summarizing runs a leave-one-out evaluation, and a
    /// computed property would rerun it on every re-render, including every scroll tick.
    @State private var summary: InsightsSummary?

    var body: some View {
        List {
            if let animal, let summary {
                Section("Readiness for \(animal.name)") {
                    switch summary.readiness {
                    case .ready(let labels):
                        Label("Ready to predict across \(labels.count) meanings", systemImage: "checkmark.circle")
                    case .notReady(let message, _):
                        Label(message, systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    if let e = summary.evaluation {
                        LabeledContent("Leave-one-out accuracy", value: "\(Int(e.accuracy * 100))% (n = \(e.n))")
                    }
                    LabeledContent("Labeled sounds", value: "\(summary.labeledCount)")
                    LabeledContent("Unlabeled sounds", value: "\(summary.unlabeledCount)")
                }
                Section("Duration and pitch by meaning") {
                    if summary.points.isEmpty {
                        Text("Tag some voiced sounds to see them here.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Chart(summary.points) { p in
                            PointMark(x: .value("Duration (s)", p.durationS), y: .value("Pitch (Hz)", p.f0Mean))
                                .foregroundStyle(by: .value("Meaning", p.meaning))
                                .symbol(by: .value("Meaning", p.meaning))
                                .symbolSize(60)
                        }
                        .chartForegroundStyleScale(domain: summary.legendOrder, range: SeriesPalette.colors(for: summary.legendOrder))
                        .chartSymbolScale(domain: summary.legendOrder)
                        .chartXAxisLabel("Duration (s)")
                        .chartYAxisLabel("Pitch (Hz)")
                        .chartLegend(position: .bottom)
                        .frame(height: 260)
                    }
                    if summary.unvoicedCount > 0 {
                        Text("\(summary.unvoicedCount) sound\(summary.unvoicedCount == 1 ? " is" : "s are") unvoiced and not plotted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Labeled sounds per meaning") {
                    ForEach(summary.labelCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, n in
                        LabeledContent(label, value: "\(n)")
                    }
                }
            } else if animal == nil {
                Text("Select an animal to see insights.").foregroundStyle(.secondary)
            } else {
                // An animal is selected but its summary is still being built off the main actor.
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: animal?.id) { await reload() }
        .onChange(of: recordings.count) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        guard let animal else {
            summary = nil
            return
        }
        summary = try? await InsightsModel.summary(for: animal, context: context)
    }
}

/// Six categorical hues validated for colorblind separation on light and dark surfaces, in fixed order; "Other" is gray.
enum SeriesPalette {
    static let slots: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),
        dynamic(light: 0xEB6834, dark: 0xD95926),
        dynamic(light: 0x1BAF7A, dark: 0x199E70),
        dynamic(light: 0xEDA100, dark: 0xC98500),
        dynamic(light: 0xE87BA4, dark: 0xD55181),
        dynamic(light: 0x008300, dark: 0x008300),
    ]
    static let other = Color.gray

    static func colors(for legend: [String]) -> [Color] {
        legend.enumerated().map { index, name in
            name == InsightsModel.otherLabel ? other : slots[min(index, slots.count - 1)]
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
