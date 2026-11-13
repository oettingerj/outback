// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DingoKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DingoKit", targets: ["DingoKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        .package(path: "../../../eucalyptus"),
    ],
    targets: [
        .target(name: "DingoKit", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Eucalyptus", package: "eucalyptus"),
        ]),
        .testTarget(name: "DingoKitTests", dependencies: ["DingoKit"], resources: [.copy("Fixtures")]),
    ]
)
