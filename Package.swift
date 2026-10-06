// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ShotDesk",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "ShotDesk", path: "Sources/ShotDesk"),
        .testTarget(name: "ShotDeskTests", dependencies: ["ShotDesk"], path: "Tests/ShotDeskTests")
    ]
)
