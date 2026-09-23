import AnimalVoiceAudio
import AnimalVoiceStats
import Foundation
import SwiftData

struct AskResult {
    var readiness: ReadinessStatus
    var prediction: Prediction?
    var evaluation: Evaluation?
    var neighbors: [Vocalization]
    var researchHint: String?
}

enum PredictionService {
    /// Everything about one animal's training data that does not change from sound to sound within a
    /// single Ask batch: the labeled samples, their counts, readiness, and the leave-one-out
    /// evaluation. Built once per batch, because leave-one-out is O(n^2) ensemble fits and running it
    /// again for every sound in a five-sound recording is five times the work for the same number.
    struct Context {
        var species: String
        var labeled: [(sample: LabeledSample, vocalization: Vocalization)]
        var counts: [String: Int]
        var readiness: ReadinessStatus
        var evaluation: Evaluation?
    }

    /// The animal's sounds that carry a real meaning label (not empty, not "Unknown").
    @MainActor
    static func labeledSamples(for animal: Animal, context: ModelContext) throws -> [(sample: LabeledSample, vocalization: Vocalization)] {
        let animalID = animal.id
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
        return recordings
            .flatMap { $0.vocalizations ?? [] }
            .compactMap { v in
                guard let label = v.meaningTag, !label.isEmpty, label != VoiceTagSeed.unknownMeaning else { return nil }
                return (LabeledSample(id: v.id, features: v.featureVector, label: label), v)
            }
    }

    /// Reads the store on the main actor, then scores the evaluation off it: `LabeledSample` is a
    /// value type, so the detached task never touches a model object.
    @MainActor
    static func makeContext(for animal: Animal, context: ModelContext) async throws -> Context {
        let labeled = try labeledSamples(for: animal, context: context)
        var counts: [String: Int] = [:]
        for item in labeled { counts[item.sample.label, default: 0] += 1 }
        let readiness = Readiness.check(labelCounts: counts)
        var evaluation: Evaluation?
        if case .ready = readiness {
            let samples = labeled.map(\.sample)
            evaluation = await Task.detached(priority: .userInitiated) { Evaluator.leaveOneOut(samples) }.value
        }
        return Context(species: animal.species, labeled: labeled, counts: counts,
                       readiness: readiness, evaluation: evaluation)
    }

    /// Scores one sound against an already-built batch context.
    @MainActor
    static func predict(features: VocalFeatures, in batch: Context) -> AskResult {
        let hint = ResearchPrior.hint(species: batch.species, durationS: features.durationS,
                                      f0Mean: features.f0Mean, f0Slope: features.f0Slope)
        guard case .ready = batch.readiness else {
            return AskResult(readiness: batch.readiness, prediction: nil, evaluation: nil, neighbors: [], researchHint: hint)
        }
        let prediction = Ensemble().predict(query: features.vector, training: batch.labeled.map(\.sample))
        let byID = Dictionary(batch.labeled.map { ($0.vocalization.id, $0.vocalization) }, uniquingKeysWith: { first, _ in first })
        let neighbors = prediction.neighborIds.compactMap { byID[$0] }
        return AskResult(readiness: batch.readiness, prediction: prediction, evaluation: batch.evaluation,
                         neighbors: neighbors, researchHint: hint)
    }

    /// One sound on its own. A batch of sounds should build a `Context` once and reuse it.
    @MainActor
    static func predict(features: VocalFeatures, for animal: Animal, context: ModelContext) async throws -> AskResult {
        predict(features: features, in: try await makeContext(for: animal, context: context))
    }
}
