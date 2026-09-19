import SwiftData
import SwiftUI

struct RootTabView: View {
    @Query(sort: \Animal.sortOrder) private var animals: [Animal]
    @AppStorage(AppStorageKeys.selectedAnimalId) private var selectedAnimalId = ""
    @State private var showFirstRun = false

    /// Identity of the active set, so archiving or deleting the last animal re-runs syncSelection.
    private var activeKey: String { animals.filter { !$0.isArchived }.map { $0.id.uuidString }.sorted().joined() }

    private var selected: Animal? {
        let id = SelectedAnimalResolver.resolve(storedID: selectedAnimalId, animals: animals.map(AnimalSnapshot.init))
        return animals.first { $0.id == id }
    }

    var body: some View {
        TabView {
            tab("Buttons", "square.grid.2x2") { Text("Buttons") }
            tab("Feed", "leaf") { Text("Feed") }
            tab("Poop", "circle.dotted") { Text("Poop") }
            tab("Health", "heart.text.square") { Text("Health") }
            tab("Voice", "waveform") { Text("Voice") }
        }
        .environment(\.selectedAnimal, selected)
        .onAppear { syncSelection() }
        .onChange(of: activeKey) { _, _ in syncSelection() }
        .fullScreenCover(isPresented: $showFirstRun) {
            NavigationStack { ManageAnimalsView(isFirstRun: true) }
        }
    }

    private func tab<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .animalToolbar()
        }
        .tabItem { Label(title, systemImage: symbol) }
    }

    /// Keeps the stored id valid and opens first-run setup when there is nothing to select.
    private func syncSelection() {
        let resolved = SelectedAnimalResolver.resolve(storedID: selectedAnimalId, animals: animals.map(AnimalSnapshot.init))
        if let resolved, resolved.uuidString != selectedAnimalId { selectedAnimalId = resolved.uuidString }
        showFirstRun = resolved == nil
    }
}
