// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Codemixer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "ClaudeCode", targets: ["ClaudeCode"]),
        .library(name: "Codex", targets: ["Codex"]),
        .library(name: "AgentClientProtocol", targets: ["AgentClientProtocol"]),
        .library(name: "ACPCLIs", targets: ["ACPCLIs"]),
        .library(name: "AgentRemoteControl", targets: ["AgentRemoteControl"]),
        .library(name: "AgentUI", targets: ["AgentUI"]),
        .library(name: "AgentTestSupport", targets: ["AgentTestSupport"]),
        .executable(name: "codemixerd", targets: ["CodemixerDaemon"]),
        .executable(name: "codemixer", targets: ["CodemixerApp"]),
        .executable(name: "fake-claude", targets: ["FakeClaudeCLI"]),
        .executable(name: "fake-acp", targets: ["FakeACPCLI"]),
        .executable(name: "fake-custom-acp", targets: ["FakeCustomACPCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "CPosixBridge",
            path: "src/Core/CPosixBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AgentProtocol",
            path: "src/Core/AgentProtocol",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentCore",
            dependencies: [
                "CPosixBridge",
                "AgentProtocol",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "src/Core/AgentCore",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ClaudeCode",
            dependencies: ["AgentCore", "AgentProtocol"],
            path: "src/AgenticCLIs/ClaudeCode",
            exclude: [
                "README.md",
                "CONTRACT.md",
                "digital-twin/README.md",
                "digital-twin/fake-claude",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Codex",
            dependencies: ["AgentCore", "AgentProtocol"],
            path: "src/AgenticCLIs/Codex",
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentClientProtocol",
            dependencies: ["AgentCore", "AgentProtocol"],
            path: "src/AgenticCLIs/AgentClientProtocol",
            exclude: [
                "README.md",
                "digital-twin/fake-acp",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ACPCLIs",
            dependencies: ["AgentCore", "AgentProtocol", "AgentClientProtocol"],
            path: "src/AgenticCLIs/ACPCLIs",
            exclude: [
                "README.md",
                "Custom/digital-twin/fake-custom-acp",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentRemoteControl",
            dependencies: ["AgentCore", "AgentProtocol"],
            path: "src/Remote/AgentRemoteControl",
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentUI",
            dependencies: ["AgentCore"],
            path: "src/AgentUI",
            resources: [.process("Resources")],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .target(
            name: "AgentTestSupport",
            dependencies: ["AgentCore", "AgentProtocol"],
            path: "tests/TestSupport/AgentTestSupport",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "FakeClaudeCLI",
            dependencies: ["ClaudeCode"],
            path: "src/AgenticCLIs/ClaudeCode/digital-twin/fake-claude",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "FakeACPCLI",
            dependencies: ["AgentClientProtocol"],
            path: "src/AgenticCLIs/AgentClientProtocol/digital-twin/fake-acp",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "FakeCustomACPCLI",
            dependencies: ["AgentClientProtocol"],
            path: "src/AgenticCLIs/ACPCLIs/Custom/digital-twin/fake-custom-acp",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CodemixerDaemon",
            dependencies: ["AgentCore", "ClaudeCode", "Codex", "AgentClientProtocol", "ACPCLIs", "AgentRemoteControl"],
            path: "src/Remote/CodemixerDaemon",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CodemixerApp",
            dependencies: ["AgentCore", "AgentUI", "ClaudeCode", "Codex", "AgentClientProtocol", "ACPCLIs", "AgentRemoteControl"],
            path: "src/CodemixerApp",
            exclude: [
                "Info.plist",
                "Codemixer.entitlements",
                "Project.swift",
                "Codemixer.xcodeproj",
                "Codemixer.xcworkspace",
                "Derived",
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentProtocolTests",
            dependencies: ["AgentProtocol", "AgentTestSupport"],
            path: "tests/Core/AgentProtocolTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore", "AgentTestSupport", "ClaudeCode"],
            path: "tests/Core/AgentCoreTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ClaudeAdapterTests",
            dependencies: ["ClaudeCode", "AgentTestSupport"],
            path: "tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests",
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CodexAdapterTests",
            dependencies: ["Codex", "AgentTestSupport"],
            path: "tests/AgenticCLIs/Codex/CodexAdapterTests",
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ACPAdapterTests",
            dependencies: ["AgentClientProtocol", "AgentCore", "AgentTestSupport"],
            path: "tests/AgenticCLIs/AgentClientProtocol/ACPAdapterTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CursorACPCLITests",
            dependencies: ["ACPCLIs", "AgentClientProtocol", "AgentCore", "AgentTestSupport"],
            path: "tests/AgenticCLIs/ACPCLIs/CursorACPCLITests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CustomACPCLITests",
            dependencies: ["ACPCLIs", "AgentClientProtocol", "AgentCore", "AgentTestSupport"],
            path: "tests/AgenticCLIs/ACPCLIs/CustomACPCLITests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentRemoteControlTests",
            dependencies: ["AgentRemoteControl", "AgentTestSupport"],
            path: "tests/Remote/AgentRemoteControlTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentUITests",
            dependencies: ["AgentUI", "AgentTestSupport"],
            path: "tests/AgentUITests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RemoteParityTests",
            dependencies: ["AgentCore", "AgentProtocol", "AgentRemoteControl", "AgentTestSupport"],
            path: "tests/Remote/RemoteParityTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ClaudeCodeTwinTests",
            dependencies: ["ClaudeCode", "AgentCore", "AgentProtocol", "AgentTestSupport"],
            path: "tests/AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CodexTwinTests",
            dependencies: ["Codex", "AgentCore", "AgentProtocol", "AgentTestSupport"],
            path: "tests/AgenticCLIs/Codex/CodexTwinTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ACPTwinTests",
            dependencies: ["AgentClientProtocol", "AgentCore", "AgentProtocol", "AgentTestSupport"],
            path: "tests/AgenticCLIs/AgentClientProtocol/ACPTwinTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentTestSupportTests",
            dependencies: ["AgentTestSupport"],
            path: "tests/TestSupport/AgentTestSupportTests",
            swiftSettings: swiftSettings
        ),
    ]
)
