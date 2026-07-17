// Tuist manifest — https://docs.tuist.io
//
// Regenerate the Xcode project with:
//   scripts/generate-xcodeproj.swift
// which is equivalent to running `tuist generate` from this directory.
//
// This file is the single source of truth for the GUI Xcode project. Bundle
// metadata is generated from `.extendingDefault(with:)` below; entitlements
// come from `Codemixer.entitlements`. The legacy `Info.plist` is obsolete.

import ProjectDescription

private let sharedSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.2",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "CODE_SIGN_STYLE": "Automatic",
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "OTHER_SWIFT_FLAGS": "-strict-concurrency=complete",
]

// GUI app overrides: hardened runtime on; no sandbox (tool accesses arbitrary files).
private let guiSettings: SettingsDictionary = [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.codecave.Codemixer",
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
    // No cs.* exemptions needed — we do not load third-party dylibs at runtime.
]

let project = Project(
    name: "Codemixer",
    options: .options(
        defaultKnownRegions: ["en"],
        disableBundleAccessors: false,
        disableSynthesizedResourceAccessors: true
    ),
    packages: [
        .local(path: "../.."),
    ],
    settings: .settings(base: sharedSettings),
    targets: [
        .target(
            name: "Codemixer",
            destinations: .macOS,
            product: .app,
            bundleId: "com.codecave.Codemixer",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSHighResolutionCapable": true,
                "NSSupportsAutomaticGraphicsSwitching": true,
                "NSMicrophoneUsageDescription":
                    "Codemixer uses the microphone for voice prompt dictation.",
                "NSSpeechRecognitionUsageDescription":
                    "Codemixer uses speech recognition to transcribe your voice into prompts.",
                "NSLocalNetworkUsageDescription":
                    "Codemixer can be controlled from your phone over the local network.",
                "NSDocumentsFolderUsageDescription":
                    "Codemixer opens and edits project files in your Documents folder.",
                "NSDownloadsFolderUsageDescription":
                    "Codemixer can read files from your Downloads folder when referenced in prompts.",
                "NSDesktopFolderUsageDescription":
                    "Codemixer can read files from your Desktop when referenced in prompts.",
                "NSAppleEventsUsageDescription":
                    "Codemixer uses Reveal in Finder to show changed files in the diff panel.",
                "NSBonjourServices": ["_codemixer._tcp"],
            ]),
            sources: [
                .glob("**/*.swift", excluding: ["Project.swift"]),
            ],
            resources: [
                "Resources/**",
            ],
            entitlements: .file(path: "Codemixer.entitlements"),
            dependencies: [
                .package(product: "AgentCore"),
                .package(product: "AgentUI"),
                .package(product: "ClaudeCode"),
                .package(product: "Codex"),
                .package(product: "AgentClientProtocol"),
                .package(product: "ACPCLIs"),
                .package(product: "AgentRemoteControl"),
            ],
            settings: .settings(base: guiSettings)
        ),
    ]
)
