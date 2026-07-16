// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DirectAPICore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DirectAPICore", targets: ["DirectAPICore"]),
    ],
    targets: [
        .target(name: "DirectAPICore"),
        .testTarget(name: "DirectAPICoreTests", dependencies: ["DirectAPICore"]),
    ]
)
