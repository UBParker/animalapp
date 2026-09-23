import AnimalVoiceAudio
import AnimalVoiceStats
import SwiftData
import SwiftUI

struct AskView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \VoiceTag.sortOrder) private var tags: [VoiceTag]
    @StateObject private var recorder = Recorder()
    @StateObject private var player = AudioPlayer()
    @State private var isAnalyzing = false
    @State private var recording: VoiceRecording?
    @State private var results: [(vocalization: Vocalization, result: AskResult)] = []
    @State private var errorMessage: String?
    @State private var permissionDenied = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Button(action: toggle) {
                        Label(recorder.isRecording ? "Stop" : "Record a sound", systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRecording ? .red : .accentColor)
                    .disabled(isAnalyzing || animal == nil)
                    Spacer()
                }
                if recorder.isRecording {
                    Text(String(format: "%.1f s", recorder.elapsedS)).monospacedDigit().frame(maxWidth: .infinity, alignment: .center)
                }
                if isAnalyzing { ProgressView("Analyzing…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
                if let animal {
                    Text("Asks what a new sound from \(animal.name) means, using only \(animal.name)'s labeled sounds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let recording, results.isEmpty, recording.status == .noSounds {
                Section { Text("No sounds detected in that recording.") }
            }
            ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                Section("Sound \(index + 1) at \(String(format: "%.1f", item.vocalization.startS)) s") {
                    AskResultView(vocalization: item.vocalization, result: item.result,
                                  meanings: VoiceTagNames.names(tags, kind: .meaning), player: player) { correct in
                        item.vocalization.meaningTag = correct
                        item.vocalization.overridden = true
                        try? context.save()
                    }
                }
            }
        }
        .onChange(of: recorder.elapsedS) { _, t in
            if recorder.isRecording, t >= RecordView.maxSeconds { finish() }
        }
        .alert("Microphone access needed", isPresented: $permissionDenied) { Button("OK") {} }
        .onDisappear { player.stop() }
    }

    private func toggle() {
        if recorder.isRecording { finish() } else { Task { await begin() } }
    }

    private func begin() async {
        errorMessage = nil
        results = []
        guard await Recorder.requestPermission() else { permissionDenied = true; return }
        do { try recorder.start() } catch { errorMessage = "Could not start recording: \(error)" }
    }

    /// Saves the new recording (so corrections become training data) and predicts each detected sound.
    private func finish() {
        let elapsed = recorder.elapsedS
        guard let url = recorder.stop() else { return }
        guard let animal else { try? FileManager.default.removeItem(at: url); return }
        isAnalyzing = true
        Task {
            defer { isAnalyzing = false }
            var stored: String?
            var inserted: VoiceRecording?
            var saved = false
            do {
                let filename = try mediaStore.saveAudio(from: url)
                stored = filename
                let newRecording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(newRecording)
                inserted = newRecording
                try context.save()
                saved = true
                await AnalysisService.analyze(recording: newRecording, mediaStore: mediaStore, context: context)
                recording = newRecording
                results = try newRecording.sortedVocalizations.map {
                    ($0, try PredictionService.predict(features: $0.features, for: animal, context: context))
                }
            } catch {
                // Only the pre-save failures leave nothing worth keeping: drop the audio file the row
                // would have owned and the row that would otherwise autosave pointing at nothing. A
                // later failure (analysis, prediction) happens on a recording that is legitimately saved.
                if !saved {
                    if let inserted { context.delete(inserted) }
                    if let stored { mediaStore.delete(stored) }
                }
                errorMessage = "Could not process the recording: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct AskResultView: View {
    let vocalization: Vocalization
    let result: AskResult
    let meanings: [String]
    @ObservedObject var player: AudioPlayer
    var onCorrect: (String) -> Void
    @State private var correction: String?

    var body: some View {
        HStack {
            VocalizationPlayButton(vocalization: vocalization, player: player)
            Text(String(format: "%.2f s long", vocalization.durationS)).font(.caption).foregroundStyle(.secondary)
            Text(vocalization.f0Mean.map { String(format: "pitch %.0f Hz", $0) } ?? "unvoiced").font(.caption).foregroundStyle(.secondary)
        }
        if let prediction = result.prediction, let best = prediction.best {
            VStack(alignment: .leading, spacing: 4) {
                Text(best.label).font(.title3.bold())
                Text("\(Int(best.probability * 100))% likely, from \(result.evaluation?.n ?? 0) labeled sounds").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(prediction.probabilities.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, p in
                HStack {
                    Text(label).font(.caption).frame(width: 130, alignment: .leading)
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            if let e = result.evaluation {
                Text("Tested on this animal's own past sounds, the model was right \(Int(e.accuracy * 100))% of the time (leave-one-out, n = \(e.n)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !result.neighbors.isEmpty {
                Text("Closest past sounds").font(.caption.bold())
                ForEach(result.neighbors) { neighbor in
                    HStack {
                        VocalizationPlayButton(vocalization: neighbor, player: player)
                        Text(neighbor.meaningTag ?? "?").font(.caption)
                        Spacer()
                        Text(neighbor.recording?.recordedAt.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else if case let .notReady(message, needed) = result.readiness {
            Text(message).font(.subheadline)
            ForEach(needed.sorted { $0.key < $1.key }, id: \.key) { label, n in
                Text("\(label): \(n) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let hint = result.researchHint {
            VStack(alignment: .leading, spacing: 2) {
                Text(hint).font(.footnote)
                Text(ResearchPrior.attribution).font(.caption2).foregroundStyle(.secondary)
            }
        }
        Picker("This was actually", selection: $correction) {
            Text("Choose").tag(String?.none)
            ForEach(meanings, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .onChange(of: correction) { _, value in
            if let value { onCorrect(value) }
        }
    }
}
