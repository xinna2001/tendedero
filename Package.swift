// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipLine",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .target(name: "ClipLineCore"),
        .executableTarget(name: "Tendedero", dependencies: ["ClipLineCore"], path: "Sources/Tendedero", exclude: ["Resources"]),
        .executableTarget(name: "ClipLineCoreChecks", dependencies: ["ClipLineCore"], path: "Tests/ClipLineCoreChecks")
    ]
)
