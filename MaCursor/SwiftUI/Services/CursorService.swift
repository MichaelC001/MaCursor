import Foundation

@MainActor
enum CursorService {
    static func applyTheme(atPath path: String) -> Bool {
        guard themeFileHasApplicableCursor(atPath: path) else {
            NSLog("MaCursor: refusing to apply %@ — no cursor in it has both an image and a known cursor type", path)
            return false
        }
        return MACCursorActions.shared.applyTheme(atPath: path)
    }

    nonisolated static func themeFileHasApplicableCursor(atPath path: String) -> Bool {
        guard let theme = NSDictionary(contentsOf: URL(fileURLWithPath: path)) as? [String: Any],
              let cursors = theme[MACCursorDefinitions.cursorsKey] as? [String: Any] else { return false }

        return cursors.contains { identifier, entry in
            guard MACCursorDefinitions.isKnownIdentifier(identifier),
                  let cursor = entry as? [String: Any],
                  let representations = cursor[MACCursorDefinitions.representationsKey] as? [Any] else { return false }
            return !representations.isEmpty
        }
    }

    static func applyTheme(from library: CursorLibrary) -> Bool {
        guard let path = library.fileURL?.path else {
            return false
        }
        return applyTheme(atPath: path)
    }

    @discardableResult
    static func restoreAll() -> Bool {
        return (try? MACCursorActions.shared.resetAllCursors()) != nil
    }

    static func currentScale() -> Float {
        return MACCursorActions.shared.cursorScale()
    }

    static func defaultScale() -> Float {
        return MACCursorActions.shared.defaultCursorScale()
    }

    @discardableResult
    static func setScale(_ scale: Float) -> Bool {
        return MACCursorActions.shared.setCursorScale(scale)
    }

    @discardableResult
    static func assertPreferredScale() -> Bool {
        return MACCursorActions.shared.assertPreferredCursorScale()
    }
}
