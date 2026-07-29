// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

var products: [Product] = [
    .library(name: "ConductorFoundation", targets: ["ConductorFoundation"]),
    .library(name: "SharedConductorData", targets: ["SharedConductorData"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.6.6"),
]

var targets: [Target] = [
    .target(
        name: "ConductorFoundation",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
        ],
        path: "ConductorFoundation/Sources",
        swiftSettings: swiftSettings
    ),
    .target(
        name: "SharedConductorData",
        dependencies: [
            .product(name: "SQLiteData", package: "sqlite-data"),
        ],
        path: "SharedConductorData/Sources",
        swiftSettings: swiftSettings
    ),
]

#if canImport(Darwin)
products.append(
    .library(name: "SharedConductorDesign", targets: ["SharedConductorDesign"])
)
dependencies.append(
    .package(url: "https://github.com/JakubMazur/lucide-icons-swift", exact: "1.23.0")
)
targets.append(
    .target(
        name: "SharedConductorDesign",
        dependencies: [
            .product(name: "LucideIcons", package: "lucide-icons-swift"),
        ],
        path: "SharedConductorDesign/Sources",
        resources: [
            .process("Fonts"),
        ],
        swiftSettings: swiftSettings
    )
)
#endif

targets.append(
    .testTarget(
        name: "SharedConductorDataTests",
        dependencies: [
            "SharedConductorData",
        ],
        path: "SharedConductorData/Tests",
        swiftSettings: swiftSettings
    )
)

let package = Package(
    name: "ConductorShared",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
