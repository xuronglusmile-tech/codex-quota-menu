import Foundation

enum ResetCreditRowPresentation {
    private static let chineseNumerals = [
        "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"
    ]

    static func ordinalLabel(position: Int) -> String {
        precondition(position > 0)
        guard position <= chineseNumerals.count else {
            return "第\(position)次"
        }
        return "第\(chineseNumerals[position - 1])次"
    }
}
