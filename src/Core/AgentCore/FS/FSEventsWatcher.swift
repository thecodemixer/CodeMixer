import CoreServices
import Foundation
import OSLog

/// File-change observer with debounce, gitignore filtering, and event-kind
/// decoding. All FSEvents framework calls are confined to `FSEventsStream` in
/// `Core/AgentCore/External/`; this actor sits on top of that stream as a thin
/// policy layer.
public actor FSEventsWatcher {

    public enum WatcherError: Error, Sendable {
        case streamCreateFailed
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FSEvents")
    private let workspace: URL
    private let ignoredPrefixes: [String]
    private let stream: FSEventsStream
    private var continuation: AsyncStream<FSEvent>.Continuation?
    private var bridgeTask: Task<Void, Never>?

    public nonisolated let events: AsyncStream<FSEvent>

    public init(workspace: URL,
                debounce: TimeInterval = 0.2,
                ignoredPrefixes: [String] = [".git/", "node_modules/", ".build/", "DerivedData/"]) {
        self.workspace = workspace
        self.ignoredPrefixes = ignoredPrefixes
        self.stream = FSEventsStream(paths: [workspace.path], debounce: debounce)

        var c: AsyncStream<FSEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.fileSystemEvents)) { c = $0 }
        self.continuation = c
    }

    public func start() async throws {
        do {
            try stream.start()
        } catch FSEventsStream.FSEventsError.streamCreateFailed {
            throw WatcherError.streamCreateFailed
        }
        let upstream = stream.events
        bridgeTask = Task { [weak self] in
            for await raw in upstream {
                await self?.handle(raw)
            }
        }
        log.notice("FSEvents started for \(self.workspace.path, privacy: .public)")
    }

    public func stop() async {
        bridgeTask?.cancel()
        bridgeTask = nil
        stream.stop()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal — policy

    func handle(_ raw: FSEventsStream.RawEvent) {
        guard !isIgnored(raw.path) else { return }
        let kind = decodeKind(raw.flags)
        continuation?.yield(FSEvent(url: URL(fileURLWithPath: raw.path),
                                    kind: kind,
                                    observedAt: raw.observedAt))
    }

    nonisolated func isIgnored(_ path: String) -> Bool {
        let relative = path.hasPrefix(workspace.path)
            ? String(path.dropFirst(workspace.path.count).drop(while: { $0 == "/" }))
            : path
        return ignoredPrefixes.contains { relative.hasPrefix($0) }
    }

    nonisolated func decodeKind(_ flags: FSEventStreamEventFlags) -> FSEvent.Kind {
        let f = Int(flags)
        if f & kFSEventStreamEventFlagItemRemoved != 0 { return .removed }
        if f & kFSEventStreamEventFlagItemRenamed != 0 { return .renamed }
        if f & kFSEventStreamEventFlagItemCreated != 0 { return .created }
        return .modified
    }
}
