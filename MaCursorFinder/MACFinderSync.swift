import FinderSync

final class MACFinderSync: FIFinderSync, RightClickMenuActionTarget {
    private var menuSettings = RightClickMenuSettings()
    private var menuContext = RightClickMenuContext.items

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = Set(RightClickMenuScope.roots)
    }

    override var toolbarItemName: String { "MaCursor" }

    override var toolbarItemToolTip: String { "MaCursor" }

    override var toolbarItemImage: NSImage { RightClickMenuActions.symbolIcon("contextualmenu.and.cursorarrow") ?? NSImage() }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let context: RightClickMenuContext
        switch menuKind {
        case .contextualMenuForItems: context = .items
        case .contextualMenuForContainer: context = .container
        case .toolbarItemMenu: context = .container
        default: return nil
        }
        let settings = RightClickMenuSettings.load()
        let applications = RightClickMenuActions.resolvedApplications(settings: settings)
        menuSettings = settings
        menuContext = context
        if menuKind == .toolbarItemMenu {
            let folder = FIFinderSyncController.default().targetedURL()
            return RightClickMenuActions.toolbarMenu(settings: settings, targetedURL: folder, target: self, applications: applications)
        }
        return RightClickMenuActions.menu(settings: settings, context: context, target: self, applications: applications)
    }

    @objc func openApplication(_ sender: NSMenuItem) {
        RightClickMenuActions.openApplication(
            tag: sender.tag, context: menuContext, shown: menuSettings, latest: RightClickMenuSettings.load(),
            target: FIFinderSyncController.default().targetedURL(),
            selectedItems: menuContext == .items ? FIFinderSyncController.default().selectedItemURLs() ?? [] : []
        )
    }

    @objc func copySelectedPaths() {
        RightClickMenuActions.copyPaths(FIFinderSyncController.default().selectedItemURLs() ?? [])
    }

    @objc func copyFolderPath() {
        guard let url = FIFinderSyncController.default().targetedURL() else { return }
        RightClickMenuActions.copyPaths([url])
    }

    @objc func newTextFile() {
        createFile(context: .items, baseName: RightClickMenuAction.newTextFile.title, ext: "txt")
    }

    @objc func newMarkdownFile() {
        createFile(context: .items, baseName: RightClickMenuAction.newMarkdownFile.title, ext: "md")
    }

    @objc func newTextFileInFolder() {
        createFile(context: .container, baseName: RightClickMenuAction.newTextFileInFolder.title, ext: "txt")
    }

    @objc func newMarkdownFileInFolder() {
        createFile(context: .container, baseName: RightClickMenuAction.newMarkdownFileInFolder.title, ext: "md")
    }

    @objc func hideSelectedFiles() {
        changeVisibility(hidden: true, context: .items)
    }

    @objc func unhideSelectedFiles() {
        changeVisibility(hidden: false, context: .items)
    }

    @objc func hideAllFilesInPath() {
        changeVisibility(hidden: true, context: .container)
    }

    @objc func unhideAllFilesInPath() {
        changeVisibility(hidden: false, context: .container)
    }

    private func changeVisibility(hidden: Bool, context: RightClickMenuContext) {
        let result = RightClickMenuActions.changeVisibility(
            hidden: hidden, context: context, target: FIFinderSyncController.default().targetedURL(),
            selectedItems: context == .items ? FIFinderSyncController.default().selectedItemURLs() ?? [] : []
        )
        RightClickMenuActions.reportVisibilityFailures(result)
    }

    private func createFile(context: RightClickMenuContext, baseName: String, ext: String) {
        do {
            guard let directory = RightClickMenuActions.creationDirectory(
                context: context, target: FIFinderSyncController.default().targetedURL(),
                selectedItems: context == .items ? FIFinderSyncController.default().selectedItemURLs() ?? [] : []
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = try RightClickMenuActions.createFile(in: directory, baseName: baseName, ext: ext) {
                try Data().write(to: $0, options: .withoutOverwriting)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
            NSLog("MaCursor: New File failed (%ld)", (error as NSError).code)
        }
    }
}
