import SwiftData
import UIKit
@testable import AnimalTracker

enum TestSupport {
    /// A ModelContext does not keep its ModelContainer alive, so a test that holds only
    /// `TestSupport.container().mainContext` traps inside SwiftData once the container
    /// deallocates. Hold every container made for a test for the life of the test process.
    private static var retained: [ModelContainer] = []

    static func container() throws -> ModelContainer {
        let container = try PersistenceController.makeContainer(inMemory: true)
        retained.append(container)
        return container
    }
}

enum TestImages {
    static func jpeg(width: Int, height: Int) -> Data {
        // scale 1 so the rendered image is exactly width x height PIXELS on every
        // simulator; the default format uses the screen scale (2x or 3x).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }
}
