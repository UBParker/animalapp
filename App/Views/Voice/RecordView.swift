import AnimalVoiceAudio
import SwiftData
import SwiftUI

struct RecordView: View {
    static let maxSeconds: TimeInterval = 300

    /// Raised while this view holds a live recorder or an analysis, so the section picker above can
    /// lock itself out rather than unmount the recorder mid-take.
    @Binding var isBusy: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @StateObject private var recorder = Recorder()
    @State private var permissionDenied = false
    @State private var isAnalyzing = false
    @State private var pendingRecording: VoiceRecording?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            WaveformView(levelDb: recorder.levelDb, isActive: recorder.isRecording)
                .frame(height: 120)
                .padding(.horizontal)
            Text(timeString(recorder.elapsedS))
                .font(.system(size: 44, weight: .light, design: .monospaced))
            if isAnalyzing { ProgressView("Analyzing…") }
            Spacer()
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 96, height: 96)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40)).foregroundStyle(.white)
                }
            }
            .disabled(isAnalyzing || animal == nil)
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            if let animal {
                Text("Recording \(animal.name) (\(animal.species)). Up to 5 minutes.").font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer().frame(height: 24)
        }
        .onChange(of: recorder.elapsedS) { _, t in
            if recorder.isRecording, t >= Self.maxSeconds { finish() }
        }
        .onChange(of: recorder.isRecording) { _, recording in isBusy = recording || isAnalyzing }
        .onChange(of: isAnalyzing) { _, analyzing in isBusy = analyzing || recorder.isRecording }
        .onDisappear {
            // Torn down mid-take (the animal changed, or the tab did): keep the audio rather than
            // drop it, by running the same finish the stop button runs.
            if recorder.isRecording { finish() }
            isBusy = false
        }
        .alert("Microphone access needed", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record your animal.")
        }
        .sheet(item: $pendingRecording) { recording in
            NavigationStack { TagSheet(recording: recording) }
        }
    }

    private func toggle() {
        if recorder.isRecording { finish() } else { Task { await begin() } }
    }

    private func begin() async {
        errorMessage = nil
        guard await Recorder.requestPermission() else {
            permissionDenied = true
            return
        }
        do { try recorder.start() } catch { errorMessage = "Could not start recording: \(error)" }
    }

    /// Moves the temp file into the media store, inserts the recording for the selected animal, analyzes, then opens tagging.
    private func finish() {
        let elapsed = recorder.elapsedS
        let animal = animal
        guard let url = recorder.stop() else { return }
        isAnalyzing = true
        Task {
            defer {
                isAnalyzing = false
                try? FileManager.default.removeItem(at: url)
            }
            var stored: String?
            var inserted: VoiceRecording?
            do {
                let filename = try mediaStore.saveAudio(from: url)
                stored = filename
                let recording = VoiceRecording(audioFilename: filename, durationS: elapsed, animal: animal)
                context.insert(recording)
                inserted = recording
                try context.save()
                await AnalysisService.analyze(recording: recording, mediaStore: mediaStore, context: context)
                // Deleted while the analysis ran: a tagging sheet bound to a deleted model traps.
                guard recording.modelContext != nil else { return }
                pendingRecording = recording
            } catch {
                // Saving failed after the audio landed in the store, so drop both halves: the file it
                // would have owned, and the pending row that would otherwise autosave pointing at nothing.
                if let inserted { context.delete(inserted) }
                if let stored { mediaStore.delete(stored) }
                errorMessage = "Could not save the recording: \(error.localizedDescription)"
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d.%d", Int(t) / 60, Int(t) % 60, Int(t * 10) % 10)
    }
}
