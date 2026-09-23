import SwiftData
import SwiftUI

struct VoiceHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \VoiceRecording.recordedAt, order: .reverse) private var allRecordings: [VoiceRecording]
    @State private var activityFilter: String?
    @State private var meaningFilter: String?

    private var recordings: [VoiceRecording] { allRecordings.filter { $0.animal?.id == animal?.id } }

    private var activities: [String] { Array(Set(recordings.compactMap(\.activityTag))).sorted() }
    private var meanings: [String] {
        let all = recordings.flatMap { r in (r.vocalizations ?? []).compactMap(\.meaningTag) + [r.meaningTag].compactMap { $0 } }
        return Array(Set(all)).sorted()
    }

    private var filtered: [VoiceRecording] {
        recordings.filter { r in
            let activityOK = activityFilter == nil || r.activityTag == activityFilter
            let meaningOK = meaningFilter == nil || r.meaningTag == meaningFilter
                || (r.vocalizations ?? []).contains { $0.meaningTag == meaningFilter }
            return activityOK && meaningOK
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Activity", selection: $activityFilter) {
                    Text("Any activity").tag(String?.none)
                    ForEach(activities, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("Meaning", selection: $meaningFilter) {
                    Text("Any meaning").tag(String?.none)
                    ForEach(meanings, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            Section {
                ForEach(filtered) { recording in
                    NavigationLink { RecordingDetailView(recording: recording) } label: { RecordingRow(recording: recording) }
                }
                .onDelete { offsets in
                    for r in offsets.map({ filtered[$0] }) {
                        mediaStore.delete(r.audioFilename)
                        context.delete(r)
                    }
                    try? context.save()
                }
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Record from the Record section."))
            }
        }
    }
}

struct RecordingRow: View {
    let recording: VoiceRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.recordedAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                Spacer()
                Text(String(format: "%.0f s", recording.durationS)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label("\(recording.vocalizations?.count ?? 0)", systemImage: "waveform")
                if let meaning = recording.meaningTag {
                    Text(meaning).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15)).clipShape(Capsule())
                }
                if let activity = recording.activityTag { Text(activity).foregroundStyle(.secondary) }
                if recording.status == .noSounds { Text("no sounds").foregroundStyle(.secondary) }
                if recording.status == .failed { Text("failed").foregroundStyle(.red) }
            }
            .font(.caption)
        }
    }
}
