// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MySuperwall",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "MySuperwall",
            targets: ["MySuperwall"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MySuperwall",
            dependencies: [],
            path: "Sources/MySuperwall"
        ),
        .testTarget(
            name: "MySuperwallTests",
            dependencies: ["MySuperwall"],
            path: "Tests/MySuperwallTests"
        ),
    ]
)
