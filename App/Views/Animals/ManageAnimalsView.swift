import SwiftData
import SwiftUI

struct ManageAnimalsView: View {
    var isFirstRun = false
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @State private var showAdd = false
    @State private var editing: Animal?
    @State private var blockedMessage: String?

    private var active: [Animal] { animals.filter { !$0.isArchived } }
    private var archived: [Animal] { animals.filter(\.isArchived) }

    var body: some View {
        List {
            Section {
                ForEach(active) { animal in
                    row(animal)
                        .swipeActions(edge: .trailing) {
                            Button("Archive") { animal.isArchived = true; try? context.save() }.tint(.orange)
                            Button("Delete", role: .destructive) { delete(animal) }
                        }
                }
                .onMove(perform: move)
            } header: {
                Text(active.isEmpty ? "Add your first animal" : "Animals")
            }
            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { animal in
                        row(animal)
                            .swipeActions(edge: .trailing) {
                                Button("Unarchive") { animal.isArchived = false; try? context.save() }.tint(.green)
                                Button("Delete", role: .destructive) { delete(animal) }
                            }
                    }
                }
            }
        }
        .overlay {
            if animals.isEmpty {
                ContentUnavailableView("No animals yet", systemImage: "pawprint",
                                       description: Text("Add an animal to start logging."))
            }
        }
        .navigationTitle("Manage Animals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add animal")
            }
            ToolbarItem(placement: .topBarLeading) {
                if !isFirstRun || !active.isEmpty { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(isPresented: $showAdd) { NavigationStack { AnimalFormView(animal: nil) } }
        .sheet(item: $editing) { animal in NavigationStack { AnimalFormView(animal: animal) } }
        .alert("Cannot delete", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK") {}
        } message: { Text(blockedMessage ?? "") }
        .onAppear { if isFirstRun && animals.isEmpty { showAdd = true } }
        .onChange(of: active.count) { _, n in if isFirstRun && n > 0 { dismiss() } }
    }

    private func row(_ animal: Animal) -> some View {
        Button { editing = animal } label: {
            HStack(spacing: 12) {
                AnimalAvatarView(animal: animal, size: 40)
                VStack(alignment: .leading) {
                    Text(animal.name).font(.headline).foregroundStyle(.primary)
                    Text(animal.species).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Renumbers every animal, not just the reordered block, so no two animals share a sortOrder.
    /// SelectedAnimalResolver sorts by sortOrder and that sort is not stable, so duplicates would
    /// make the resolved animal arbitrary.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = active
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, a) in ordered.enumerated() { a.sortOrder = i }
        for (i, a) in archived.enumerated() { a.sortOrder = ordered.count + i }
        try? context.save()
    }

    private func delete(_ animal: Animal) {
        do {
            let counts = try AnimalDeletionPolicy.recordCounts(for: animal, context: context)
            guard counts.values.allSatisfy({ $0 == 0 }) else {
                blockedMessage = "\(animal.name) has \(AnimalDeletionPolicy.summary(counts)). Archive it instead."
                return
            }
            if let photo = animal.photoFilename { mediaStore.delete(photo) }
            if let thumb = animal.photoThumbnailFilename { mediaStore.delete(thumb) }
            context.delete(animal)
            try context.save()
        } catch {
            blockedMessage = error.localizedDescription
        }
    }
}
