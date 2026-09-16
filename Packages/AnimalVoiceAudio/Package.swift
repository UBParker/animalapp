// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnimalVoiceAudio",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AnimalVoiceAudio", targets: ["AnimalVoiceAudio"])],
    targets: [
        .target(
            name: "AnimalVoiceAudio",
            linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("AVFoundation")]
        ),
        .testTarget(
            name: "AnimalVoiceAudioTests",
            dependencies: ["AnimalVoiceAudio"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
