// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InterlaceClient",
    platforms: [.iOS("26.0"), .macOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "InterlaceClient", targets: ["InterlaceClient"]),
    ],
    targets: [
        .target(name: "InterlaceClient"),
        .testTarget(
            name: "InterlaceClientTests",
            dependencies: ["InterlaceClient"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
