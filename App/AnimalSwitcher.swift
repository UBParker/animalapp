import SwiftData
import SwiftUI

/// Nav-bar leading menu: current animal, switch to another, or open Manage Animals.
struct AnimalSwitcher: View {
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @AppStorage(AppStorageKeys.selectedAnimalId) private var selectedAnimalId = ""
    @Environment(\.selectedAnimal) private var selected
    @State private var showManage = false

    var body: some View {
        Menu {
            ForEach(animals.filter { !$0.isArchived }) { animal in
                Button {
                    selectedAnimalId = animal.id.uuidString
                } label: {
                    if animal.id == selected?.id {
                        Label("\(animal.name) (\(animal.species))", systemImage: "checkmark")
                    } else {
                        Text("\(animal.name) (\(animal.species))")
                    }
                }
            }
            Divider()
            Button { showManage = true } label: { Label("Manage Animals", systemImage: "pawprint") }
        } label: {
            HStack(spacing: 6) {
                if let selected {
                    AnimalAvatarView(animal: selected, size: 28)
                    Text(selected.name).font(.headline)
                } else {
                    Image(systemName: "pawprint.circle")
                    Text("No animal").font(.headline)
                }
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("Switch animal")
        .sheet(isPresented: $showManage) { NavigationStack { ManageAnimalsView() } }
    }
}

/// Applies the shared toolbar: animal menu on the left, oral check-in and settings on the right.
struct AnimalToolbar: ViewModifier {
    @State private var showSettings = false
    @State private var showCheckIn = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AnimalSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showCheckIn = true } label: { Image(systemName: "mic.circle") }
                            .accessibilityLabel("Oral check-in")
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
            .sheet(isPresented: $showCheckIn) { OralCheckInEntry() }
    }
}

extension View {
    func animalToolbar() -> some View { modifier(AnimalToolbar()) }
}

/// Placeholder until Plan F supplies the real sheet.
struct OralCheckInEntry: View {
    var body: some View {
        ContentUnavailableView("Oral check-in", systemImage: "mic.circle",
                               description: Text("Talk-to-log arrives in a later update."))
    }
}
