/// Persists transcript mutations as project-local JSONL. It is deliberately a
/// stateless value; the repository actor owns ordering, buffering, and policy.
import Foundation
import OSLog

struct ProjectSessionTranscriptStore: Sendable {
    let log = Logger(subsystem: AppIdentity.logSubsystem,
                     category: "SessionTranscriptStore")
    let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    func append(_ mutations: [TranscriptMutation],
                to key: SessionTranscriptKey) throws {
        guard !mutations.isEmpty else { return }
        try prepareDirectory(for: key)
        let url = ProjectPaths.transcriptURL(for: key)
        let records = mutations.map(StoredTranscriptRecord.mutation)
        if fileSystem.fileExists(at: url) {
            try fileSystem.append(try encodeLines(records), to: url)
        } else {
            let allRecords = [StoredTranscriptRecord.header(.init(sessionID: key.sessionID))]
                + records
            try fileSystem.createExclusively(try encodeLines(allRecords), at: url)
        }
    }

    func loadMutations(for key: SessionTranscriptKey) throws -> [TranscriptMutation] {
        let url = ProjectPaths.transcriptURL(for: key)
        guard fileSystem.fileExists(at: url) else { return [] }
        let data = try fileSystem.readData(at: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var mutations: [TranscriptMutation] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            do {
                let record = try decoder.decode(StoredTranscriptRecord.self,
                                                from: Data(line))
                switch record {
                case .header(let header):
                    guard index == 0, header.sessionID == key.sessionID else {
                        throw SessionTranscriptStoreError.invalidHeader(path: url.path)
                    }
                case .mutation(let mutation):
                    mutations.append(mutation)
                }
            } catch where index == lines.indices.last {
                log.notice("Ignored truncated transcript tail path=\(url.path, privacy: .private)")
            } catch {
                throw SessionTranscriptStoreError.decodeFailed(
                    path: url.path,
                    detail: String(describing: error)
                )
            }
        }
        return mutations
    }

    func header(for key: SessionTranscriptKey) throws -> StoredTranscriptHeader? {
        let url = ProjectPaths.transcriptURL(for: key)
        guard fileSystem.fileExists(at: url) else { return nil }
        let data = try fileSystem.readData(at: url)
        guard let first = data.split(separator: 0x0A).first else { return nil }
        let record = try decoder.decode(StoredTranscriptRecord.self, from: Data(first))
        guard case .header(let header) = record else {
            throw SessionTranscriptStoreError.invalidHeader(path: url.path)
        }
        return header
    }

    func acquireWriteLock(for key: SessionTranscriptKey,
                          ownerPID: Int32) throws -> TranscriptWriteLock {
        try prepareDirectory(for: key)
        let url = ProjectPaths.transcriptLockURL(for: key)
        try fileSystem.createExclusively(Data(String(ownerPID).utf8), at: url)
        return TranscriptWriteLock(url: url)
    }

    func lockOwnerPID(for key: SessionTranscriptKey) throws -> Int32? {
        let url = ProjectPaths.transcriptLockURL(for: key)
        guard fileSystem.fileExists(at: url) else { return nil }
        let data = try fileSystem.readData(at: url)
        guard let value = String(data: data, encoding: .utf8),
              let pid = Int32(value) else {
            throw SessionTranscriptStoreError.invalidLock(path: url.path)
        }
        return pid
    }

    func releaseWriteLock(_ lock: TranscriptWriteLock) {
        do {
            try fileSystem.remove(at: lock.url)
        } catch let error as FileSystemError {
            if case .notFound = error { return }
            log.error("Failed to release transcript lock path=\(lock.url.path, privacy: .private)")
        } catch {
            log.error("Failed to release transcript lock path=\(lock.url.path, privacy: .private)")
        }
    }

    func deleteJournal(for key: SessionTranscriptKey) throws {
        let url = ProjectPaths.transcriptURL(for: key)
        guard fileSystem.fileExists(at: url) else { return }
        try fileSystem.remove(at: url)
    }

    private func prepareDirectory(for key: SessionTranscriptKey) throws {
        let history = ProjectPaths.historyDirectoryURL(in: key.projectRoot)
        let namespace = ProjectPaths.transcriptDirectoryURL(for: key)
        if !fileSystem.isDirectory(at: history) {
            try fileSystem.createDirectory(at: history, withIntermediates: true)
        }
        if !fileSystem.isDirectory(at: namespace) {
            try fileSystem.createDirectory(at: namespace, withIntermediates: true)
        }
        let ignore = ProjectPaths.historyIgnoreURL(in: key.projectRoot)
        if !fileSystem.fileExists(at: ignore) {
            try fileSystem.createExclusively(Data("*\n".utf8), at: ignore)
        }
    }

    private func encodeLines(_ records: [StoredTranscriptRecord]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }

    var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum SessionTranscriptStoreError: Error, Sendable, Equatable {
    case invalidHeader(path: String)
    case invalidLock(path: String)
    case decodeFailed(path: String, detail: String)
}
