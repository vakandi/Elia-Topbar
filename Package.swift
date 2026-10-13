// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EliaTopBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "EliaTopBarKit",
            path: "Lib"
        ),
        .executableTarget(
            name: "EliaTopBar",
            dependencies: ["EliaTopBarKit"],
            path: "Sources",
            exclude: ["Info.plist", "AppIcon.icns"]
        ),
        // XCTest and Swift Testing are both unavailable on this CLT-only
        // machine (no Xcode toolchain, _Testing_Foundation ships without a
        // swiftmodule), so the regression suite is a plain executable that
        // asserts and exits non-zero. Same guarantees, actually runnable here.
        .executableTarget(
            name: "PerfTests",
            dependencies: ["EliaTopBarKit"],
            path: "Tests/PerfTests"
        ),
    ]
)
