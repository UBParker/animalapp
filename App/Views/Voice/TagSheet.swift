import SwiftData
import SwiftUI

/// Tags a recording with animal, activity, meaning, confidence, and note, then propagates to its sounds.
struct TagSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var recording: VoiceRecording
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @State private var newActivity = ""
    @State private var newMeaning = ""

    var body: some View {
        Form {
            Section("Which animal") {
                Picker("Animal", selection: Binding(
                    get: { recording.animal?.id },
                    set: { id in recording.animal = animals.first { $0.id == id } }
                )) {
                    Text("Choose an animal").tag(UUID?.none)
                    ForEach(animals.filter { !$0.isArchived }) { Text("\($0.name) (\($0.species))").tag(Optional($0.id)) }
                }
            }
            Section("What was the animal doing") {
                tagPicker(selection: $recording.activityTag, options: VoiceTagNames.names(tags, kind: .activity), newText: $newActivity, kind: .activity)
            }
            Section("What do you think it meant") {
                tagPicker(selection: $recording.meaningTag, options: VoiceTagNames.names(tags, kind: .meaning), newText: $newMeaning, kind: .meaning)
            }
            Section("How sure are you") {
                ConfidencePicker(value: Binding(get: { recording.userConfidence ?? 2 }, set: { recording.userConfidence = $0 }))
            }
            Section("Note") {
                TextField("Anything else", text: $recording.note, axis: .vertical)
            }
            Section { statusSummary }
        }
        .navigationTitle("Tag recording")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(recording.animal == nil) }
            ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        switch recording.status {
        case .analyzed:
            Text("\(recording.vocalizations?.count ?? 0) sounds detected. These tags apply to all of them; edit individual sounds in History.")
                .font(.footnote).foregroundStyle(.secondary)
        case .noSounds:
            Text("No sounds detected. You can re-analyze with a lower threshold in History.").font(.footnote).foregroundStyle(.secondary)
        case .failed:
            Text("Analysis failed: \(recording.errorMessage ?? "unknown error")").font(.footnote).foregroundStyle(.red)
        case .recorded:
            Text("Not analyzed yet.").font(.footnote)
        }
    }

    @ViewBuilder
    private func tagPicker(selection: Binding<String?>, options: [String], newText: Binding<String>, kind: VoiceTagKind) -> some View {
        Picker("Tag", selection: selection) {
            Text("None").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(Optional($0)) }
        }
        HStack {
            TextField("Add a new tag", text: newText)
            Button("Add") {
                addTag(newText.wrappedValue, kind: kind, selection: selection)
                newText.wrappedValue = ""
            }
            .disabled(newText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addTag(_ raw: String, kind: VoiceTagKind, selection: Binding<String?>) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !tags.contains(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
        }
        selection.wrappedValue = name
    }

    private func save() {
        recording.editedAt = Date()
        TagPropagation.apply(to: recording)
        try? context.save()
        dismiss()
    }
}

struct ConfidencePicker: View {
    @Binding var value: Int

    var body: some View {
        Picker("Confidence", selection: $value) {
            Text("Guess").tag(1)
            Text("Fairly sure").tag(2)
            Text("Certain").tag(3)
        }
        .pickerStyle(.segmented)
    }
}

enum VoiceTagNames {
    /// Distinct tag names of a kind in sort order.
    static func names(_ tags: [VoiceTag], kind: VoiceTagKind) -> [String] {
        var seen = Set<String>()
        return tags.filter { $0.kind == kind }.map(\.name).filter { seen.insert($0).inserted }
    }
}
