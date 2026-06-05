// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "IPBar",
            path: "Sources/IPBar"
        ),
        .testTarget(
            name: "IPBarTests",
            dependencies: ["IPBar"],
            path: "Tests/IPBarTests"
        )
    ]
)
