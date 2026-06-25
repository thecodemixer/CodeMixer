// Tuist manifest — https://docs.tuist.io
//
// Regenerate the Xcode project with:
//   scripts/generate-xcodeproj.swift
// which is equivalent to running `tuist generate` from this directory.
//
// This file is the single source of truth for the GUI Xcode project. There is
// no separate Info.plist — Tuist generates it from `.extendingDefault(with:)`
// above, so all bundle metadata lives here. App Sandbox is off, strict
// concurrency is on, and the two microphone/speech privacy strings are
// declared on the GUI target only.

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
            // .extendingDefault generates all boilerplate (CFBundle*, LSMinimumSystemVersion,
            // NSPrincipalClass, etc.) automatically. We only add the two privacy strings
            // that macOS requires before presenting the microphone / speech prompts.
            infoPlist: .extendingDefault(with: [
                "NSMicrophoneUsageDescription":
                    "Codemixer uses the microphone for voice prompt dictation.",
                "NSSpeechRecognitionUsageDescription":
                    "Codemixer uses speech recognition to transcribe your voice into prompts.",
            ]),
            sources: [
                .glob("**/*.swift", excluding: ["Project.swift"]),
            ],
            dependencies: [
                .package(product: "AgentCore"),
                .package(product: "AgentUI"),
                .package(product: "ClaudeCode"),
                .package(product: "AgentRemoteControl"),
            ],
            settings: .settings(base: guiSettings)
        ),
    ]
)
