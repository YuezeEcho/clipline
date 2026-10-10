// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Clipline", path: "Sources/Tendedero")
    ]
)
