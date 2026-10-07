import Foundation

enum CursorIdentifier {
    static func displayName(for identifier: String) -> String {
        return MACCursorDefinitions.nameForIdentifier(identifier)
    }

    static func identifier(for name: String) -> String? {
        return MACCursorDefinitions.identifierForName(name)
    }

    static var allIdentifiers: [(identifier: String, name: String)] {
        allIdentifiers(hideTahoeCursors: MACPreferences.hideTahoeCursors)
    }

    static func allIdentifiers(hideTahoeCursors: Bool) -> [(identifier: String, name: String)] {
        var result = MACCursorDefinitions.cursorMap
            .filter { !MACCursorDefinitions.redundantCursorAliases.contains($0.key) }
        if hideTahoeCursors {
            result = result.filter { !MACCursorDefinitions.hiddenCursorAliases.contains($0.key) }
        }
        return result
            .map { (identifier: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var allNames: [String] {
        return MACCursorDefinitions.cursorMap.values
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
