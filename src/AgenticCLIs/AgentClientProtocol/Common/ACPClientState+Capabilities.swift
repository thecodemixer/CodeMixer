import Foundation

import AgentCore
import AgentProtocol

/// Advertised agent capabilities (load/resume/list session support) plus
/// the current/available session modes and models.
extension ACPClientState {
    func setAgentCapabilities(_ caps: JSONValue?) {
        withLock {
            agentCapabilities = caps
            loadSessionSupported = caps?["loadSession"]?.boolValue == true
            let sessionCaps = caps?["sessionCapabilities"]?.objectValue
            resumeSessionSupported = sessionCaps?["resume"] != nil
            listSessionsSupported = sessionCaps?["list"] != nil
        }
    }

    func supportsLoadSession() -> Bool {
        withLock { loadSessionSupported }
    }

    func supportsResumeSession() -> Bool {
        withLock { resumeSessionSupported }
    }

    func supportsListSessions() -> Bool {
        withLock { listSessionsSupported }
    }

    func setSessionModes(currentModeID: String?, available: [ACPSessionMode]) {
        withLock {
            self.currentModeIDStorage = currentModeID
            self.availableModesStorage = available
        }
    }

    func setCurrentModeID(_ modeID: String) {
        withLock { currentModeIDStorage = modeID }
    }

    func currentModeID() -> String? {
        withLock { currentModeIDStorage }
    }

    func availableModes() -> [ACPSessionMode] {
        withLock { availableModesStorage }
    }

    func setSessionModels(currentModelID: String?, available: [AgentModelOption]) {
        withLock {
            currentModelIDStorage = currentModelID
            availableModelOptions = available
        }
    }

    func setCurrentModelID(_ modelID: String) {
        withLock { currentModelIDStorage = modelID }
    }

    func currentModelID() -> String? {
        withLock { currentModelIDStorage }
    }

    func availableModels() -> [AgentModelOption] {
        withLock { availableModelOptions }
    }
}
