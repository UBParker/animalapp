import SwiftData
import SwiftUI

struct VocalizationEditView: View {
    @Environment(\.modelContext) private var context
    @Bindable var vocalization: Vocalization
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]

    var body: some View {
        Form {
            Section("Measured") {
                LabeledContent("Start", value: String(format: "%.2f s", vocalization.startS))
                LabeledContent("Duration", value: String(format: "%.2f s", vocalization.durationS))
                LabeledContent("Pitch mean", value: vocalization.f0Mean.map { String(format: "%.0f Hz", $0) } ?? "unvoiced")
                LabeledContent("Pitch slope", value: vocalization.f0Slope.map { String(format: "%+.0f Hz/s", $0) } ?? "n/a")
                LabeledContent("Loudness", value: String(format: "%.0f dBFS", vocalization.rmsDb))
                LabeledContent("Spectral centroid", value: String(format: "%.0f Hz", vocalization.spectralCentroidHz))
            }
            Section("Activity") {
                Picker("Activity", selection: $vocalization.activityTag) {
                    Text("None").tag(String?.none)
                    ForEach(VoiceTagNames.names(tags, kind: .activity), id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section("Meaning") {
                Picker("Meaning", selection: $vocalization.meaningTag) {
                    Text("None").tag(String?.none)
                    ForEach(VoiceTagNames.names(tags, kind: .meaning), id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section("Confidence") {
                ConfidencePicker(value: Binding(get: { vocalization.userConfidence ?? 2 }, set: { vocalization.userConfidence = $0 }))
            }
            Section {
                if vocalization.overridden {
                    Button("Reset to recording tags") {
                        TagPropagation.resetOverride(vocalization)
                        try? context.save()
                    }
                } else {
                    Text("Changing tags here overrides the recording-level tags for this sound only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sound")
        .onChange(of: vocalization.activityTag) { _, _ in markOverriddenIfChanged() }
        .onChange(of: vocalization.meaningTag) { _, _ in markOverriddenIfChanged() }
        .onChange(of: vocalization.userConfidence) { _, _ in markOverriddenIfChanged() }
    }

    private func markOverriddenIfChanged() {
        if TagPropagation.differsFromRecording(vocalization) { vocalization.overridden = true }
        try? context.save()
    }
}
