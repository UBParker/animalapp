import Foundation

enum SpeciesDefaults {
    static let suggestions = ["horse", "pony", "donkey", "dog", "cat", "goat", "sheep", "cow", "pig", "chicken", "rabbit", "other"]
    private static let outdoorSpecies: Set<String> = ["horse", "pony", "donkey", "goat", "sheep", "cow", "pig", "chicken"]

    /// True for pasture and yard animals; false for dogs, cats, rabbits, and anything unknown.
    static func tracksOutdoorTime(_ species: String) -> Bool {
        outdoorSpecies.contains(species.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
