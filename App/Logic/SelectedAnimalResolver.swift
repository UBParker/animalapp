import Foundation

enum SelectedAnimalResolver {
    /// The stored id if it names a non-archived animal, else the first non-archived animal by sortOrder, else nil.
    static func resolve(storedID: String, animals: [AnimalSnapshot]) -> UUID? {
        // id breaks sortOrder ties, so two animals with the same sortOrder resolve the same way every launch.
        let active = animals.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        if let id = UUID(uuidString: storedID), active.contains(where: { $0.id == id }) {
            return id
        }
        return active.first?.id
    }
}
