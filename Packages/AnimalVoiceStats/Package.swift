// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnimalVoiceStats",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AnimalVoiceStats", targets: ["AnimalVoiceStats"])],
    targets: [
        .target(name: "AnimalVoiceStats"),
        .testTarget(name: "AnimalVoiceStatsTests", dependencies: ["AnimalVoiceStats"]),
    ]
)
