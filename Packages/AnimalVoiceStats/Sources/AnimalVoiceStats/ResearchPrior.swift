import Foundation

/// A one-line hint from published cat-vocalization research. Always shown with `attribution`; never presented as a prediction for this animal.
public enum ResearchPrior {
    public static let attribution =
        "General pattern reported by the Lund University Meowsic project (Schötz et al.). Not a prediction for your animal."

    /// The finding is about domestic cats, so any other species gets nil.
    public static func hint(species: String, durationS: Double, f0Mean: Double?, f0Slope: Double?) -> String? {
        guard species.lowercased().contains("cat"), let f0 = f0Mean, let slope = f0Slope else { return nil }
        if durationS < 0.6, slope > 0, f0 > 500 {
            return "Short, high, rising. In published cat studies this pattern is common in requests and greetings."
        }
        if durationS > 0.8, slope < 0 {
            return "Long and falling. In published cat studies this pattern is common in distress or complaint."
        }
        return nil
    }
}
