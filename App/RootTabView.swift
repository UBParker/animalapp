import SwiftData
import SwiftUI

/// The app's top-level tabs, in display order.
enum RootTab: String, CaseIterable {
    case buttons, feed, poop, health, voice

    var title: String {
        switch self {
        case .buttons: "Buttons"
        case .feed: "Feed"
        case .poop: "Poop"
        case .health: "Health"
        case .voice: "Voice"
        }
    }

    var symbol: String {
        switch self {
        case .buttons: "square.grid.2x2"
        case .feed: "leaf"
        case .poop: "circle.dotted"
        case .health: "heart.text.square"
        case .voice: "waveform"
        }
    }
}

/// Which tabs a build shows. A local-only build hides the placeholder tabs and shows only Voice.
enum RootTabs {
    static func visible(localOnly: Bool) -> [RootTab] {
        localOnly ? [.voice] : RootTab.allCases
    }
}

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
            ForEach(RootTabs.visible(localOnly: AppMode.isLocalOnly), id: \.self) { rootTab in
                tab(rootTab.title, rootTab.symbol) { content(for: rootTab) }
            }
        }
        .environment(\.selectedAnimal, selected)
        .onAppear { syncSelection() }
        .onChange(of: activeKey) { _, _ in syncSelection() }
        .fullScreenCover(isPresented: $showFirstRun) {
            NavigationStack { ManageAnimalsView(isFirstRun: true) }
        }
    }

    @ViewBuilder
    private func content(for rootTab: RootTab) -> some View {
        switch rootTab {
        case .buttons: Text("Buttons")
        case .feed: Text("Feed")
        case .poop: Text("Poop")
        case .health: Text("Health")
        case .voice: VoiceTabView()
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
