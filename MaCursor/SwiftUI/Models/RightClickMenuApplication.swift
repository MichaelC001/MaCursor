import AppKit

struct RightClickMenuApplication: Equatable {
    let url: URL
    let bundleIdentifier: String
    let displayName: String

    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        self.url = url
        bundleIdentifier = identifier
        displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func resolve(_ bundleIdentifier: String) -> Self? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return Self(url: url)
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}
