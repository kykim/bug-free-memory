// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "hello",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.4.0"),
        .package(url: "https://github.com/kykim/clerk-vapor.git", from: "0.0.6"),
    ],
    targets: [
        .executableTarget(
            name: "hello",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "ClerkVapor", package: "clerk-vapor"),
                .product(name: "ClerkLeaf", package: "clerk-vapor"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "helloTests",
            dependencies: [
                .target(name: "hello"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
