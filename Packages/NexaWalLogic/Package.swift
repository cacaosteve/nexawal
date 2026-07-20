// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NexaWalLogic",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NexaWalLogic", targets: ["NexaWalLogic"]),
    ],
    targets: [
        .target(name: "NexaWalLogic"),
        .testTarget(
            name: "NexaWalLogicTests",
            dependencies: ["NexaWalLogic"]
        ),
    ]
)
