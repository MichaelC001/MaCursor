import Foundation

enum RightClickMenuContext: Equatable {
    case items
    case container
}

struct RightClickMenuRowOptions: Codable, Equatable {
    var addToMainMenu = false
    var enabled = true

    init(addToMainMenu: Bool = false, enabled: Bool = true) {
        self.addToMainMenu = addToMainMenu
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addToMainMenu = try container.decodeIfPresent(Bool.self, forKey: .addToMainMenu) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct RightClickMenuAppRow: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var addToMainMenu = false
    var enabled = true

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, addToMainMenu: Bool = false, enabled: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.addToMainMenu = addToMainMenu
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        addToMainMenu = try container.decodeIfPresent(Bool.self, forKey: .addToMainMenu) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

enum RightClickMenuAppList: CaseIterable {
    case openWith
    case commonApps

    var keyPath: WritableKeyPath<RightClickMenuSettings, [RightClickMenuAppRow]> {
        switch self {
        case .openWith: return \.openWithApps
        case .commonApps: return \.commonApps
        }
    }

    var group: RightClickMenuGroup {
        switch self {
        case .openWith: return .openWith
        case .commonApps: return .commonApps
        }
    }

    func itemTitle(_ applicationName: String) -> String {
        let format = self == .openWith ? String(localized: "Open With %@") : String(localized: "Open in %@")
        return String(format: format, applicationName)
    }
}

enum RightClickMenuFileType: String, CaseIterable, Identifiable {
    case text
    case markdown

    var id: Self { self }

    var keyPath: WritableKeyPath<RightClickMenuSettings, RightClickMenuRowOptions> {
        switch self {
        case .text: return \.textFile
        case .markdown: return \.markdownFile
        }
    }

    var name: String {
        switch self {
        case .text: return String(localized: "Text File")
        case .markdown: return String(localized: "Markdown File")
        }
    }

    var itemTitle: String {
        switch self {
        case .text: return String(localized: "New Text File")
        case .markdown: return String(localized: "New Markdown File")
        }
    }

    var fileExtension: String { self == .text ? "txt" : "md" }
}

enum RightClickMenuGroup: String, CaseIterable {
    case openWith
    case newFile
    case commonApps

    var title: String {
        switch self {
        case .openWith: return String(localized: "Open With")
        case .newFile: return String(localized: "New File")
        case .commonApps: return String(localized: "Common Apps")
        }
    }

    var symbolName: String {
        switch self {
        case .openWith: return "arrow.up.forward.app"
        case .newFile: return "doc.badge.plus"
        case .commonApps: return "square.stack.3d.up"
        }
    }

    var appList: RightClickMenuAppList? {
        switch self {
        case .openWith: return .openWith
        case .newFile: return nil
        case .commonApps: return .commonApps
        }
    }
}

enum RightClickMenuSwitch: String, CaseIterable {
    case copyPath
    case hideSelected
    case unhideSelected
    case hideAll
    case unhideAll

    var keyPath: WritableKeyPath<RightClickMenuSettings, Bool> {
        switch self {
        case .copyPath: return \.copyPathEnabled
        case .hideSelected: return \.hideSelectedFilesEnabled
        case .unhideSelected: return \.unhideSelectedFilesEnabled
        case .hideAll: return \.hideAllFilesInPathEnabled
        case .unhideAll: return \.unhideAllFilesInPathEnabled
        }
    }

    var title: String {
        switch self {
        case .copyPath: return String(localized: "Copy Path")
        case .hideSelected: return String(localized: "Hide Selected File(s)")
        case .unhideSelected: return String(localized: "Unhide Selected Files")
        case .hideAll: return String(localized: "Hide All Files in Path")
        case .unhideAll: return String(localized: "Unhide All Files in Path")
        }
    }

    var symbolName: String {
        switch self {
        case .copyPath: return "doc.on.doc"
        case .hideSelected, .hideAll: return "eye.slash"
        case .unhideSelected, .unhideAll: return "eye"
        }
    }
}

enum RightClickMenuItem: Hashable, Encodable {
    case group(RightClickMenuGroup)
    case action(RightClickMenuSwitch)
    case application(RightClickMenuAppList, String)
    case file(RightClickMenuFileType)

    static var defaultOrder: [RightClickMenuItem] {
        [.group(.openWith), .action(.copyPath), .group(.newFile), .group(.commonApps),
         .action(.hideSelected), .action(.unhideSelected), .action(.hideAll), .action(.unhideAll)]
    }

    init?(key: String) {
        if let group = RightClickMenuGroup(rawValue: key) {
            self = .group(group)
        } else if let action = RightClickMenuSwitch(rawValue: key) {
            self = .action(action)
        } else {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let group = RightClickMenuGroup(rawValue: parts[0]) else { return nil }
            if let list = group.appList {
                self = .application(list, parts[1])
            } else if let type = RightClickMenuFileType(rawValue: parts[1]) {
                self = .file(type)
            } else {
                return nil
            }
        }
    }

    var key: String {
        switch self {
        case .group(let group): return group.rawValue
        case .action(let action): return action.rawValue
        case .application(let list, let identifier): return "\(list.group.rawValue):\(identifier)"
        case .file(let type): return "\(RightClickMenuGroup.newFile.rawValue):\(type.rawValue)"
        }
    }

    func shows(in context: RightClickMenuContext) -> Bool {
        switch self {
        case .group(.openWith), .application(.openWith, _), .action(.hideSelected), .action(.unhideSelected):
            return context == .items
        case .action(.hideAll), .action(.unhideAll):
            return context == .container
        default:
            return true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

enum RightClickMenuSettingsError: LocalizedError {
    case duplicateApplication

    var errorDescription: String? {
        switch self {
        case .duplicateApplication: return String(localized: "That app is already in the list.")
        }
    }
}

struct RightClickMenuSettings: Codable, Equatable {
    static let appGroupIdentifier = "SP495GG2KZ.com.writronic.macursor"

    var isEnabled = false
    var hasFullDiskAccess = false
    var copyPathEnabled = true
    var hideSelectedFilesEnabled = true
    var unhideSelectedFilesEnabled = true
    var hideAllFilesInPathEnabled = true
    var unhideAllFilesInPathEnabled = true
    var textFile = RightClickMenuRowOptions()
    var markdownFile = RightClickMenuRowOptions()
    var openWithApps = [RightClickMenuAppRow(bundleIdentifier: "com.sublimetext.4")]
    var commonApps = [RightClickMenuAppRow(bundleIdentifier: "com.apple.Terminal")]
    var menuOrder = RightClickMenuItem.defaultOrder

    var isActive: Bool { isEnabled && hasFullDiskAccess }

    init(isEnabled: Bool = false, hasFullDiskAccess: Bool = false, copyPathEnabled: Bool = true,
         textFile: RightClickMenuRowOptions = RightClickMenuRowOptions(), markdownFile: RightClickMenuRowOptions = RightClickMenuRowOptions(),
         openWithApps: [RightClickMenuAppRow] = [RightClickMenuAppRow(bundleIdentifier: "com.sublimetext.4")],
         commonApps: [RightClickMenuAppRow] = [RightClickMenuAppRow(bundleIdentifier: "com.apple.Terminal")],
         hideSelectedFilesEnabled: Bool = true, unhideSelectedFilesEnabled: Bool = true,
         hideAllFilesInPathEnabled: Bool = true, unhideAllFilesInPathEnabled: Bool = true,
         menuOrder: [RightClickMenuItem] = RightClickMenuItem.defaultOrder) {
        self.isEnabled = isEnabled
        self.hasFullDiskAccess = hasFullDiskAccess
        self.copyPathEnabled = copyPathEnabled
        self.hideSelectedFilesEnabled = hideSelectedFilesEnabled
        self.unhideSelectedFilesEnabled = unhideSelectedFilesEnabled
        self.hideAllFilesInPathEnabled = hideAllFilesInPathEnabled
        self.unhideAllFilesInPathEnabled = unhideAllFilesInPathEnabled
        self.textFile = textFile
        self.markdownFile = markdownFile
        self.openWithApps = openWithApps
        self.commonApps = commonApps
        self.menuOrder = menuOrder
        normalizeMenuOrder()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        hasFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .hasFullDiskAccess) ?? false
        copyPathEnabled = try container.decodeIfPresent(Bool.self, forKey: .copyPathEnabled) ?? true
        hideSelectedFilesEnabled = try container.decodeIfPresent(Bool.self, forKey: .hideSelectedFilesEnabled) ?? true
        unhideSelectedFilesEnabled = try container.decodeIfPresent(Bool.self, forKey: .unhideSelectedFilesEnabled) ?? true
        hideAllFilesInPathEnabled = try container.decodeIfPresent(Bool.self, forKey: .hideAllFilesInPathEnabled) ?? true
        unhideAllFilesInPathEnabled = try container.decodeIfPresent(Bool.self, forKey: .unhideAllFilesInPathEnabled) ?? true
        textFile = try container.decodeIfPresent(RightClickMenuRowOptions.self, forKey: .textFile) ?? RightClickMenuRowOptions()
        markdownFile = try container.decodeIfPresent(RightClickMenuRowOptions.self, forKey: .markdownFile) ?? RightClickMenuRowOptions()
        openWithApps = try container.decodeIfPresent([RightClickMenuAppRow].self, forKey: .openWithApps) ?? [RightClickMenuAppRow(bundleIdentifier: "com.sublimetext.4")]
        commonApps = try container.decodeIfPresent([RightClickMenuAppRow].self, forKey: .commonApps) ?? [RightClickMenuAppRow(bundleIdentifier: "com.apple.Terminal")]
        let keys = try? container.decodeIfPresent([String].self, forKey: .menuOrder)
        menuOrder = keys?.compactMap(RightClickMenuItem.init(key:)) ?? RightClickMenuItem.defaultOrder
        try validate()
        normalizeMenuOrder()
    }

    mutating func addApplication(_ bundleIdentifier: String, to list: RightClickMenuAppList) throws {
        guard !self[keyPath: list.keyPath].contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw RightClickMenuSettingsError.duplicateApplication
        }
        guard !bundleIdentifier.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        self[keyPath: list.keyPath].append(RightClickMenuAppRow(bundleIdentifier: bundleIdentifier))
    }

    func menuItems(isAvailable: (String) -> Bool) -> [RightClickMenuItem] {
        let arrangement = menuArrangement(isAvailable: isAvailable)
        return arrangement.order.filter(arrangement.shown.contains)
    }

    func submenuItems(of group: RightClickMenuGroup, isAvailable: (String) -> Bool) -> [RightClickMenuItem] {
        rows(of: group, isAvailable: isAvailable).filter { !$0.promoted }.map(\.item)
    }

    mutating func setMenuOrder(_ items: [RightClickMenuItem], isAvailable: (String) -> Bool) {
        let arrangement = menuArrangement(isAvailable: isAvailable)
        var seen = Set<RightClickMenuItem>()
        let moved = items.filter { arrangement.shown.contains($0) && seen.insert($0).inserted }
        var queue = moved + arrangement.order.filter { arrangement.shown.contains($0) && !seen.contains($0) }
        menuOrder = arrangement.order.map { arrangement.shown.contains($0) ? queue.removeFirst() : $0 }
    }

    private func rows(of group: RightClickMenuGroup, isAvailable: (String) -> Bool) -> [(item: RightClickMenuItem, promoted: Bool)] {
        if let list = group.appList {
            return self[keyPath: list.keyPath].filter { $0.enabled && isAvailable($0.bundleIdentifier) }
                .map { (.application(list, $0.bundleIdentifier), $0.addToMainMenu) }
        }
        return RightClickMenuFileType.allCases.filter { self[keyPath: $0.keyPath].enabled }
            .map { (.file($0), self[keyPath: $0.keyPath].addToMainMenu) }
    }

    private func menuArrangement(isAvailable: (String) -> Bool) -> (order: [RightClickMenuItem], shown: Set<RightClickMenuItem>) {
        var order: [RightClickMenuItem] = []
        var shown = Set<RightClickMenuItem>()
        for item in menuOrder {
            switch item {
            case .group(let group):
                let rows = rows(of: group, isAvailable: isAvailable)
                let submenu = rows.firstIndex { !$0.promoted } ?? rows.endIndex
                let unplaced = rows.indices.filter { rows[$0].promoted && !menuOrder.contains(rows[$0].item) }
                order += unplaced.filter { $0 < submenu }.map { rows[$0].item }
                order.append(item)
                order += unplaced.filter { $0 > submenu }.map { rows[$0].item }
                if submenu < rows.endIndex { shown.insert(item) }
                for row in rows where row.promoted { shown.insert(row.item) }
            case .action(let action):
                order.append(item)
                if self[keyPath: action.keyPath] { shown.insert(item) }
            case .application, .file:
                order.append(item)
            }
        }
        return (order, shown)
    }

    private mutating func normalizeMenuOrder() {
        var seen = Set<RightClickMenuItem>()
        var order = menuOrder.filter { canStore($0) && seen.insert($0).inserted }
        let defaults = RightClickMenuItem.defaultOrder
        for (index, item) in defaults.enumerated() where !seen.contains(item) {
            let previous = index == 0 ? nil : order.firstIndex(of: defaults[index - 1])
            order.insert(item, at: previous.map { $0 + 1 } ?? 0)
        }
        menuOrder = order
    }

    private func canStore(_ item: RightClickMenuItem) -> Bool {
        switch item {
        case .group, .action:
            return true
        case .application(let list, let identifier):
            return self[keyPath: list.keyPath].contains { $0.bundleIdentifier == identifier && $0.addToMainMenu }
        case .file(let type):
            return self[keyPath: type.keyPath].addToMainMenu
        }
    }

    private func validate() throws {
        for list in RightClickMenuAppList.allCases {
            let identifiers = self[keyPath: list.keyPath].map(\.bundleIdentifier)
            guard Set(identifiers).count == identifiers.count else { throw RightClickMenuSettingsError.duplicateApplication }
            guard identifiers.allSatisfy({ !$0.isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("RightClickMenuSettings.json")
    }

    static func load(from url: URL? = fileURL) -> Self {
        guard let url,
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return settings
    }

    func save(to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileWriteNoPermission) }
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func update(shown: Self, load: () -> Self = { Self.load() },
                       save: (Self) throws -> Void = { try $0.save() },
                       change: (inout Self) throws -> Void) -> (settings: Self, error: Error?) {
        var updated = load()
        do {
            try change(&updated)
            updated.normalizeMenuOrder()
            try updated.validate()
            try save(updated)
            return (updated, nil)
        } catch {
            return (shown, error)
        }
    }

    static func reset(to url: URL? = fileURL) throws -> Self {
        let defaults = Self(hasFullDiskAccess: load(from: url).hasFullDiskAccess)
        try defaults.save(to: url)
        return defaults
    }
}
