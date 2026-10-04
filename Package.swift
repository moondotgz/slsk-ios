// swift-tools-version:5.9
// SoulseekCore is a platform-independent package so the protocol and client
// logic can be unit-tested on Linux CI without Xcode. The iOS app target
// compiles the same sources directly (see project.yml).
import PackageDescription

let package = Package(
    name: "SoulseekCore",
    products: [
        .library(name: "SoulseekCore", targets: ["SoulseekCore"])
    ],
    targets: [
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "SoulseekCore",
            dependencies: ["CZlib"],
            path: "Sources/SoulseekCore"
        ),
        .testTarget(
            name: "SoulseekCoreTests",
            dependencies: ["SoulseekCore"],
            path: "Tests/SoulseekCoreTests"
        )
    ]
)
