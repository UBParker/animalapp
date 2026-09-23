import SwiftData
import SwiftUI

/// Rename or add activity and meaning tags. Built-in tags can be renamed but not deleted; custom tags delete freely
/// (labels on existing sounds keep the old name, which is why rename is the safer edit).
/// The built-in "Unknown" meaning is reserved: the model treats it as "not labeled", so it cannot be renamed.
struct ManageVoiceTagsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @State private var newName = ""
    @State private var newKind: VoiceTagKind = .meaning

    var body: some View {
        List {
            Section("Add") {
                Picker("Kind", selection: $newKind) {
                    Text("Meaning").tag(VoiceTagKind.meaning)
                    Text("Activity").tag(VoiceTagKind.activity)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("New tag", text: $newName)
                    Button("Add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !isDuplicate(name, kind: newKind, excluding: nil) else { return }
                        context.insert(VoiceTag(kind: newKind, name: name, sortOrder: (tags.map(\.sortOrder).max() ?? 0) + 1))
                        try? context.save()
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            section("Meanings", kind: .meaning)
            section("Activities", kind: .activity)
        }
        .navigationTitle("Voice tags")
    }

    private func section(_ title: String, kind: VoiceTagKind) -> some View {
        Section(title) {
            ForEach(tags.filter { $0.kind == kind }) { tag in
                if isReserved(tag) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name)
                        Text("built-in, reserved").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    TagRow(tag: tag, validate: { validate($0, for: tag) }, commit: { rename(tag, to: $0) })
                        .swipeActions {
                            if !tag.isBuiltIn {
                                Button("Delete", role: .destructive) { context.delete(tag); try? context.save() }
                            }
                        }
                }
            }
        }
    }

    /// The meaning the model reads as "not labeled". Renaming it would silently relabel every untagged sound.
    private func isReserved(_ tag: VoiceTag) -> Bool {
        tag.kind == .meaning && tag.name == VoiceTagSeed.unknownMeaning
    }

    private func isDuplicate(_ name: String, kind: VoiceTagKind, excluding id: UUID?) -> Bool {
        tags.contains { $0.id != id && $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Returns the reason a rename is rejected, or nil when it is allowed.
    private func validate(_ name: String, for tag: VoiceTag) -> String? {
        if name.isEmpty { return "Name can't be empty." }
        if isDuplicate(name, kind: tag.kind, excluding: tag.id) {
            return "Another \(tag.kind == .meaning ? "meaning" : "activity") is already called \"\(name)\"."
        }
        return nil
    }

    private func rename(_ tag: VoiceTag, to name: String) {
        // A model deleted out from under the row has no context; writing to it would be a write to nothing.
        guard tag.modelContext != nil else { return }
        tag.name = name
        try? context.save()
    }
}

/// One editable tag row. The draft lives in the row, so the model is written only when editing ends
/// (submit or focus loss) rather than on every keystroke, which keeps half-typed names out of the store.
private struct TagRow: View {
    let tag: VoiceTag
    let validate: (String) -> String?
    let commit: (String) -> Void

    @State private var draft: String
    @State private var error: String?
    @FocusState private var isFocused: Bool

    init(tag: VoiceTag, validate: @escaping (String) -> String?, commit: @escaping (String) -> Void) {
        self.tag = tag
        self.validate = validate
        self.commit = commit
        _draft = State(initialValue: tag.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Name", text: $draft)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { save() }
                if tag.isBuiltIn { Text("built-in").font(.caption2).foregroundStyle(.secondary) }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
        .onChange(of: draft) { _, edited in
            // The user is typing again, so a stale rejection goes away. A revert puts the stored name
            // back, and that must keep the caption up: Done rejects, then focus loss saves a second time.
            if edited != tag.name { error = nil }
        }
        .onChange(of: tag.name) { _, renamed in
            if !isFocused { draft = renamed }
        }
        .onDisappear {
            // Scrolling a focused row out of the list tears it down without ever clearing focus.
            if isFocused { save() }
        }
    }

    private func save() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard name != tag.name else {
            if draft != name { draft = name }   // normalise stray whitespace; leave any rejection showing
            return
        }
        if let reason = validate(name) {
            error = reason
            draft = tag.name
            return
        }
        error = nil
        draft = name
        commit(name)
    }
}
