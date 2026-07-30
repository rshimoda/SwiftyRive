// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftyRive",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SwiftyRive", targets: ["SwiftyRive"]),
        // Demo app (macOS only): `swift run RiveInspector [file.riv]`.
        .executable(name: "RiveInspector", targets: ["RiveInspector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/rive-app/rive-ios", from: "6.22.0"),
    ],
    targets: [
        .target(
            name: "SwiftyRive",
            dependencies: [
                .product(name: "RiveRuntime", package: "rive-ios"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .executableTarget(
            name: "RiveInspector",
            dependencies: ["SwiftyRive"],
            path: "Examples/RiveInspector",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "SwiftyRiveTests",
            dependencies: ["SwiftyRive"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
