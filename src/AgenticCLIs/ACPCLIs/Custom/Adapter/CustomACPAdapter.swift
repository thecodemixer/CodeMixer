import Foundation

import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Generic ACP CLI adapter for `ProjectType.custom` projects.
///
/// Thin identity + launch + mode-mapping wrapper around `ACPAdapter`, with a
/// project-local session store under `<project>/.codemixer/acp/<id>/`.
public final class CustomACPAdapter: AgentAdapter, ACPBackedAdapter {
    public let id: AgentID = .other
    public let displayName: String
    public let iconSymbol = "terminal"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
        .sessionHandshakeGate,
        .overviewDashboard,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .agentClientProtocol }

    public let ref: CustomAgentRef
    private let locator: CustomACPBinaryLocator
    let inner: ACPAdapter

    public init(ref: CustomAgentRef,
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.ref = ref
        self.displayName = ref.displayName
        self.locator = CustomACPBinaryLocator(
            executablePath: ref.executablePath,
            displayName: ref.displayName,
            environment: environment,
            fileSystem: fileSystem
        )
        let store = ACPProjectSessionStore(
            customAgentID: ref.id,
            environment: environment,
            fileSystem: fileSystem,
            clock: clock
        )
        self.inner = ACPAdapter(
            ref: ref,
            environment: environment,
            fileSystem: fileSystem,
            clock: clock,
            random: random,
            sessionIndex: store
        )
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        do {
            return try locator.locate(env: env)
        } catch let error as CustomACPBinaryLocator.LocateError {
            switch error {
            case .notFound(let checked, let name):
                let locations = checked.prefix(4).joined(separator: ", ")
                throw AgentError.binaryNotFound(
                    agentID: .other,
                    hint: "Install or configure \(name). Checked: \(locations)"
                )
            }
        }
    }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        let exeName = URL(fileURLWithPath: ref.executablePath).lastPathComponent
        return [exeName] + ref.arguments
    }

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        let modes = inner.sessionAvailableModes()
        switch command {
        case .setPermissionMode(let mode):
            guard let modeID = CustomACPModeMapping.modeID(
                forPermissionMode: mode,
                available: modes
            ) else {
                return nil
            }
            return inner.encodeSessionMode(modeID)
        case .runSlashCommand(.builtin(let name), let args):
            if let modeID = CustomACPModeMapping.modeID(forSlash: name, available: modes),
               args.isEmpty {
                return inner.encodeSessionMode(modeID)
            }
            return inner.encodeCommand(command)
        case .setAgentMode(let id):
            guard modes.contains(where: { $0.id == id }) else { return nil }
            return inner.encodeSessionMode(id)
        case .selectModel(let id):
            return inner.encodeCommand(.selectModel(id: id))
        default:
            return inner.encodeCommand(command)
        }
    }

    public var slashCommandCatalog: [SlashCommand] {
        CustomACPModeMapping.slashCatalog(from: inner.sessionAvailableModes())
    }

    public func availableAgentModes() -> [AgentModeOption] {
        CustomACPModeMapping.agentModes(
            from: inner.sessionAvailableModes(),
            currentModeID: inner.sessionCurrentModeID()
        )
    }

    public func availableModels() -> [AgentModelOption] {
        inner.availableModels()
    }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        await inner.listResumableSessions(workspace: workspace)
    }
}
