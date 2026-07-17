import Foundation
import OSLog
import AgentCore
import AgentRemoteControl
import ClaudeCode
import Codex

/// `codemixerd` — the headless daemon.
///
/// Wires `AgentCore + ClaudeCode + AgentRemoteControl` together with no
/// UI. The Mac app, the future iOS client, and CLI scripts all talk to it
/// over the same WebSocket protocol.
@main
struct CodemixerDaemon {

    static func main() async {
        let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Daemon")
        log.notice("codemixerd starting")

        ChildReaper.shared.install()

        let seams = Seams.live
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()
        let adapter = ClaudeAdapter()
        await AdapterRegistry.shared.register(adapter)
        await AdapterRegistry.shared.register(CodexAdapter())

        let pairing = await RemoteRuntimeCoordinator.makePairing(seams: seams)
        let certificates = RemoteRuntimeCoordinator.makeCertificates(seams: seams)
        let runtime = RemoteRuntimeCoordinator(seams: seams,
                                                 pairing: pairing,
                                                 certificates: certificates)

        do {
            _ = try await runtime.start(
                engine: engine,
                configuration: .init(host: .loopback, requireAuth: false, useTLS: false)
            )
            let fp = await runtime.certificateFingerprint
            log.notice("WebSocket up on \(RemoteDefaults.loopbackHost, privacy: .public):\(RemoteDefaults.webSocketPort, privacy: .public) fp=\(fp ?? "n/a", privacy: .public)")
        } catch {
            log.fault("server failed to start: \(String(describing: error), privacy: .public)")
            exit(1)
        }

        let signalHandling = Task {
            for await _ in signalStream(signals: [SIGTERM, SIGINT]) {
                log.notice("signal received; shutting down")
                await runtime.stop()
                await engine.shutdown(reason: .naturalExit)
                exit(0)
            }
        }

        Task {
            var consecutiveIdleChecks = 0
            while true {
                try? await Task.sleep(for: DaemonDefaults.idleCheckInterval)
                let clients = await runtime.server?.connectedClientCount ?? 0
                let engineState = await engine.currentState
                let isIdle = clients == 0 && (engineState == .stopped || engineState == .stopping)
                consecutiveIdleChecks = isIdle ? consecutiveIdleChecks + 1 : 0
                if consecutiveIdleChecks >= DaemonDefaults.idleExitAfterChecks {
                    log.notice("idle \(DaemonDefaults.idleExitAfterChecks, privacy: .public) min with no clients; exiting")
                    await runtime.stop()
                    await engine.shutdown(reason: .naturalExit)
                    exit(0)
                }
            }
        }

        await signalHandling.value
    }

    private static func signalStream(signals: [Int32]) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            for sig in signals {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig,
                                                             queue: .global(qos: .utility))
                source.setEventHandler { continuation.yield(sig) }
                source.resume()
            }
        }
    }
}
