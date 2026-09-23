import AnimalVoiceAudio
import Foundation
import SwiftData

@Model
final class Vocalization {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var startS: Double = 0
    var endS: Double = 0
    var f0Mean: Double?
    var f0Min: Double?
    var f0Max: Double?
    var f0Slope: Double?
    var voicedFraction: Double = 0
    var rmsDb: Double = -160
    var spectralCentroidHz: Double = 0
    var mfcc: [Double] = []
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    /// True once the user edited this sound's tags directly; recording-level tags then leave it alone.
    var overridden: Bool = false
    var recording: VoiceRecording?

    init(segment: Segment, features: VocalFeatures) {
        startS = segment.startS
        endS = segment.endS
        f0Mean = features.f0Mean
        f0Min = features.f0Min
        f0Max = features.f0Max
        f0Slope = features.f0Slope
        voicedFraction = features.voicedFraction
        rmsDb = features.rmsDb
        spectralCentroidHz = features.spectralCentroidHz
        mfcc = features.mfcc
    }

    var durationS: Double { endS - startS }

    var features: VocalFeatures {
        VocalFeatures(durationS: durationS, f0Mean: f0Mean, f0Min: f0Min, f0Max: f0Max, f0Slope: f0Slope,
                      voicedFraction: voicedFraction, rmsDb: rmsDb, spectralCentroidHz: spectralCentroidHz, mfcc: mfcc)
    }

    var featureVector: [Double] { features.vector }
}
