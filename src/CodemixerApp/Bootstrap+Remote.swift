import Foundation
import AgentCore
import AgentUI
import AgentRemoteControl

extension Bootstrap {

    // MARK: - Remote control

    var isRemoteRunning: Bool { remoteRuntime != nil }

    func stopRemote() async {
        await remoteRuntime?.stop()
        remoteRuntime = nil
    }

    func startRemote(engine: AgentEngine) async {
        guard remoteRuntime == nil else { return }
        let seams = Seams.live
        let pairing = await RemoteRuntimeCoordinator.makePairing(seams: seams)
        self.pairing = pairing
        let certificates = RemoteRuntimeCoordinator.makeCertificates(seams: seams)
        let runtime = RemoteRuntimeCoordinator(seams: seams,
                                                 pairing: pairing,
                                                 certificates: certificates)
        do {
            let remote = try await runtime.start(
                engine: engine,
                configuration: .init(host: remoteHost, requireAuth: true, useTLS: true)
            )
            remoteRuntime = runtime
            remoteFingerprint = await runtime.certificateFingerprint
            // Connected-peer count (server side) → toolbar chip + Settings → Remote.
            await remote.observeClientCount { [weak self] count in
                Task { @MainActor in self?.viewModel?.setConnectedRemoteClients(count) }
            }
        } catch {
            startupError = "Remote control failed to start: \(error.localizedDescription)"
        }
    }

    func setRemoteHost(_ host: RemoteControlServer.BindHost) async {
        remoteHost = host
        guard let remote = await remoteRuntime?.server else { return }
        let config = RemoteControlServer.Configuration(
            host: host,
            port: RemoteDefaults.webSocketPort,
            requireAuth: true,
            useTLS: true
        )
        try? await remote.reconfigure(config)
        remoteFingerprint = await remote.certificateFingerprint
    }

    func remoteSettingsActions() -> RemoteSettingsActions {
        RemoteSettingsActions(
            refresh: { [weak self] in
                await self?.remoteSettingsState(pin: nil) ?? RemoteSettingsState()
            },
            startPairing: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                if await MainActor.run(body: { self.remoteRuntime == nil }) {
                    guard let engine = await MainActor.run(body: { self.engine }) else {
                        return RemoteSettingsState()
                    }
                    await self.startRemote(engine: engine)
                }
                guard let pairing = await MainActor.run(body: { self.pairing }) else {
                    return RemoteSettingsState()
                }
                let pin = await pairing.startNewPairing()
                return await self.remoteSettingsState(pin: pin)
            },
            revoke: { [weak self] token in
                guard let self else { return RemoteSettingsState() }
                guard let pairing = await MainActor.run(body: { self.pairing }) else {
                    return RemoteSettingsState()
                }
                await pairing.revokeToken(token)
                return await self.remoteSettingsState(pin: nil)
            },
            installLaunchAgent: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                do {
                    try await self.launchAgentInstaller.install()
                    return await self.remoteSettingsState(pin: nil, launchAgentDetail: "LaunchAgent installed.")
                } catch {
                    return await self.remoteSettingsState(pin: nil,
                                                          launchAgentDetail: "Install failed: \(error)")
                }
            },
            uninstallLaunchAgent: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                do {
                    try await self.launchAgentInstaller.uninstall()
                    return await self.remoteSettingsState(pin: nil, launchAgentDetail: "LaunchAgent removed.")
                } catch {
                    return await self.remoteSettingsState(pin: nil,
                                                          launchAgentDetail: "Uninstall failed: \(error)")
                }
            },
            enableRemote: { [weak self] enabled in
                guard let self else { return RemoteSettingsState() }
                if enabled {
                    // Grab the engine reference on the main actor, then start the server.
                    if let engine = await MainActor.run(body: { self.engine }) {
                        await self.startRemote(engine: engine)
                    }
                } else {
                    await self.stopRemote()
                }
                return await self.remoteSettingsState(pin: nil)
            },
            setLANEnabled: { [weak self] enabled in
                guard let self else { return RemoteSettingsState() }
                let host: RemoteControlServer.BindHost = enabled ? .lan : .loopback
                await self.setRemoteHost(host)
                return await self.remoteSettingsState(pin: nil)
            }
        )
    }

    func remoteSettingsState(pin: String?, launchAgentDetail: String? = nil) async -> RemoteSettingsState {
        let devices = await pairing?.allPaired().map {
            RemoteSettingsState.Device(id: $0.token,
                                       name: $0.deviceName,
                                       lastSeen: $0.lastSeen)
        } ?? []
        let fingerprint = remoteFingerprint
        let remoteRunning = isRemoteRunning
        let lan = remoteHost == .lan
        return RemoteSettingsState(pin: pin,
                                   certificateFingerprint: fingerprint,
                                   pairingURL: pairingURL(pin: pin, fingerprint: fingerprint),
                                   pairedDevices: devices.sorted { $0.name < $1.name },
                                   connectedClientCount: await remoteRuntime?.server?.connectedClientCount ?? 0,
                                   launchAgentInstalled: await launchAgentInstaller.isInstalled,
                                   launchAgentDetail: launchAgentDetail,
                                   remoteEnabled: remoteRunning,
                                   lanEnabled: lan)
    }

    func pairingURL(pin: String?, fingerprint: String?) -> String? {
        guard let pin, let fingerprint else { return nil }
        let host = remoteHost == .loopback
            ? RemoteDefaults.loopbackHost
            : Seams.live.environment.deviceName
        var components = URLComponents()
        components.scheme = "codemixer"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "\(RemoteDefaults.webSocketPort)"),
            URLQueryItem(name: "pin", value: pin),
            URLQueryItem(name: "fingerprint", value: fingerprint),
        ]
        return components.string
    }
}
