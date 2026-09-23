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

    @MainActor
    static func predict(features: VocalFeatures, for animal: Animal, context: ModelContext) throws -> AskResult {
        let labeled = try labeledSamples(for: animal, context: context)
        var counts: [String: Int] = [:]
        for item in labeled { counts[item.sample.label, default: 0] += 1 }
        let readiness = Readiness.check(labelCounts: counts)
        let hint = ResearchPrior.hint(species: animal.species, durationS: features.durationS, f0Mean: features.f0Mean, f0Slope: features.f0Slope)
        guard case .ready = readiness else {
            return AskResult(readiness: readiness, prediction: nil, evaluation: nil, neighbors: [], researchHint: hint)
        }
        let samples = labeled.map(\.sample)
        let prediction = Ensemble().predict(query: features.vector, training: samples)
        let evaluation = Evaluator.leaveOneOut(samples)
        let byID = Dictionary(labeled.map { ($0.vocalization.id, $0.vocalization) }, uniquingKeysWith: { first, _ in first })
        let neighbors = prediction.neighborIds.compactMap { byID[$0] }
        return AskResult(readiness: readiness, prediction: prediction, evaluation: evaluation, neighbors: neighbors, researchHint: hint)
    }
}
