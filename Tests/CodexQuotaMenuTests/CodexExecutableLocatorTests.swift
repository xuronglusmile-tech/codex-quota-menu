import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct CodexExecutableLocatorTests {
    @Test
    func testProductionDefaultsUseOnlyChatGPTBundledCodex() {
        let bundledPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let locator = CodexExecutableLocator(
            isExecutable: { $0.path != bundledPath }
        )

        #expect(locator.candidates.map(\.path) == [bundledPath])

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to reject non-bundled Codex executables")
        } catch is CodexExecutableNotFound {
            // Expected actionable production error when the bundled executable is absent.
        } catch {
            Issue.record("Expected CodexExecutableNotFound, got \(error)")
        }
    }

    @Test
    func testReturnsFirstExecutableCandidate() throws {
        let locator = CodexExecutableLocator(
            candidates: [
                URL(fileURLWithPath: "/missing"),
                URL(fileURLWithPath: "/bin/cat")
            ],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
        )

        #expect(try locator.locate().path == "/bin/cat")
    }

    @Test
    func testThrowsActionableErrorWhenNothingExists() {
        let locator = CodexExecutableLocator(
            candidates: [URL(fileURLWithPath: "/missing")],
            isExecutable: { _ in false }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch {
            #expect(error.localizedDescription.contains("ChatGPT"))
        }
    }
}
