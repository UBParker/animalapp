import AnimalVoiceAudio
import AnimalVoiceStats
import Foundation
import SwiftData

struct InsightsSummary: Equatable {
    struct Point: Identifiable, Equatable {
        let id: UUID
        let durationS: Double
        let f0Mean: Double
        let meaning: String
    }

    var labeledCount: Int
    var unlabeledCount: Int
    var labelCounts: [String: Int]
    var readiness: ReadinessStatus
    var evaluation: Evaluation?
    var points: [Point]
    /// Meanings in fixed display order (count descending, then name), with "Other" last when folded.
    var legendOrder: [String]
}

enum InsightsModel {
    static let maxSeries = 6
    static let otherLabel = "Other"

    struct Item {
        let id: UUID
        let features: VocalFeatures
        let meaning: String?
    }

    static func summarize(_ items: [Item]) -> InsightsSummary {
        let labeled = items.compactMap { item -> (Item, String)? in
            guard let m = item.meaning, !m.isEmpty, m != VoiceTagSeed.unknownMeaning else { return nil }
            return (item, m)
        }
        var counts: [String: Int] = [:]
        for (_, meaning) in labeled { counts[meaning, default: 0] += 1 }
        let ordered = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let top = Array(ordered.prefix(maxSeries))
        let legend = ordered.count > maxSeries ? top + [otherLabel] : top

        let readiness = Readiness.check(labelCounts: counts)
        var evaluation: Evaluation?
        if case .ready = readiness {
            evaluation = Evaluator.leaveOneOut(labeled.map { LabeledSample(id: $0.0.id, features: $0.0.features.vector, label: $0.1) })
        }
        let points = labeled.compactMap { item, meaning -> InsightsSummary.Point? in
            guard let f0 = item.features.f0Mean else { return nil }
            return InsightsSummary.Point(id: item.id, durationS: item.features.durationS, f0Mean: f0,
                                         meaning: top.contains(meaning) ? meaning : otherLabel)
        }
        return InsightsSummary(labeledCount: labeled.count, unlabeledCount: items.count - labeled.count, labelCounts: counts,
                               readiness: readiness, evaluation: evaluation, points: points, legendOrder: legend)
    }

    @MainActor
    static func summarize(animal: Animal, context: ModelContext) throws -> InsightsSummary {
        let animalID = animal.id
        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.animal?.id == animalID }))
        let items = recordings.flatMap { $0.vocalizations ?? [] }
            .map { Item(id: $0.id, features: $0.features, meaning: $0.meaningTag) }
        return summarize(items)
    }
}
