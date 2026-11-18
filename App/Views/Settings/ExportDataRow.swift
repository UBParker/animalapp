import SwiftData
import SwiftUI

/// The Export row's words, lifted out of the view so they can be asserted.
enum ExportCopy {
    static let button = "Export voice data"

    /// Says how many media files the data names but the export could not include.
    static func missingNotice(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 audio or photo file was missing and is not in the export."
            : "\(count) audio or photo files were missing and are not in the export."
    }

    /// A recovered store is the temporary one opened after the real store failed, so an export of
    /// it is not a backup of the person's history.
    static func recoveredNotice(recovered: Bool) -> String? {
        recovered
            ? "The data store could not be opened, so this export holds only what was recorded since the app started."
            : nil
    }
}

/// Builds a zip of everything in the store and hands it to the share sheet.
struct ExportDataRow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @EnvironmentObject private var store: AppStoreLifecycle
    @State private var isExporting = false
    @State private var archive: ExportArchive?
    /// Kept apart from `archive` because `.sheet(item:)` sets that back to nil before `onDismiss`
    /// runs, which would leave nothing to delete.
    @State private var archiveToRemove: URL?
    @State private var missingCount = 0
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(ExportCopy.button) { Task { await export() } }
                    .disabled(isExporting)
                if isExporting {
                    Spacer()
                    ProgressView()
                }
            }
            if let notice = ExportCopy.recoveredNotice(recovered: store.recovered) {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
            if let notice = ExportCopy.missingNotice(count: missingCount) {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
        .sheet(item: $archive, onDismiss: removeArchive) { archive in
            ShareSheet(items: [archive.url])
        }
    }

    @MainActor
    private func export() async {
        isExporting = true
        defer { isExporting = false }
        missingCount = 0
        errorText = nil
        do {
            // SwiftData models belong to the main actor, so the bundle is read here; only the file
            // copying and zipping leave it.
            let bundle = try ExportBundleBuilder.build(context: context)
            let media = mediaStore
            let result = try await Task.detached(priority: .userInitiated) {
                try ExportWriter.write(bundle: bundle, media: media)
            }.value
            missingCount = result.missingMedia.count
            archiveToRemove = result.archiveURL
            archive = ExportArchive(url: result.archiveURL)
        } catch {
            errorText = String(describing: error)
        }
    }

    /// The zip lives in the temporary directory; once the share sheet has handed it on, nothing
    /// needs it.
    private func removeArchive() {
        if let url = archiveToRemove { try? FileManager.default.removeItem(at: url) }
        archiveToRemove = nil
    }
}

/// The archive the share sheet is presenting. `Identifiable` so `.sheet(item:)` can drive it.
struct ExportArchive: Identifiable {
    let url: URL
    var id: URL { url }
}
