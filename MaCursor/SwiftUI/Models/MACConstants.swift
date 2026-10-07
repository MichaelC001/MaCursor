import Foundation

enum MACCursorScaleValue: Int, CaseIterable {
    case none = 0
    case x1   = 100
    case x2   = 200
    case x5   = 500
    case x10  = 1000

    static func from(scale: CGFloat) -> MACCursorScaleValue {
        guard scale >= 0 else { return .none }
        return MACCursorScaleValue(rawValue: Int(scale * 100)) ?? .none
    }
}

enum MACConstants {


    static let errorDomain = "com.writronic.macursor.error"


    static let websiteURL = URL(string: "https://writronic.com")!
    static let donateURL  = URL(string: "https://writronic.com/donate")!

    static func copyrightYear(at date: Date) -> String {
        String(Calendar(identifier: .gregorian).component(.year, from: date))
    }


    enum ErrorCode: Int {
        case invalidTheme             = -1
        case writeFail                = -2
        case invalidFormat            = -100
        case multipleCursorIdentifiers = -101
        case slotOrderConflict        = -102
    }
}
