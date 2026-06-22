// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodeQuotaDialWidget",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "QuotaProcessSupport",
            targets: ["QuotaProcessSupport"]
        ),
        .library(
            name: "QuotaDialWidgetUI",
            targets: ["QuotaDialWidgetUI"]
        ),
        .library(
            name: "CodexQuotaCore",
            targets: ["CodexQuotaCore"]
        ),
        .library(
            name: "CodexQuotaDialWidget",
            targets: ["CodexQuotaDialWidget"]
        ),
        .executable(
            name: "CodexQuotaSnapshotTool",
            targets: ["CodexQuotaSnapshotTool"]
        ),
        .library(
            name: "ClaudeQuotaCore",
            targets: ["ClaudeQuotaCore"]
        ),
        .library(
            name: "ClaudeQuotaDialWidget",
            targets: ["ClaudeQuotaDialWidget"]
        ),
        .executable(
            name: "ClaudeQuotaSnapshotTool",
            targets: ["ClaudeQuotaSnapshotTool"]
        ),
        .library(
            name: "GLMQuotaCore",
            targets: ["GLMQuotaCore"]
        ),
        .library(
            name: "GLMQuotaDialWidget",
            targets: ["GLMQuotaDialWidget"]
        ),
        .executable(
            name: "GLMQuotaSnapshotTool",
            targets: ["GLMQuotaSnapshotTool"]
        ),
        .library(
            name: "AntigravityQuotaCore",
            targets: ["AntigravityQuotaCore"]
        ),
        .library(
            name: "AntigravityQuotaDialWidget",
            targets: ["AntigravityQuotaDialWidget"]
        ),
        .executable(
            name: "AntigravityQuotaSnapshotTool",
            targets: ["AntigravityQuotaSnapshotTool"]
        ),
        .library(
            name: "UsageQuotaCore",
            targets: ["UsageQuotaCore"]
        ),
        .library(
            name: "UsageQuotaDialWidget",
            targets: ["UsageQuotaDialWidget"]
        ),
        .executable(
            name: "UsageQuotaSnapshotTool",
            targets: ["UsageQuotaSnapshotTool"]
        )
    ],
    targets: [
        .target(
            name: "QuotaProcessSupport"
        ),
        .target(
            name: "QuotaDialWidgetUI"
        ),
        .target(
            name: "CodexQuotaCore",
            dependencies: ["QuotaProcessSupport"]
        ),
        .target(
            name: "CodexQuotaDialWidget",
            dependencies: ["CodexQuotaCore", "QuotaDialWidgetUI"]
        ),
        .executableTarget(
            name: "CodexQuotaSnapshotTool",
            dependencies: ["CodexQuotaCore"]
        ),
        .testTarget(
            name: "CodexQuotaCoreTests",
            dependencies: ["CodexQuotaCore"]
        ),
        .target(
            name: "ClaudeQuotaCore",
            dependencies: ["QuotaProcessSupport"]
        ),
        .target(
            name: "ClaudeQuotaDialWidget",
            dependencies: ["ClaudeQuotaCore", "QuotaDialWidgetUI"]
        ),
        .executableTarget(
            name: "ClaudeQuotaSnapshotTool",
            dependencies: ["ClaudeQuotaCore"]
        ),
        .testTarget(
            name: "ClaudeQuotaCoreTests",
            dependencies: ["ClaudeQuotaCore"]
        ),
        .target(
            name: "GLMQuotaCore",
            dependencies: ["QuotaProcessSupport"]
        ),
        .target(
            name: "GLMQuotaDialWidget",
            dependencies: ["GLMQuotaCore", "QuotaDialWidgetUI"]
        ),
        .executableTarget(
            name: "GLMQuotaSnapshotTool",
            dependencies: ["GLMQuotaCore"]
        ),
        .testTarget(
            name: "GLMQuotaCoreTests",
            dependencies: ["GLMQuotaCore"]
        ),
        .target(
            name: "AntigravityQuotaCore",
            dependencies: ["QuotaProcessSupport"]
        ),
        .target(
            name: "AntigravityQuotaDialWidget",
            dependencies: ["AntigravityQuotaCore", "QuotaDialWidgetUI"]
        ),
        .executableTarget(
            name: "AntigravityQuotaSnapshotTool",
            dependencies: ["AntigravityQuotaCore"]
        ),
        .testTarget(
            name: "AntigravityQuotaCoreTests",
            dependencies: ["AntigravityQuotaCore"]
        ),
        .target(
            name: "UsageQuotaCore",
            dependencies: ["QuotaProcessSupport"]
        ),
        .target(
            name: "UsageQuotaDialWidget",
            dependencies: ["UsageQuotaCore"]
        ),
        .executableTarget(
            name: "UsageQuotaSnapshotTool",
            dependencies: ["UsageQuotaCore"]
        ),
        .testTarget(
            name: "UsageQuotaCoreTests",
            dependencies: ["UsageQuotaCore"]
        )
    ]
)
