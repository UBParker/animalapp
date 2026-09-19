import Foundation

/// Value copies of models so logic and IO can be tested without a SwiftData container.
struct AnimalSnapshot: Equatable, Identifiable {
    let id: UUID
    let name: String
    let species: String
    let tracksOutdoorTime: Bool
    let isArchived: Bool
    let sortOrder: Int

    init(id: UUID, name: String, species: String, tracksOutdoorTime: Bool, isArchived: Bool, sortOrder: Int) {
        self.id = id
        self.name = name
        self.species = species
        self.tracksOutdoorTime = tracksOutdoorTime
        self.isArchived = isArchived
        self.sortOrder = sortOrder
    }

    init(_ animal: Animal) {
        self.init(id: animal.id, name: animal.name, species: animal.species, tracksOutdoorTime: animal.tracksOutdoorTime,
                  isArchived: animal.isArchived, sortOrder: animal.sortOrder)
    }
}
