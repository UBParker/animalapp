import Foundation
import SwiftData

@Model
final class Animal {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var name: String = ""
    /// Free text; see SpeciesDefaults.suggestions. Never empty after the form validates.
    var species: String = ""
    var colorHex: String = ColorPalette.defaultHex
    /// Relative to Documents/Media/, e.g. "<uuid>-photo.jpg".
    var photoFilename: String?
    var photoThumbnailFilename: String?
    var tracksOutdoorTime: Bool = true
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var note: String?

    init(name: String, species: String, colorHex: String = ColorPalette.defaultHex,
         tracksOutdoorTime: Bool? = nil, sortOrder: Int = 0) {
        self.name = name
        self.species = species
        self.colorHex = colorHex
        self.tracksOutdoorTime = tracksOutdoorTime ?? SpeciesDefaults.tracksOutdoorTime(species)
        self.sortOrder = sortOrder
    }

    var isCat: Bool {
        let words = species.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { ["cat", "cats", "kitten", "kitty"].contains($0) }
    }

    var displayInitial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
}
