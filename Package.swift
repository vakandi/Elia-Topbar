// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EliaTopBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "EliaTopBar",
            path: "Sources",
            exclude: ["Info.plist"]
        )
    ]
)
