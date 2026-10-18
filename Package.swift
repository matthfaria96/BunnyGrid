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
        // SSH tunnel (MIT). Citadel pins its swift-nio-ssh fork; it is listed here only so the core can import NIOSSH.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // Auto-updates (MIT). Linked always but inert unless the release sets SUFeedURL + SUPublicEDKey
        // (scripts/release.sh, BUNNYGRID_SPARKLE_FEED_URL / BUNNYGRID_SPARKLE_PUBLIC_KEY).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "BunnyGridCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BunnyGrid",
            dependencies: [
                "BunnyGridCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/Icons"), .copy("Resources/Licenses")],
            // Sparkle.framework is embedded in Contents/Frameworks (scripts/bundle.sh, scripts/release.sh);
            // SwiftPM's own @loader_path rpath keeps `swift run` working from the build directory.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BunnyGridCoreTests",
            dependencies: [
                "BunnyGridCore",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
    ]
)
