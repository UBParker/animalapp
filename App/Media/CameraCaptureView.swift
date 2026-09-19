import SwiftUI
import UIKit

/// UIImagePickerController in camera mode. Photo returns JPEG data; video returns the temporary movie URL.
struct CameraCaptureView: UIViewControllerRepresentable {
    enum Mode { case photo, video }

    var mode: Mode
    var maxVideoSeconds: TimeInterval = 60
    var onPhoto: (Data) -> Void = { _ in }
    var onVideo: (URL) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    static var isCameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.isCameraAvailable ? .camera : .photoLibrary
        picker.mediaTypes = mode == .photo ? ["public.image"] : ["public.movie"]
        if mode == .video {
            picker.videoMaximumDuration = maxVideoSeconds
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                parent.onPhoto(data)
            } else if let url = info[.mediaURL] as? URL {
                parent.onVideo(url)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
