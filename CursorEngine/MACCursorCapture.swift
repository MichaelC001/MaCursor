import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
struct MACCursorCapture {
    struct Operations {
        var connection: () -> CGSConnectionID = { CGSMainConnectionID() }
        var unregister: (CGSConnectionID) -> CGError = CoreCursorUnregisterAll
        var select: (CGSConnectionID, CGSCursorID) -> CGError = CoreCursorSet
        var getScale: (CGSConnectionID, UnsafeMutablePointer<Float>?) -> CGError = CGSGetCursorScale
        var setScale: (CGSConnectionID, Float) -> CGError = CGSSetCursorScale
        var hide: (CGSConnectionID) -> CGError = CGSHideCursor
        var show: (CGSConnectionID) -> CGError = CGSShowCursor
        var registeredSize: (CGSConnectionID, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?) -> CGError = CGSGetRegisteredCursorDataSize
        var copyNamed: (CGSConnectionID, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CGSize>?, UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<CGFloat>?, UnsafeMutablePointer<Unmanaged<CFArray>?>?) -> CGError = CGSCopyRegisteredCursorImages
        var copyCore: (CGSConnectionID, CGSCursorID, UnsafeMutablePointer<Unmanaged<CFArray>?>?, UnsafeMutablePointer<CGSize>?, UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<CGFloat>?) -> CGError = CoreCursorCopyImages
        var preferredScale: () -> NSNumber? = { MACPreferences.value(forKey: MACPreferences.cursorScaleKey) as? NSNumber }
        var read: (URL) -> Data? = { try? Data(contentsOf: $0) }
        var write: (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        var exclusively: (URL, () -> Bool) -> Bool = { url, body in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var descriptor: Int32
            repeat {
                descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC, 0o644)
            } while descriptor == -1 && errno == EINTR
            guard descriptor != -1 else { return false }
            defer { close(descriptor) }
            return FileManager.default.fileExists(atPath: url.path) || body()
        }
    }

    struct Images {
        let images: [CGImage]
        let size: CGSize
        let hotSpot: CGPoint
        let frameCount: UInt
        let frameDuration: CGFloat

        var isBad: Bool {
            let first = images[0]
            return MACCursorCapture.isRedPlaceholder(first) || first.width < Int(size.width) || first.height < Int(size.height)
        }

        var theme: [String: Any]? {
            let pngs = images.compactMap {
                NSBitmapImageRep(cgImage: $0).ensuredSRGBSpace.cgImage.flatMap { MACCursorCapture.pngData(for: $0) }
            }
            guard !pngs.isEmpty else { return nil }
            return MACCursorCapture.theme(size: size, hotSpot: hotSpot, frames: frameCount, duration: frameDuration, pngs: pngs)
        }
    }

    static let shared = MACCursorCapture()
    var operations = Operations()

    nonisolated static var systemDefaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaCursor/SystemDefault.cursor").path
    }

    func query(_ identifier: String, connection: CGSConnectionID) -> Images? {
        var frameCount: UInt = 0
        var duration: CGFloat = 0
        var size = CGSize.zero
        var hotSpot = CGPoint.zero
        var output: Unmanaged<CFArray>?
        let error: CGError
        if identifier.hasPrefix("com.apple.cursor.") {
            let cursorID = (identifier as NSString).pathExtension
            error = operations.copyCore(connection, (cursorID as NSString).intValue, &output, &size, &hotSpot, &frameCount, &duration)
        } else {
            var name = Array(identifier.utf8CString)
            var byteCount = 0
            guard name.withUnsafeMutableBufferPointer({
                operations.registeredSize(connection, $0.baseAddress, &byteCount)
            }) == .success, byteCount > 0 else { return nil }
            error = name.withUnsafeMutableBufferPointer {
                operations.copyNamed(connection, $0.baseAddress, &size, &hotSpot, &frameCount, &duration, &output)
            }
        }
        let owned = output?.takeRetainedValue()
        guard error == .success, let array = owned as? [Any], !array.isEmpty,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width < CGFloat(Int.max), size.height < CGFloat(Int.max),
              hotSpot.x.isFinite, hotSpot.y.isFinite, frameCount > 0,
              duration.isFinite, duration >= 0 else { return nil }
        var images: [CGImage] = []
        for object in array {
            guard CFGetTypeID(object as CFTypeRef) == CGImage.typeID else { return nil }
            images.append(object as! CGImage)
        }
        return Images(images: images, size: size, hotSpot: hotSpot, frameCount: frameCount, frameDuration: duration)
    }

    func cursorTheme(_ identifier: String, connection: CGSConnectionID) -> [String: Any]? {
        guard let original = query(identifier, connection: connection) else { return nil }
        let isCore = identifier.hasPrefix("com.apple.cursor.")
        if original.isBad || (!isCore && Self.namedPDFMap[identifier] != nil) {
            if isCore {
                var scale = MACCursorDefinitions.dumpScale
                _ = operations.getScale(connection, &scale)
                if scale > 1 {
                    let retry: Images? = {
                        _ = operations.setScale(connection, 1)
                        defer { _ = operations.setScale(connection, scale) }
                        return query(identifier, connection: connection)
                    }()
                    if let retry, !retry.isBad, let theme = retry.theme { return theme }
                }
            }
            if let folder = (isCore ? Self.corePDFMap : Self.namedPDFMap)[identifier],
               let theme = pdfTheme(folder) { return theme }
        }
        return original.theme
    }

    @discardableResult
    func capture(to path: String) -> Bool {
        autoreleasepool {
            operations.exclusively(URL(fileURLWithPath: path)) { captureLocked(to: path) }
        }
    }

    private func captureLocked(to path: String) -> Bool {
        let connection = operations.connection()
        guard connection != 0 else { return false }
        _ = operations.unregister(connection)
        for cursor in 0...MACCursorDefinitions.maxCoreCursorID { _ = operations.select(connection, cursor) }
        var originalScale: Float = 1
        if operations.getScale(connection, &originalScale) != .success || originalScale == MACCursorDefinitions.dumpScale {
            originalScale = 1
            MACCursorDefinitions.resolvePreferredScale(operations.preferredScale(), &originalScale)
        }
        let cursors: [String: Any] = {
            _ = operations.setScale(connection, MACCursorDefinitions.dumpScale)
            _ = operations.hide(connection)
            defer {
                _ = operations.show(connection)
                _ = operations.setScale(connection, originalScale)
            }
            var cursors: [String: Any] = [:]
            for identifier in MACCursorDefinitions.defaultCursors
                where identifier != "com.apple.coregraphics.IBeamXOR" && identifier != "com.apple.coregraphics.Empty" {
                cursors[identifier] = cursorTheme(identifier, connection: connection)
            }
            for cursor in 0...MACCursorDefinitions.maxCoreCursorID where cursor != 0 && cursor != 1 && cursor != 8 {
                _ = operations.select(connection, cursor)
                let identifier = "com.apple.cursor.\(cursor)"
                cursors[identifier] = cursorTheme(identifier, connection: connection)
            }
            return cursors
        }()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let theme: [String: Any] = [
            MACCursorDefinitions.creatorKey: "Apple, Inc.",
            MACCursorDefinitions.themeNameKey: "System Default (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))",
            MACCursorDefinitions.themeVersionKey: 1.0,
            MACCursorDefinitions.cursorsKey: cursors,
            MACCursorDefinitions.hiDPIKey: true,
            MACCursorDefinitions.identifierKey: "com.writronic.macursor.systemdefault",
            MACCursorDefinitions.uuidKey: UUID().uuidString
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: theme, format: .binary, options: 0)
            try operations.write(data, URL(fileURLWithPath: path))
            print("Captured \(cursors.count) cursors to \(path)")
            return true
        } catch {
            print("System default capture failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func pngData(for object: Any) -> Data? {
        if let bitmap = object as? NSBitmapImageRep { return bitmap.representation(using: .png, properties: [:]) }
        guard CFGetTypeID(object as CFTypeRef) == CGImage.typeID else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, object as! CGImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private nonisolated static func isRedPlaceholder(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width <= 32, height <= 32 else { return false }
        guard let context = makeContext(width: width, height: height), let data = context.data else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(width * height)).allSatisfy {
            bytes[$0 * 4] == 255 && bytes[$0 * 4 + 1] == 0 && bytes[$0 * 4 + 2] == 0 && bytes[$0 * 4 + 3] == 255
        }
    }

    private nonisolated static func theme(size: CGSize, hotSpot: CGPoint, frames: UInt, duration: CGFloat, pngs: [Data]) -> [String: Any] {
        [MACCursorDefinitions.frameCountKey: frames, MACCursorDefinitions.frameDurationKey: duration,
         MACCursorDefinitions.hotSpotXKey: hotSpot.x, MACCursorDefinitions.hotSpotYKey: hotSpot.y,
         MACCursorDefinitions.pointsWideKey: size.width, MACCursorDefinitions.pointsHighKey: size.height,
         MACCursorDefinitions.representationsKey: pngs]
    }

    private nonisolated static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= Int.max / 4, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func pdfTheme(_ folder: String) -> [String: Any]? {
        let directory = URL(fileURLWithPath: Self.pdfPath).appendingPathComponent(folder)
        guard let pdfData = operations.read(directory.appendingPathComponent("cursor.pdf")),
              let infoData = operations.read(directory.appendingPathComponent("info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)) as? NSDictionary,
              let provider = CGDataProvider(data: pdfData as CFData), let pdf = CGPDFDocument(provider),
              let first = pdf.page(at: 1) else { return nil }
        func number(_ key: String) -> Double {
            (info[key] as? NSNumber)?.doubleValue ?? (info[key] as? NSString)?.doubleValue ?? 0
        }
        let frameValue = number("frames")
        guard frameValue.isFinite, frameValue < Double(Int.max) else { return nil }
        let frames = max(1, Int(max(1, frameValue)))
        let box = first.getBoxRect(.mediaBox)
        let size = CGSize(width: box.width, height: frames > 1 && pdf.numberOfPages == 1 ? box.height / CGFloat(frames) : box.height)
        var pngs: [Data] = []
        for scale in Self.pdfScales {
            let width = size.width * CGFloat(scale)
            let height = frames > 1 && pdf.numberOfPages >= frames ? size.height * CGFloat(scale) * CGFloat(frames) : box.height * CGFloat(scale)
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  width < CGFloat(Int.max), height < CGFloat(Int.max),
                  let context = Self.makeContext(width: Int(width), height: Int(height)) else { continue }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            if frames > 1 && pdf.numberOfPages >= frames {
                for frame in 0..<frames {
                    guard let page = pdf.page(at: frame + 1) else { continue }
                    context.saveGState()
                    context.translateBy(x: 0, y: CGFloat(frames - 1 - frame) * size.height * CGFloat(scale))
                    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                    context.drawPDFPage(page)
                    context.restoreGState()
                }
            } else {
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                context.drawPDFPage(first)
            }
            if let image = context.makeImage(), let png = Self.pngData(for: image) { pngs.append(png) }
        }
        guard !pngs.isEmpty else { return nil }
        return Self.theme(size: size, hotSpot: CGPoint(x: number("hotx"), y: number("hoty")), frames: UInt(frames), duration: number("delay"), pngs: pngs)
    }

    private static let pdfPath = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"
    static let pdfScales = [1, 2, 5, 10]
    static let corePDFMap: [String: String] = [
        "com.apple.cursor.2":  "makealias",
        "com.apple.cursor.3":  "notallowed",
        "com.apple.cursor.4":  "busybutclickable",
        "com.apple.cursor.5":  "copy",
        "com.apple.cursor.7":  "cross",
        "com.apple.cursor.8":  "cross",
        "com.apple.cursor.9":  "screenshotwindow",
        "com.apple.cursor.10": "screenshotselection",
        "com.apple.cursor.11": "closedhand",
        "com.apple.cursor.12": "openhand",
        "com.apple.cursor.13": "pointinghand",
        "com.apple.cursor.14": "countinguphand",
        "com.apple.cursor.15": "countingdownhand",
        "com.apple.cursor.16": "countingupandownhand",
        "com.apple.cursor.17": "resizeleft",
        "com.apple.cursor.18": "resizeright",
        "com.apple.cursor.19": "resizeleftright",
        "com.apple.cursor.20": "cross",
        "com.apple.cursor.21": "resizeup",
        "com.apple.cursor.22": "resizedown",
        "com.apple.cursor.23": "resizeupdown",
        "com.apple.cursor.24": "contextualmenu",
        "com.apple.cursor.25": "poof",
        "com.apple.cursor.26": "ibeamhorizontal",
        "com.apple.cursor.27": "resizeeast",
        "com.apple.cursor.28": "resizeeastwest",
        "com.apple.cursor.29": "resizenortheast",
        "com.apple.cursor.30": "resizenortheastsouthwest",
        "com.apple.cursor.31": "resizenorth",
        "com.apple.cursor.32": "resizenorthsouth",
        "com.apple.cursor.33": "resizenorthwest",
        "com.apple.cursor.34": "resizenorthwestsoutheast",
        "com.apple.cursor.35": "resizesoutheast",
        "com.apple.cursor.36": "resizesouth",
        "com.apple.cursor.37": "resizesouthwest",
        "com.apple.cursor.38": "resizewest",
        "com.apple.cursor.39": "move",
        "com.apple.cursor.40": "help",
        "com.apple.cursor.41": "cell",
        "com.apple.cursor.42": "zoomin",
        "com.apple.cursor.43": "zoomout",
    ]
    static let namedPDFMap: [String: String] = [
        "com.apple.coregraphics.Alias":    "makealias",
        "com.apple.coregraphics.Copy":     "copy",
        "com.apple.coregraphics.ArrowCtx": "contextualmenu",
        "com.apple.coregraphics.Move":     "move",
        "com.apple.coregraphics.IBeam":    "ibeamhorizontal",
        "com.apple.coregraphics.IBeamXOR": "ibeamhorizontal",
    ]
}
