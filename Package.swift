// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BunnyGrid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BunnyGrid", targets: ["BunnyGrid"]),
        .library(name: "BunnyGridCore", targets: ["BunnyGridCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
    ],
    targets: [
        .target(
            name: "BunnyGridCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BunnyGrid",
            dependencies: ["BunnyGridCore"]
        ),
        .testTarget(
            name: "BunnyGridCoreTests",
            dependencies: ["BunnyGridCore"]
        ),
    ]
)
