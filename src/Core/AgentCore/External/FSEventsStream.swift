import CoreServices
import Foundation

/// Single boundary between Codemixer business code and
/// `CoreServices.FSEventStream*`.
///
/// Emits raw `(path, flags, observedAt)` triples. Gitignore filtering and
/// flag-to-kind decoding belong to `FSEventsWatcher`, which sits on top of
/// this stream.
///
/// Modelled as a `final class` rather than an `actor` because the FSEvents
/// callback delivers on a dispatch queue and we need to yield to the
/// `AsyncStream.Continuation` synchronously — going through an `actor` hop
/// drops events under bursts and makes tests racy.
public final class FSEventsStream: @unchecked Sendable {

    public struct RawEvent: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags
        public let observedAt: Date

        public init(path: String, flags: FSEventStreamEventFlags, observedAt: Date) {
            self.path = path
            self.flags = flags
            self.observedAt = observedAt
        }
    }

    public enum FSEventsError: Error, Sendable, Equatable {
        case streamCreateFailed
    }

    /// Hot stream of raw events. Buffered so a slow consumer doesn't lose
    /// observations during a churn burst.
    public let events: AsyncStream<RawEvent>

    private let lock = NSLock()
    private let paths: [String]
    private let debounce: TimeInterval
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<RawEvent>.Continuation

    public init(paths: [String], debounce: TimeInterval = 0.2) {
        self.paths = paths
        self.debounce = debounce
        var c: AsyncStream<RawEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.fileSystemEvents)) { c = $0 }
        self.continuation = c
    }

    /// Begin observing. Throws `streamCreateFailed` if `FSEventStreamCreate`
    /// returns nil. Idempotent.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
            let nsArray = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue()
            let pathStrings = (nsArray as? [String]) ?? []
            let flagsBuf = UnsafeBufferPointer(start: flags, count: count)
            let now = Date()
            for i in 0..<min(count, pathStrings.count) {
                let raw = RawEvent(path: pathStrings[i],
                                   flags: flagsBuf[i],
                                   observedAt: now)
                me.continuation.yield(raw)
            }
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer    |
                           kFSEventStreamCreateFlagIgnoreSelf)

        guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                                callback,
                                                context,
                                                paths as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                debounce,
                                                flags) else {
            context.deinitialize(count: 1); context.deallocate()
            throw FSEventsError.streamCreateFailed
        }

        FSEventStreamSetDispatchQueue(created, .global(qos: .utility))
        FSEventStreamStart(created)
        self.stream = created
    }

    /// Idempotent. Safe to call before `start()` or twice in a row.
    public func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation.finish()
    }
}
