// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MatrixKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(
            name: "MatrixKit",
            targets: ["MatrixKit"]
        ),
        .library(
            name: "MatrixKitCrypto",
            targets: ["MatrixKitCrypto"]
        ),
        .library(
            name: "MatrixKitSQLite",
            targets: ["MatrixKitSQLite"]
        ),
        .library(
            name: "MatrixKitSwiftData",
            targets: ["MatrixKitSwiftData"]
        ),
        .library(
            name: "MatrixRTC",
            targets: ["MatrixRTC"]
        ),
        .executable(
            name: "mx",
            targets: ["mx"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "MatrixKit",
            dependencies: [
                "MatrixKitCrypto",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MatrixKitCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite"]),
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .target(
            name: "MatrixKitSQLite",
            dependencies: ["MatrixKit", "CSQLite"]
        ),
        .target(
            name: "MatrixKitSwiftData",
            dependencies: ["MatrixKit"]
        ),
        .target(
            name: "MatrixRTC",
            dependencies: [
                "MatrixKit",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "MatrixRTCTests",
            dependencies: ["MatrixRTC"]
        ),
        .testTarget(
            name: "MatrixKitCryptoTests",
            dependencies: ["MatrixKitCrypto"]
        ),
        .testTarget(
            name: "MatrixKitTests",
            dependencies: ["MatrixKit", "MatrixKitCrypto", "MatrixKitSQLite", "MatrixKitSwiftData"]
        ),
        .executableTarget(
            name: "mx",
            dependencies: [
                "MatrixKit",
                "MatrixKitCrypto",
                "MatrixKitSQLite",
                "MatrixKitSwiftData",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
