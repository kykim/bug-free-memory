// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hello",
    platforms: [
       .macOS(.v15)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.4.0"),
        .package(url: "https://github.com/apple/swift-temporal-sdk.git", .upToNextMinor(from: "0.6.0")),
        .package(url: "https://github.com/kykim/clerk-vapor.git", from: "0.0.6"),
        .package(url: "https://github.com/kykim/tiingo-kit.git", from: "0.0.2"),
    ],
    targets: [
        .executableTarget(
            name: "bug-free-memory",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Temporal", package: "swift-temporal-sdk"),
                .product(name: "ClerkVapor", package: "clerk-vapor"),
                .product(name: "ClerkLeaf", package: "clerk-vapor"),
                .product(name: "TiingoKit", package: "tiingo-kit")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "bug-free-memoryTests",
            dependencies: [
                .target(name: "bug-free-memory"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
