import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct CodexExecutableLocatorTests {
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
