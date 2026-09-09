// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenTracker",
    platforms: [.macOS(.v14)],
    targets: [
        // 无 UI 依赖的核心包：扫描器 / 存储 / 成本 / 配额 / 调度（Phase 1+ 填充）
        .target(
            name: "TokenTrackerCore",
            path: "Sources/TokenTrackerCore"
        ),
        // SwiftUI 桌面壳：状态栏常驻 + 主面板
        .executableTarget(
            name: "TokenTrackerApp",
            dependencies: ["TokenTrackerCore"],
            path: "Sources/TokenTrackerApp"
        ),
        // 原生 CLI：scan / stats / detect / quotas（替代 Python tt）
        .executableTarget(
            name: "tt-swift",
            dependencies: ["TokenTrackerCore"],
            path: "Sources/tt-swift"
        ),
        .testTarget(
            name: "TokenTrackerCoreTests",
            dependencies: ["TokenTrackerCore"],
            path: "Tests/TokenTrackerCoreTests"
        ),
        .testTarget(
            name: "TokenTrackerAppTests",
            dependencies: ["TokenTrackerApp", "TokenTrackerCore"],
            path: "Tests/TokenTrackerAppTests"
        ),
    ]
)
