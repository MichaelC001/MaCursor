import AppKit
import UniformTypeIdentifiers

@objc protocol RightClickMenuActionTarget {
    func openApplication(_ sender: NSMenuItem)
    func copySelectedPaths()
    func copyFolderPath()
    func newTextFile()
    func newMarkdownFile()
    func newTextFileInFolder()
    func newMarkdownFileInFolder()
    func hideSelectedFiles()
    func unhideSelectedFiles()
    func hideAllFilesInPath()
    func unhideAllFilesInPath()
}

enum RightClickMenuAction: Equatable {
    case application(RightClickMenuAppList, Int, RightClickMenuApplication)
    case copySelectedPaths
    case copyFolderPath
    case newTextFile
    case newMarkdownFile
    case newTextFileInFolder
    case newMarkdownFileInFolder
    case hideSelectedFiles
    case unhideSelectedFiles
    case hideAllFilesInPath
    case unhideAllFilesInPath

    var title: String {
        switch self {
        case .application(let list, _, let application): return list.itemTitle(application.displayName)
        case .copySelectedPaths, .copyFolderPath: return RightClickMenuSwitch.copyPath.title
        case .newTextFile, .newTextFileInFolder: return RightClickMenuFileType.text.itemTitle
        case .newMarkdownFile, .newMarkdownFileInFolder: return RightClickMenuFileType.markdown.itemTitle
        case .hideSelectedFiles: return RightClickMenuSwitch.hideSelected.title
        case .unhideSelectedFiles: return RightClickMenuSwitch.unhideSelected.title
        case .hideAllFilesInPath: return RightClickMenuSwitch.hideAll.title
        case .unhideAllFilesInPath: return RightClickMenuSwitch.unhideAll.title
        }
    }

    var submenuTitle: String {
        switch self {
        case .application(_, _, let application): return application.displayName
        case .newTextFile, .newTextFileInFolder: return RightClickMenuFileType.text.name
        case .newMarkdownFile, .newMarkdownFileInFolder: return RightClickMenuFileType.markdown.name
        default: return title
        }
    }

    var tag: Int {
        if case .application(_, let tag, _) = self { return tag }
        return -1
    }

    var icon: NSImage? {
        switch self {
        case .application(_, _, let application): return RightClickMenuActions.applicationIcon(application)
        case .copySelectedPaths, .copyFolderPath: return RightClickMenuActions.copyPathIcon()
        case .newTextFile, .newTextFileInFolder: return RightClickMenuActions.fileIcon(for: .plainText)
        case .newMarkdownFile, .newMarkdownFileInFolder: return RightClickMenuActions.fileIcon(for: RightClickMenuActions.markdownContentType())
        case .hideSelectedFiles, .hideAllFilesInPath: return RightClickMenuActions.symbolIcon(RightClickMenuSwitch.hideSelected.symbolName)
        case .unhideSelectedFiles, .unhideAllFilesInPath: return RightClickMenuActions.symbolIcon(RightClickMenuSwitch.unhideSelected.symbolName)
        }
    }

    var selector: Selector {
        switch self {
        case .application: return #selector(RightClickMenuActionTarget.openApplication(_:))
        case .copySelectedPaths: return #selector(RightClickMenuActionTarget.copySelectedPaths)
        case .copyFolderPath: return #selector(RightClickMenuActionTarget.copyFolderPath)
        case .newTextFile: return #selector(RightClickMenuActionTarget.newTextFile)
        case .newMarkdownFile: return #selector(RightClickMenuActionTarget.newMarkdownFile)
        case .newTextFileInFolder: return #selector(RightClickMenuActionTarget.newTextFileInFolder)
        case .newMarkdownFileInFolder: return #selector(RightClickMenuActionTarget.newMarkdownFileInFolder)
        case .hideSelectedFiles: return #selector(RightClickMenuActionTarget.hideSelectedFiles)
        case .unhideSelectedFiles: return #selector(RightClickMenuActionTarget.unhideSelectedFiles)
        case .hideAllFilesInPath: return #selector(RightClickMenuActionTarget.hideAllFilesInPath)
        case .unhideAllFilesInPath: return #selector(RightClickMenuActionTarget.unhideAllFilesInPath)
        }
    }
}

enum RightClickMenuEntry: Equatable {
    case action(RightClickMenuAction)
    case submenu(RightClickMenuGroup, [RightClickMenuAction])
}

typealias RightClickMenuApplicationOpener = ([URL], URL, @escaping @Sendable (Error?) -> Void) -> Void

enum RightClickMenuActions {
    static func actions(settings: RightClickMenuSettings, context: RightClickMenuContext,
                        applications: [String: RightClickMenuApplication] = [:]) -> [RightClickMenuEntry] {
        guard settings.isEnabled else { return [] }
        let isAvailable: (String) -> Bool = { applications[$0] != nil }
        return settings.menuItems(isAvailable: isAvailable).filter { $0.shows(in: context) }.compactMap { item in
            if case .group(let group) = item {
                return .submenu(group, settings.submenuItems(of: group, isAvailable: isAvailable).compactMap {
                    action(for: $0, settings: settings, context: context, applications: applications)
                })
            }
            return action(for: item, settings: settings, context: context, applications: applications).map(RightClickMenuEntry.action)
        }
    }

    private static func action(for item: RightClickMenuItem, settings: RightClickMenuSettings, context: RightClickMenuContext,
                               applications: [String: RightClickMenuApplication]) -> RightClickMenuAction? {
        switch item {
        case .group: return nil
        case .action(.copyPath): return context == .items ? .copySelectedPaths : .copyFolderPath
        case .action(.hideSelected): return .hideSelectedFiles
        case .action(.unhideSelected): return .unhideSelectedFiles
        case .action(.hideAll): return .hideAllFilesInPath
        case .action(.unhideAll): return .unhideAllFilesInPath
        case .file(.text): return context == .items ? .newTextFile : .newTextFileInFolder
        case .file(.markdown): return context == .items ? .newMarkdownFile : .newMarkdownFileInFolder
        case .application(let list, let identifier):
            guard let application = applications[identifier],
                  let index = settings[keyPath: list.keyPath].firstIndex(where: { $0.bundleIdentifier == identifier }) else { return nil }
            return .application(list, (list == .openWith ? 0 : settings.openWithApps.count) + index, application)
        }
    }

    static func menu(settings: RightClickMenuSettings, context: RightClickMenuContext, target: RightClickMenuActionTarget,
                     applications: [String: RightClickMenuApplication] = [:]) -> NSMenu? {
        let actions = actions(settings: settings, context: context, applications: applications)
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in actions {
            switch entry {
            case .action(let action):
                menu.addItem(menuItem(action, target: target, inSubmenu: false))
            case .submenu(let group, let children):
                let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                parent.image = symbolIcon(group.symbolName)
                let submenu = NSMenu(title: group.title)
                for child in children { submenu.addItem(menuItem(child, target: target, inSubmenu: true)) }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        return menu
    }

    static func toolbarMenu(settings: RightClickMenuSettings, targetedURL: URL?, target: RightClickMenuActionTarget,
                            applications: [String: RightClickMenuApplication] = [:]) -> NSMenu {
        let folderMenu = menu(settings: settings, context: .container, target: target, applications: applications)
        if let folderMenu, targetedURL != nil { return folderMenu }
        let reason: String
        if folderMenu != nil {
            reason = String(localized: "Not available in this location.")
        } else if actions(settings: settings, context: .items, applications: applications).isEmpty {
            reason = String(localized: "Nothing is turned on.")
        } else {
            reason = String(localized: "Items that are on show only on files.")
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return menu
    }

    private static func menuItem(_ action: RightClickMenuAction, target: RightClickMenuActionTarget, inSubmenu: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: inSubmenu ? action.submenuTitle : action.title, action: action.selector, keyEquivalent: "")
        item.target = target
        item.tag = action.tag
        item.image = action.icon
        return item
    }

    static func resolvedApplications(settings: RightClickMenuSettings,
                                     resolve: (String) -> RightClickMenuApplication? = RightClickMenuApplication.resolve) -> [String: RightClickMenuApplication] {
        guard settings.isEnabled else { return [:] }
        var applications: [String: RightClickMenuApplication] = [:]
        for row in settings.openWithApps + settings.commonApps where row.enabled {
            if applications[row.bundleIdentifier] == nil {
                applications[row.bundleIdentifier] = resolve(row.bundleIdentifier)
            }
        }
        return applications
    }

    static func pasteboardText(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pasteboardText(for: urls), forType: .string)
    }

    static func applicationRow(tag: Int, shown: RightClickMenuSettings, latest: RightClickMenuSettings) -> (RightClickMenuAppList, RightClickMenuAppRow)? {
        guard shown.isEnabled, latest.isEnabled, tag >= 0 else { return nil }
        let list: RightClickMenuAppList = tag < shown.openWithApps.count ? .openWith : .commonApps
        let index = list == .openWith ? tag : tag - shown.openWithApps.count
        let oldRows = shown[keyPath: list.keyPath]
        let newRows = latest[keyPath: list.keyPath]
        guard oldRows.indices.contains(index), newRows.indices.contains(index),
              oldRows[index].enabled, newRows[index].enabled,
              oldRows[index].bundleIdentifier == newRows[index].bundleIdentifier else { return nil }
        return (list, newRows[index])
    }

    static func openApplication(tag: Int, context: RightClickMenuContext, shown: RightClickMenuSettings, latest: RightClickMenuSettings,
                                target: URL?, selectedItems: [URL],
                                resolve: (String) -> RightClickMenuApplication? = RightClickMenuApplication.resolve,
                                isDirectory: (URL) throws -> Bool = { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true },
                                opener: RightClickMenuApplicationOpener = openInWorkspace,
                                reportFailure: @escaping @MainActor (Int?) -> Void = reportApplicationFailure) {
        guard let (list, row) = applicationRow(tag: tag, shown: shown, latest: latest),
              list != .openWith || context == .items else {
            DispatchQueue.main.async { reportFailure(nil) }
            return
        }
        do {
            let urls: [URL]
            if list == .openWith {
                urls = selectedItems
            } else {
                guard let directory = try commonAppsDirectory(context: context, target: target, selectedItems: selectedItems, isDirectory: isDirectory) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                urls = [directory]
            }
            openSelection(urls, application: resolve(row.bundleIdentifier), opener: opener, reportFailure: reportFailure)
        } catch {
            let code = (error as NSError).code
            DispatchQueue.main.async { reportFailure(code) }
        }
    }

    static func openSelection(_ urls: [URL], application: RightClickMenuApplication?,
                              opener: RightClickMenuApplicationOpener = openInWorkspace,
                              reportFailure: @escaping @MainActor (Int?) -> Void = reportApplicationFailure) {
        guard !urls.isEmpty else { return }
        guard let application else {
            DispatchQueue.main.async { reportFailure(nil) }
            return
        }
        opener(urls, application.url) { error in
            guard let error else { return }
            let code = (error as NSError).code
            DispatchQueue.main.async { reportFailure(code) }
        }
    }

    private static func openInWorkspace(_ urls: [URL], applicationURL: URL, completion: @escaping @Sendable (Error?) -> Void) {
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            completion(error)
        }
    }

    @MainActor private static func reportApplicationFailure(_ code: Int?) {
        NSSound.beep()
        if let code { NSLog("MaCursor: Open Application failed (%ld)", code) }
    }

    static func changeVisibility(hidden: Bool, context: RightClickMenuContext, target: URL?, selectedItems: [URL],
                                 contentsOfDirectory: (URL) throws -> [URL] = {
                                     try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [])
                                 },
                                 setter: (URL, Bool) throws -> Void = setHiddenFlag) -> (failureCount: Int, firstErrorCode: Int?) {
        var failureCount = 0
        var firstErrorCode: Int?
        do {
            let urls: [URL]
            if context == .items {
                urls = selectedItems
            } else {
                guard let target else { throw CocoaError(.fileNoSuchFile) }
                urls = try contentsOfDirectory(target).filter { !hidden || !$0.lastPathComponent.hasPrefix(".") }
            }
            for url in urls {
                do {
                    try setter(url, hidden)
                } catch {
                    failureCount += 1
                    if firstErrorCode == nil { firstErrorCode = (error as NSError).code }
                }
            }
        } catch {
            failureCount = 1
            firstErrorCode = (error as NSError).code
        }
        return (failureCount, firstErrorCode)
    }

    static func setHiddenFlag(_ original: URL, hidden: Bool) throws {
        var url = original
        var values = URLResourceValues()
        values.isHidden = hidden
        try url.setResourceValues(values)
    }

    static func reportVisibilityFailures(_ result: (failureCount: Int, firstErrorCode: Int?),
                                         reportFailure: @escaping @MainActor (Int, Int) -> Void = { count, code in
                                             NSSound.beep()
                                             NSLog("MaCursor: Visibility change failed (%ld, %ld)", count, code)
                                         }) {
        guard let code = result.firstErrorCode else { return }
        DispatchQueue.main.async { reportFailure(result.failureCount, code) }
    }

    static func copyPathIcon() -> NSImage? {
        symbolIcon(RightClickMenuSwitch.copyPath.symbolName)
    }

    static func symbolIcon(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return bitmapIcon(from: symbol, isTemplate: true)
    }

    static func markdownContentType(_ resolved: UTType? = UTType(filenameExtension: "md")) -> UTType {
        guard let resolved, !resolved.isDynamic else { return .plainText }
        return resolved
    }

    static func fileIcon(for type: UTType) -> NSImage? {
        bitmapIcon(from: NSWorkspace.shared.icon(for: type), isTemplate: false)
    }

    static func applicationIcon(_ application: RightClickMenuApplication) -> NSImage? {
        bitmapIcon(from: application.icon, isTemplate: false)
    }

    private static func bitmapIcon(from source: NSImage, isTemplate: Bool) -> NSImage? {
        let drawing = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let scale = min(rect.width / source.size.width, rect.height / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            return true
        }
        guard let bitmap = drawing.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let representation = NSBitmapImageRep(cgImage: bitmap)
        representation.size = image.size
        image.addRepresentation(representation)
        image.isTemplate = isTemplate
        return image
    }

    static let maximumNameAttempts = 100

    static func commonAppsDirectory(context: RightClickMenuContext, target: URL?, selectedItems: [URL],
                                    isDirectory: (URL) throws -> Bool = { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }) throws -> URL? {
        guard context == .items else { return target }
        if selectedItems.count == 1, let url = selectedItems.first, try isDirectory(url) { return url }
        return creationDirectory(context: .items, target: target, selectedItems: selectedItems)
    }

    static func creationDirectory(context: RightClickMenuContext, target: URL?, selectedItems: [URL]) -> URL? {
        guard context == .items else { return target }
        guard let directory = selectedItems.first?.deletingLastPathComponent(),
              selectedItems.allSatisfy({ $0.deletingLastPathComponent() == directory }) else { return nil }
        return directory
    }

    static func createFile(in directory: URL, baseName: String, ext: String,
                           write: (URL) throws -> Void) throws -> URL {
        for attempt in 1...maximumNameAttempts {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
            do {
                try write(url)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
