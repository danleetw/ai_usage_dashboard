// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AiDashWidgetMac",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "AiDashWidgetCore",
            path: "Sources/AiDashWidgetCore"
        ),
        .executableTarget(
            name: "AiDashWidgetMac",
            dependencies: ["AiDashWidgetCore"],
            path: "Sources/AiDashWidgetMac"
        ),
        .executableTarget(
            name: "AiDashWidgetMiniMac",
            dependencies: ["AiDashWidgetCore"],
            path: "Sources/AiDashWidgetMiniMac"
        ),
    ]
)
