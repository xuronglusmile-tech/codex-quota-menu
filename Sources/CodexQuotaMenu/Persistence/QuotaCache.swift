import Foundation

protocol QuotaCaching: Sendable {
    func load() async -> QuotaSnapshot?
    func save(_ snapshot: QuotaSnapshot) async throws
}

actor FileQuotaCache: QuotaCaching {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = FileQuotaCache.defaultURL()) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func load() async -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(QuotaSnapshot.self, from: data)
    }

    func save(_ snapshot: QuotaSnapshot) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    static func defaultURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Codex Quota Menu", isDirectory: true)
            .appendingPathComponent("quota-cache.json")
    }
}
