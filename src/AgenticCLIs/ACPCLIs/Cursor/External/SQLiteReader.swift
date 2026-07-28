/// Read-only SQLite boundary for Cursor's vendor-owned workspace databases.
import Foundation
import SQLite3

protocol SQLiteReading: Sendable {
    func rows(in databaseURL: URL,
              query: String,
              textBindings: [String]) throws -> [[String: Data]]
}

struct SQLiteReader: SQLiteReading {
    enum ReaderError: Error, Equatable {
        case open(path: String, message: String)
        case prepare(message: String)
        case bind(index: Int, message: String)
        case step(message: String)
    }

    func rows(in databaseURL: URL,
              query: String,
              textBindings: [String] = []) throws -> [[String: Data]] {
        let database = try openDatabase(at: databaseURL)
        defer { sqlite3_close(database) }
        let statement = try prepare(query, in: database)
        defer { sqlite3_finalize(statement) }
        try bind(textBindings, to: statement, database: database)
        return try readRows(from: statement, database: database)
    }

    private func openDatabase(at databaseURL: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let readOnlyURL = databaseURL.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(readOnlyURL, &database, flags, nil) == SQLITE_OK,
              let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw ReaderError.open(path: databaseURL.path, message: message)
        }
        return database
    }

    private func prepare(_ query: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ReaderError.prepare(message: String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ textBindings: [String],
                      to statement: OpaquePointer,
                      database: OpaquePointer) throws {
        for (offset, binding) in textBindings.enumerated() {
            let index = Int32(offset + 1)
            guard sqlite3_bind_text(statement,
                                    index,
                                    binding,
                                    -1,
                                    Self.sqliteTransient) == SQLITE_OK else {
                throw ReaderError.bind(index: offset + 1,
                                       message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func readRows(from statement: OpaquePointer,
                          database: OpaquePointer) throws -> [[String: Data]] {
        var output: [[String: Data]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: Data] = [:]
                for column in 0 ..< sqlite3_column_count(statement) {
                    guard let name = sqlite3_column_name(statement, column) else {
                        continue
                    }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row[String(cString: name)] = Data(bytes: bytes, count: count)
                    } else {
                        row[String(cString: name)] = Data()
                    }
                }
                output.append(row)
            case SQLITE_DONE:
                return output
            default:
                throw ReaderError.step(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    // SQLite copies Swift's temporary UTF-8 buffer before `bind_text` returns.
    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
