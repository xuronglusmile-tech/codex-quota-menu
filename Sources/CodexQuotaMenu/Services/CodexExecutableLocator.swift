import Foundation

protocol CodexExecutableLocating: Sendable {
    func locate() throws -> URL
}

struct CodexExecutableNotFound: LocalizedError {
    var errorDescription: String? {
        "找不到 Codex。请确认 ChatGPT 已安装在 /Applications 并完成登录。"
    }
}

struct CodexExecutableLocator: CodexExecutableLocating {
    let candidates: [URL]
    private let isExecutable: @Sendable (URL) -> Bool

    init(
        candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ],
        isExecutable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    func locate() throws -> URL {
        guard let match = candidates.first(where: isExecutable) else {
            throw CodexExecutableNotFound()
        }
        return match
    }
}
