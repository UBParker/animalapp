import Foundation

enum TagPropagation {
    /// Copies the recording's tags onto every vocalization the user has not overridden.
    static func apply(to recording: VoiceRecording) {
        for v in recording.vocalizations ?? [] where !v.overridden {
            v.activityTag = recording.activityTag
            v.meaningTag = recording.meaningTag
            v.userConfidence = recording.userConfidence
        }
    }

    /// True when any of the sound's tags differ from its recording's tags.
    static func differsFromRecording(_ v: Vocalization) -> Bool {
        guard let r = v.recording else { return false }
        return v.activityTag != r.activityTag || v.meaningTag != r.meaningTag || v.userConfidence != r.userConfidence
    }

    /// Drops a per-sound override and re-applies the recording's tags.
    static func resetOverride(_ v: Vocalization) {
        v.overridden = false
        guard let r = v.recording else { return }
        v.activityTag = r.activityTag
        v.meaningTag = r.meaningTag
        v.userConfidence = r.userConfidence
    }
}
