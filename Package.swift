// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperScreenshot",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "SuperScreenshot", targets: ["SuperScreenshot"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.2")
    ],
    targets: [
        .executableTarget(
            name: "SuperScreenshot",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SuperScreenshot",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "SuperScreenshotTests", dependencies: ["SuperScreenshot"], path: "Tests")
    ]
)
