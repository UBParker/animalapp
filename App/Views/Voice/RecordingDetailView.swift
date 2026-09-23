import AnimalVoiceAudio
import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss
    @Bindable var recording: VoiceRecording
    @StateObject private var player = AudioPlayer()
    @State private var showTagSheet = false
    @State private var thresholdDb: Double = 20
    @State private var reanalyzing = false
    @State private var confirmDelete = false

    private var isPlayingWhole: Bool { player.playingID == recording.id }

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        if isPlayingWhole {
                            player.stop()
                        } else if mediaStore.exists(recording.audioFilename) {
                            player.play(url: mediaStore.url(for: recording.audioFilename), id: recording.id)
                        }
                    } label: {
                        Label(isPlayingWhole ? "Stop" : "Play recording", systemImage: isPlayingWhole ? "stop.fill" : "play.fill")
                    }
                    .disabled(!mediaStore.exists(recording.audioFilename))
                    Spacer()
                    Text(String(format: "%.1f s", recording.durationS)).foregroundStyle(.secondary)
                }
                if !mediaStore.exists(recording.audioFilename) {
                    Label("Audio file missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Animal", value: recording.animal?.name ?? "Not set")
                LabeledContent("Activity", value: recording.activityTag ?? "Not set")
                LabeledContent("Meaning", value: recording.meaningTag ?? "Not set")
                if !recording.note.isEmpty { Text(recording.note).font(.footnote) }
                Button("Edit tags") { showTagSheet = true }
            }
            Section("Sounds (\(recording.sortedVocalizations.count))") {
                if recording.status == .failed {
                    Text(recording.errorMessage ?? "Analysis failed").foregroundStyle(.red)
                }
                if recording.status == .noSounds {
                    Text("No sounds detected. Lower the threshold below and re-analyze.").foregroundStyle(.secondary)
                }
                ForEach(recording.sortedVocalizations) { v in
                    HStack {
                        VocalizationPlayButton(vocalization: v, player: player)
                        NavigationLink { VocalizationEditView(vocalization: v) } label: { VocalizationRow(vocalization: v) }
                    }
                }
                // Re-analysis deletes every vocalization, so no editor can be pushed onto one while it runs.
                .disabled(reanalyzing)
            }
            Section("Re-analyze") {
                VStack(alignment: .leading) {
                    Text("Detect sounds down to \(Int(thresholdDb)) dB below the loudest one").font(.footnote)
                    Slider(value: $thresholdDb, in: 10...40, step: 1)
                }
                Button(reanalyzing ? "Analyzing…" : "Re-analyze", action: reanalyze).disabled(reanalyzing)
                Text("Replaces the detected sounds and re-applies the recording tags. Per-sound edits are lost.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete recording", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(recording.recordedAt.formatted(date: .abbreviated, time: .shortened))
        .sheet(isPresented: $showTagSheet) { NavigationStack { TagSheet(recording: recording) } }
        .confirmationDialog("Delete this recording and its audio file?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.stop()
                // Dismiss first, then delete: a body re-evaluated after the delete would read a
                // deleted model. The captures keep what the delete needs once `recording` is gone.
                let filename = recording.audioFilename
                let doomed = recording
                dismiss()
                Task { @MainActor in
                    mediaStore.delete(filename)
                    context.delete(doomed)
                    try? context.save()
                }
            }
        }
        .onDisappear { player.stop() }
    }

    private func reanalyze() {
        reanalyzing = true
        var config = SegmenterConfig()
        config.relativeThresholdDb = Float(thresholdDb)
        Task {
            await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context, segmenter: config)
            reanalyzing = false
        }
    }
}

struct VocalizationPlayButton: View {
    let vocalization: Vocalization
    @ObservedObject var player: AudioPlayer
    @Environment(\.mediaStore) private var mediaStore

    var body: some View {
        Button {
            if player.playingID == vocalization.id {
                player.stop()
            } else if let recording = vocalization.recording, mediaStore.exists(recording.audioFilename) {
                player.play(url: mediaStore.url(for: recording.audioFilename), id: vocalization.id,
                            startS: vocalization.startS, endS: vocalization.endS)
            }
        } label: {
            Image(systemName: player.playingID == vocalization.id ? "stop.circle" : "play.circle").font(.title2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Play sound")
    }
}

/// The row's text only: the play button sits beside the row's NavigationLink so it has its own tap target.
struct VocalizationRow: View {
    let vocalization: Vocalization

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "at %.1f s, %.2f s long", vocalization.startS, vocalization.durationS)).font(.subheadline)
                Text(vocalization.f0Mean.map { String(format: "pitch %.0f Hz", $0) } ?? "unvoiced").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(vocalization.meaningTag ?? "untagged").font(.caption)
                if vocalization.overridden { Text("edited").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
}
