import SwiftData
import SwiftUI

/// Tags a recording with animal, activity, meaning, confidence, and note, then propagates to its sounds.
///
/// The form edits a draft copy rather than the model. Writing straight through to the recording would
/// let the autosaving context persist every keystroke, so "Later" has to leave the model untouched.
struct TagSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let recording: VoiceRecording
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @State private var draft: Draft
    @State private var newActivity = ""
    @State private var newMeaning = ""

    /// A snapshot of the recording's tag fields, written back only by `save()`.
    private struct Draft {
        var animalID: UUID?
        var activityTag: String?
        var meaningTag: String?
        /// Seeded to 2 when unset, so an untouched save stores the "Fairly sure" the picker shows.
        var confidence: Int
        var note: String

        init(_ recording: VoiceRecording) {
            animalID = recording.animal?.id
            activityTag = recording.activityTag
            meaningTag = recording.meaningTag
            confidence = recording.userConfidence ?? 2
            note = recording.note
        }
    }

    init(recording: VoiceRecording) {
        self.recording = recording
        _draft = State(initialValue: Draft(recording))
    }

    var body: some View {
        Form {
            Section("Which animal") {
                Picker("Animal", selection: $draft.animalID) {
                    Text("Choose an animal").tag(UUID?.none)
                    ForEach(animals.filter { !$0.isArchived }) { Text("\($0.name) (\($0.species))").tag(Optional($0.id)) }
                }
            }
            Section("What was the animal doing") {
                tagPicker(selection: $draft.activityTag, options: VoiceTagNames.names(tags, kind: .activity), newText: $newActivity, kind: .activity)
            }
            Section("What do you think it meant") {
                tagPicker(selection: $draft.meaningTag, options: VoiceTagNames.names(tags, kind: .meaning), newText: $newMeaning, kind: .meaning)
            }
            Section("How sure are you") {
                ConfidencePicker(value: $draft.confidence)
            }
            Section("Note") {
                TextField("Anything else", text: $draft.note, axis: .vertical)
            }
            Section { statusSummary }
        }
        .navigationTitle("Tag recording")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(draft.animalID == nil) }
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

    /// Selects the existing tag's own spelling when one matches case-insensitively, so the picker
    /// lands on a row it actually lists; otherwise inserts the typed name and selects that.
    private func addTag(_ raw: String, kind: VoiceTagKind, selection: Binding<String?>) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let existing = tags.first(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selection.wrappedValue = existing.name
        } else {
            context.insert(VoiceTag(kind: kind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
            selection.wrappedValue = name
        }
    }

    /// The only place the draft reaches the model.
    private func save() {
        recording.animal = animals.first { $0.id == draft.animalID }
        recording.activityTag = draft.activityTag
        recording.meaningTag = draft.meaningTag
        recording.userConfidence = draft.confidence
        recording.note = draft.note
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
