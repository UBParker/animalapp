import SwiftUI
import UIKit

/// The system share sheet, for handing a file to Files, AirDrop, Mail and the rest.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Called when the share sheet finishes, whether an activity ran or it was cancelled. An
    /// activity such as Save to Files dismisses the controller itself, which need not go through
    /// SwiftUI's sheet binding, so a `.sheet` `onDismiss` alone may never run.
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
