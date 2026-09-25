// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrintMaeEngine",
    defaultLocalization: "ja",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "PrintMaeEngine", targets: ["PrintMaeEngine"]),
        .library(name: "PrintMaeStoreKit", targets: ["PrintMaeStoreKit"]),
        .executable(name: "printmae-harness", targets: ["PrintMaeHarness"])
    ],
    targets: [
        .target(
            name: "PrintMaeEngine",
            resources: [.process("Resources")]
        ),
        .target(
            name: "PrintMaeStoreKit",
            dependencies: ["PrintMaeEngine"]
        ),
        .executableTarget(
            name: "PrintMaeHarness",
            dependencies: ["PrintMaeEngine"]
        ),
        .testTarget(
            name: "PrintMaeEngineTests",
            dependencies: ["PrintMaeEngine", "PrintMaeStoreKit"],
            resources: [.process("Fixtures")]
        )
    ]
)
