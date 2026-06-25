import Foundation

/// Creates a unique temporary directory for tests.
public enum TempDirectoryFixture {
    public static func make(prefix: String = "codemixer-test") -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
