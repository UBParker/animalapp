import SwiftUI

struct AnimalAvatarView: View {
    let animal: Animal
    var size: CGFloat = 32
    @Environment(\.mediaStore) private var mediaStore

    var body: some View {
        ZStack {
            Circle().fill(ColorPalette.color(animal.colorHex))
            if let thumb = animal.photoThumbnailFilename, mediaStore.exists(thumb),
               let image = UIImage(contentsOfFile: mediaStore.url(for: thumb).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(animal.displayInitial)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.contrastingText(on: animal.colorHex))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(animal.name)
    }
}
