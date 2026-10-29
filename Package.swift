// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinWriter",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WinWriterCore", targets: ["WinWriterCore"]),
        .executable(name: "WinWriter", targets: ["WinWriter"])
    ],
    targets: [
        .target(name: "WinWriterCore"),
        .executableTarget(
            name: "WinWriter",
            dependencies: ["WinWriterCore"],
            path: "Sources/WinWriterApp",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "WinWriterCoreTests", dependencies: ["WinWriterCore"])
    ],
    swiftLanguageVersions: [.v5]
)
