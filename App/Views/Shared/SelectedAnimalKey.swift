import SwiftUI

private struct SelectedAnimalKey: EnvironmentKey {
    static let defaultValue: Animal? = nil
}

extension EnvironmentValues {
    /// The animal every tab shows. Resolved once in RootTabView.
    var selectedAnimal: Animal? {
        get { self[SelectedAnimalKey.self] }
        set { self[SelectedAnimalKey.self] = newValue }
    }
}

enum AppStorageKeys {
    static let selectedAnimalId = "selectedAnimalId"
}
