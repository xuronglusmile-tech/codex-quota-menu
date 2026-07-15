import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct ResetCreditRowPresentationTests {
    @Test
    func testFirstTenPositionsUseChineseOrdinalLabels() {
        let labels = (1...10).map(ResetCreditRowPresentation.ordinalLabel)

        #expect(labels == [
            "第一次", "第二次", "第三次", "第四次", "第五次",
            "第六次", "第七次", "第八次", "第九次", "第十次"
        ])
    }

    @Test
    func testLargerPositionUsesUnambiguousNumericFallback() {
        #expect(ResetCreditRowPresentation.ordinalLabel(position: 11) == "第11次")
    }

    @Test
    func testMenuRowsUseOrdinalAndExpirationWithoutBackendCopy() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/CodexQuotaMenu/UI/MenuBarContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("credits.enumerated()"))
        #expect(source.contains("ResetCreditRowPresentation.ordinalLabel"))
        #expect(source.contains("到期："))
        #expect(!source.contains("credit.title"))
        #expect(!source.contains("credit.detail"))
        #expect(!source.contains("Full reset"))
    }

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
