import Foundation

/// Filenames persisted under the app-support directory.
public enum AppSupportPaths {
    public static let prefsFileName = "prefs.json"
    public static let sessionsFileName = "sessions.json"
    public static let workspacesFileName = "workspaces.json"
    public static let attachmentsDirectoryName = "attachments"
    public static let remoteServerP12FileName = "remote-server.p12"

    public static func prefsURL(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent(prefsFileName)
    }

    public static func sessionsURL(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent(sessionsFileName)
    }

    public static func workspacesURL(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent(workspacesFileName)
    }

    public static func attachmentsDirectory(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    public static func remoteServerP12URL(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent(remoteServerP12FileName)
    }
}
