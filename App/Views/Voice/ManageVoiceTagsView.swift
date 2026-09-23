import SwiftData
import SwiftUI

/// Rename or add activity and meaning tags. Built-in tags can be renamed but not deleted; custom tags delete freely
/// (labels on existing sounds keep the old name, which is why rename is the safer edit).
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
                        guard !name.isEmpty, !tags.contains(where: { $0.kind == newKind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
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
                HStack {
                    TextField("Name", text: Binding(get: { tag.name }, set: { tag.name = $0; try? context.save() }))
                    if tag.isBuiltIn { Text("built-in").font(.caption2).foregroundStyle(.secondary) }
                }
                .swipeActions {
                    if !tag.isBuiltIn {
                        Button("Delete", role: .destructive) { context.delete(tag); try? context.save() }
                    }
                }
            }
        }
    }
}
