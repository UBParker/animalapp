import SwiftUI

enum VoiceSection: String, CaseIterable, Identifiable {
    case record = "Record", history = "History", ask = "Ask", insights = "Insights"
    var id: String { rawValue }
}

struct VoiceTabView: View {
    @Environment(\.selectedAnimal) private var animal
    @State private var section: VoiceSection = .record

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(VoiceSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if animal == nil {
                ContentUnavailableView("No animal selected", systemImage: "pawprint",
                                       description: Text("Add or select an animal from the top-left menu."))
            } else {
                switch section {
                case .record: RecordView()
                case .history: Text("History")
                case .ask: Text("Ask")
                case .insights: Text("Insights")
                }
            }
        }
    }
}
