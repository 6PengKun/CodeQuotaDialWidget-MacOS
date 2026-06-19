// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodeQuotaDialWidget",
    platforms: [
        .macOS(.v14)
    ],
    products: [
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
        )
    ],
    targets: [
        .target(
            name: "CodexQuotaCore"
        ),
        .target(
            name: "CodexQuotaDialWidget",
            dependencies: ["CodexQuotaCore"]
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
            name: "ClaudeQuotaCore"
        ),
        .target(
            name: "ClaudeQuotaDialWidget",
            dependencies: ["ClaudeQuotaCore"]
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
            name: "GLMQuotaCore"
        ),
        .target(
            name: "GLMQuotaDialWidget",
            dependencies: ["GLMQuotaCore"]
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
            name: "AntigravityQuotaCore"
        ),
        .target(
            name: "AntigravityQuotaDialWidget",
            dependencies: ["AntigravityQuotaCore"]
        ),
        .executableTarget(
            name: "AntigravityQuotaSnapshotTool",
            dependencies: ["AntigravityQuotaCore"]
        ),
        .testTarget(
            name: "AntigravityQuotaCoreTests",
            dependencies: ["AntigravityQuotaCore"]
        )
    ]
)
