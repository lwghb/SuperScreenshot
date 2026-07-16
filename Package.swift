// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperScreenshot",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "SuperScreenshot", targets: ["SuperScreenshot"])],
    targets: [
        .executableTarget(name: "SuperScreenshot", path: "Sources/SuperScreenshot"),
        .testTarget(name: "SuperScreenshotTests", dependencies: ["SuperScreenshot"], path: "Tests")
    ]
)
