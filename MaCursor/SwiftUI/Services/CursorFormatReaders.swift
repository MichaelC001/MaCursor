import CoreGraphics
import Foundation
import ImageIO

struct BinaryReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var count: Int { bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw CursorReadError.truncated(context: "seek to \(newOffset) in \(bytes.count)-byte data")
        }
        offset = newOffset
    }

    func peekByte() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    mutating func readBytes(_ n: Int, context: String) throws -> [UInt8] {
        guard n >= 0, offset <= bytes.count - n else {
            throw CursorReadError.truncated(context: context)
        }
        defer { offset += n }
        return Array(bytes[offset ..< offset + n])
    }

    mutating func readData(_ n: Int, context: String) throws -> Data {
        Data(try readBytes(n, context: context))
    }

    mutating func u8(_ context: String) throws -> Int {
        Int(try readBytes(1, context: context)[0])
    }

    mutating func u16le(_ context: String) throws -> Int {
        let b = try readBytes(2, context: context)
        return Int(b[0]) | (Int(b[1]) << 8)
    }

    mutating func u32le(_ context: String) throws -> Int {
        let b = try readBytes(4, context: context)
        return Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
    }

    mutating func i32le(_ context: String) throws -> Int {
        let u = UInt32(truncatingIfNeeded: try u32le(context))
        return Int(Int32(bitPattern: u))
    }
}

public enum CURReader: CursorFormat {
    public static let identifier = "cur"

    static let curMagic: [UInt8] = [0x00, 0x00, 0x02, 0x00]
    static let icoMagic: [UInt8] = [0x00, 0x00, 0x01, 0x00]
    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

    public static func matches(firstBytes: Data) -> Bool {
        let head = [UInt8](firstBytes.prefix(4))
        return head == curMagic || head == icoMagic
    }

    public static func read(_ data: Data) throws -> AnimatedCursor {
        AnimatedCursor(frames: [.init(cursor: try readStaticCursor(data), delayMS: 100)])
    }

    static func readStaticCursor(_ data: Data) throws -> Cursor {
        var pngPixelBudget = maxPNGPixelsPerFile
        return try readStaticCursor(data, pngPixelBudget: &pngPixelBudget)
    }

    static func readStaticCursor(_ data: Data, pngPixelBudget: inout Int) throws -> Cursor {
        var reader = BinaryReader(data)
        let magic = try reader.readBytes(4, context: "cur magic")
        let isICO: Bool
        switch magic {
        case curMagic: isICO = false
        case icoMagic: isICO = true
        default: throw CursorReadError.notThisFormat("not a .cur/.ico file")
        }

        let count = try reader.u16le("entry count")
        guard count > 0 else { throw CursorReadError.malformed("no entries in .cur") }

        var directory = reader
        let ranges = try (0 ..< count).map { index -> Range<Int> in
            try directory.seek(to: 6 + index * 16 + 8)
            let size = try directory.u32le("entry \(index) size")
            let offset = try directory.u32le("entry \(index) offset")
            return offset ..< offset + size
        }
        try validateDirectory(ranges, in: data, pngPixelBudget: &pngPixelBudget)

        var cursor = Cursor()
        for index in 0 ..< count {
            var width = try reader.u8("entry \(index) width")
            var height = try reader.u8("entry \(index) height")
            if width == 0 { width = 256 }
            if height == 0 { height = 256 }
            _ = try reader.u8("entry \(index) colors")
            _ = try reader.u8("entry \(index) reserved")
            let planes = try reader.u16le("entry \(index) planes")
            let bitCount = try reader.u16le("entry \(index) bpp")
            let bytesInRes = try reader.u32le("entry \(index) size")
            let imageOffset = try reader.u32le("entry \(index) offset")

            guard imageOffset >= 0, bytesInRes > 0, imageOffset + bytesInRes <= data.count else {
                throw CursorReadError.truncated(context: "entry \(index) image data")
            }
            let blob = data.subdata(in: data.startIndex + imageOffset
                                     ..< data.startIndex + imageOffset + bytesInRes)

            let image: CGImage
            if [UInt8](blob.prefix(4)) == pngMagic {
                guard let source = CGImageSourceCreateWithData(blob as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw CursorReadError.unsupportedImage("entry \(index): undecodable PNG")
                }
                image = decoded
            } else {
                image = try DIBDecoder.decode(blob)
            }

            var hotX = isICO ? 0 : planes
            var hotY = isICO ? 0 : bitCount
            if !(0 ..< image.width).contains(hotX) { hotX = 0 }
            if !(0 ..< image.height).contains(hotY) { hotY = 0 }

            cursor.add(try CursorImage(image: image, hotspot: CGPoint(x: hotX, y: hotY)))
        }
        return cursor
    }

    static let maxEntries = 64
    static let maxPNGSide = 1024
    static let maxPNGPixelsPerFile = maxEntries * maxPNGSide * maxPNGSide

    static func validateDirectory(_ ranges: [Range<Int>], in data: Data, pngPixelBudget: inout Int) throws {
        guard ranges.count <= maxEntries else {
            throw CursorReadError.malformed("more than \(maxEntries) image entries")
        }
        guard !imageRangesOverlap(ranges) else {
            throw CursorReadError.malformed("image entries overlap")
        }
        for range in ranges where !range.isEmpty {
            let head = [UInt8](data.dropFirst(range.lowerBound).prefix(min(range.count, 24)))
            guard head.count == 24, head.starts(with: pngMagic) else { continue }
            guard head[12 ..< 16].elementsEqual("IHDR".utf8) else {
                throw CursorReadError.malformed("PNG entry does not start with an IHDR chunk")
            }
            let width = head[16 ..< 20].reduce(0) { $0 << 8 | Int($1) }
            let height = head[20 ..< 24].reduce(0) { $0 << 8 | Int($1) }
            guard width <= maxPNGSide, height <= maxPNGSide else {
                throw CursorReadError.malformed("PNG entries exceed \(maxPNGSide)x\(maxPNGSide) pixels")
            }
            guard width * height <= pngPixelBudget else {
                throw CursorReadError.malformed("PNG entries exceed \(maxPNGPixelsPerFile) pixels in one file")
            }
            pngPixelBudget -= width * height
        }
    }

    static func imageRangesOverlap(_ ranges: [Range<Int>]) -> Bool {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        return zip(sorted, sorted.dropFirst()).contains { $0.upperBound > $1.lowerBound }
    }
}

enum DIBDecoder {
    static func decode(_ dib: Data) throws -> CGImage {
        var reader = BinaryReader(dib)
        let biSize = try reader.u32le("biSize")
        guard biSize >= 40 else {
            throw CursorReadError.unsupportedImage("BITMAPCOREHEADER (biSize \(biSize)) not supported")
        }
        let width = try reader.i32le("biWidth")
        let doubledHeight = try reader.i32le("biHeight")
        _ = try reader.u16le("biPlanes")
        let bitCount = try reader.u16le("biBitCount")
        let compression = try reader.u32le("biCompression")
        _ = try reader.u32le("biSizeImage")
        _ = try reader.i32le("biXPelsPerMeter")
        _ = try reader.i32le("biYPelsPerMeter")
        let clrUsed = try reader.u32le("biClrUsed")
        _ = try reader.u32le("biClrImportant")

        guard width > 0, doubledHeight > 0, doubledHeight % 2 == 0,
              width <= 0x7FFF, doubledHeight <= 0xFFFE else {
            throw CursorReadError.malformed("DIB dimensions \(width)x\(doubledHeight)")
        }
        let height = doubledHeight / 2
        guard [1, 4, 8, 16, 24, 32].contains(bitCount) else {
            throw CursorReadError.unsupportedImage("\(bitCount)bpp DIB")
        }
        switch (compression, bitCount) {
        case (0, _): break
        case (3, 32): break
        default:
            throw CursorReadError.unsupportedImage("DIB compression \(compression) at \(bitCount)bpp")
        }

        let colorCount = clrUsed != 0 ? clrUsed : (bitCount <= 8 ? 1 << bitCount : 0)
        var pixelOffset = biSize + colorCount * 4
        if compression == 3 {
            let masks = try (0 ..< 3).map { _ in try reader.u32le("bitfield mask") }
            guard masks == [0x00FF_0000, 0x0000_FF00, 0x0000_00FF] else {
                throw CursorReadError.unsupportedImage("nonstandard BI_BITFIELDS masks")
            }
            if biSize == 40 { pixelOffset += 12 }
        }

        let xorRowBytes = ((width * bitCount + 31) / 32) * 4
        let andRowBytes = ((width + 31) / 32) * 4
        let xorSize = xorRowBytes * height
        guard pixelOffset + xorSize <= dib.count else {
            throw CursorReadError.truncated(context: "DIB XOR block")
        }
        let maskOffset = pixelOffset + xorSize
        let maskAvailable = maskOffset + andRowBytes * height <= dib.count

        func maskBitSet(_ x: Int, _ y: Int) -> Bool {
            guard maskAvailable else { return false }
            let row = height - 1 - y
            let byte = dib[dib.startIndex + maskOffset + row * andRowBytes + x / 8]
            return (byte >> (7 - x % 8)) & 1 == 1
        }

        if bitCount == 32 {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            var alphaAllZero = true
            dib.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for y in 0 ..< height {
                    let rowStart = pixelOffset + (height - 1 - y) * xorRowBytes
                    for x in 0 ..< width {
                        let p = rowStart + x * 4
                        let out = (y * width + x) * 4
                        rgba[out] = raw[p + 2]
                        rgba[out + 1] = raw[p + 1]
                        rgba[out + 2] = raw[p]
                        rgba[out + 3] = raw[p + 3]
                        if raw[p + 3] != 0 { alphaAllZero = false }
                    }
                }
            }
            if alphaAllZero {
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        rgba[(y * width + x) * 4 + 3] = maskBitSet(x, y) ? 0 : 255
                    }
                }
            }
            return try ImageScaler.makeImage(rgba: rgba, width: width, height: height)
        }

        var bmp = Data()
        bmp.append(contentsOf: [0x42, 0x4D])
        let fileHeaderSize = 14
        let bmpPixelOffset = fileHeaderSize + pixelOffset
        let fileSize = bmpPixelOffset + xorSize
        func appendU32(_ v: Int) {
            bmp.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                    UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        appendU32(fileSize)
        appendU32(0)
        appendU32(bmpPixelOffset)
        var header = dib.subdata(in: dib.startIndex ..< dib.startIndex + pixelOffset)
        withUnsafeBytes(of: Int32(height).littleEndian) { header.replaceSubrange(8 ..< 12, with: $0) }
        withUnsafeBytes(of: UInt32(xorSize).littleEndian) { header.replaceSubrange(20 ..< 24, with: $0) }
        bmp.append(header)
        bmp.append(dib.subdata(in: dib.startIndex + pixelOffset ..< dib.startIndex + pixelOffset + xorSize))

        guard let source = CGImageSourceCreateWithData(bmp as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CursorReadError.unsupportedImage("\(bitCount)bpp DIB: BMP decode failed")
        }

        let ctx = try ImageScaler.rgbaContext(width: width, height: height)
        ctx.interpolationQuality = .none
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = ctx.data else {
            throw CursorReadError.unsupportedImage("DIB compositing context has no backing store")
        }
        let bytesPerRow = ctx.bytesPerRow
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let src = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for y in 0 ..< height {
            let srcRow = y * bytesPerRow
            for x in 0 ..< width {
                let s = srcRow + x * 4
                let d = (y * width + x) * 4
                let transparent = maskBitSet(x, y)
                rgba[d] = transparent ? 0 : src[s]
                rgba[d + 1] = transparent ? 0 : src[s + 1]
                rgba[d + 2] = transparent ? 0 : src[s + 2]
                rgba[d + 3] = transparent ? 0 : 255
            }
        }
        return try ImageScaler.makeImage(rgba: rgba, width: width, height: height)
    }
}

public enum ANIReader: CursorFormat {
    public static let identifier = "ani"

    public static func matches(firstBytes: Data) -> Bool {
        let head = [UInt8](firstBytes.prefix(12))
        return head.count >= 12
            && Array(head[0 ..< 4]) == Array("RIFF".utf8)
            && Array(head[8 ..< 12]) == Array("ACON".utf8)
    }

    private struct Header {
        var numFrames: Int
        var numSteps: Int
        var displayRate: Int
        var containsSeq: Bool
        var isInIco: Bool
    }

    public static func read(_ data: Data) throws -> AnimatedCursor {
        guard matches(firstBytes: data.prefix(12)) else {
            throw CursorReadError.notThisFormat("not a .ani file")
        }

        var reader = BinaryReader(data)
        try reader.seek(to: 12)

        var header: Header?
        var icons: [Cursor] = []
        var seq: [Int]?
        var rate: [Int]?
        var pngPixelBudget = CURReader.maxPNGPixelsPerFile

        try walkChunks(&reader, end: reader.count, depth: 0) { id, chunk in
            switch id {
            case "anih":
                guard header == nil else { throw CursorReadError.malformed("this ani has 2 headers") }
                var payload = chunk
                if payload.count == 36 { payload = payload.dropFirst(4) }
                guard payload.count >= 32 else {
                    throw CursorReadError.truncated(context: "anih payload")
                }
                var h = BinaryReader(Data(payload))
                let numFrames = try h.u32le("numFrames")
                let numSteps = try h.u32le("numSteps")
                try h.seek(to: 24)
                let displayRate = try h.u32le("displayRate")
                let flags = try h.u32le("flags")
                guard numFrames > 0, numSteps > 0 else {
                    throw CursorReadError.malformed("anih with zero frames/steps")
                }
                guard numSteps <= 4096, numFrames <= 4096 else {
                    throw CursorReadError.malformed("anih frames/steps implausibly large")
                }
                header = Header(numFrames: numFrames,
                                numSteps: numSteps,
                                displayRate: displayRate,
                                containsSeq: (flags >> 1) & 1 == 1,
                                isInIco: flags & 1 == 1)
            case "icon":
                guard let h = header else { throw CursorReadError.malformed("icon chunk before header") }
                if h.isInIco {
                    icons.append(try CURReader.readStaticCursor(chunk, pngPixelBudget: &pngPixelBudget))
                } else {
                    let image = try DIBDecoder.decode(chunk)
                    icons.append(Cursor([try CursorImage(image: image, hotspot: .zero)]))
                }
            case "seq ":
                guard let h = header else { throw CursorReadError.malformed("seq chunk before header") }
                guard chunk.count / 4 == h.numSteps else {
                    throw CursorReadError.malformed("seq length != numSteps")
                }
                var s = BinaryReader(chunk)
                seq = try (0 ..< h.numSteps).map { _ in try s.u32le("seq entry") }
            case "rate":
                guard let h = header else { throw CursorReadError.malformed("rate chunk before header") }
                guard chunk.count / 4 == h.numSteps else {
                    throw CursorReadError.malformed("rate length != numSteps")
                }
                var r = BinaryReader(chunk)
                rate = try (0 ..< h.numSteps).map { _ in try r.u32le("rate entry") }
            default:
                break
            }
        }

        guard let h = header else { throw CursorReadError.malformed("no anih header") }
        guard !icons.isEmpty else { throw CursorReadError.malformed("no icon frames") }

        let finalSeq = seq ?? (0 ..< h.numSteps).map { $0 % h.numFrames }
        let finalRate = rate ?? Array(repeating: h.displayRate, count: h.numSteps)

        var frames: [AnimatedCursor.Frame] = []
        for (index, jiffies) in zip(finalSeq, finalRate) {
            guard icons.indices.contains(index) else {
                throw CursorReadError.malformed("seq index \(index) out of range (\(icons.count) icons)")
            }
            frames.append(.init(cursor: icons[index], delayMS: jiffies * 1000 / 60))
        }
        return AnimatedCursor(frames: frames)
    }

    static let maxChunkDepth = 8

    private static func walkChunks(_ reader: inout BinaryReader, end: Int, depth: Int,
                                   handle: (String, Data) throws -> Void) throws {
        guard depth <= maxChunkDepth else {
            throw CursorReadError.malformed("LIST nesting too deep")
        }
        while reader.offset + 8 <= end {
            let idBytes = try reader.readBytes(4, context: "chunk id")
            let id = String(decoding: idBytes, as: UTF8.self)
            let declaredSize = try reader.u32le("chunk \(id) size")
            let size = min(declaredSize, end - reader.offset)
            if id == "LIST" {
                let subEnd = reader.offset + size
                if subEnd - reader.offset >= 4 {
                    _ = try reader.readBytes(4, context: "LIST form type")
                }
                try walkChunks(&reader, end: subEnd, depth: depth + 1, handle: handle)
                try reader.seek(to: subEnd)
            } else {
                try handle(id, try reader.readData(size, context: "chunk \(id) data"))
            }
            if size % 2 == 1, reader.peekByte() == 0 {
                _ = try reader.readBytes(1, context: "chunk pad byte")
            }
        }
    }
}

public enum XCursorReader: CursorFormat {
    public static let identifier = "xcur"

    static let headerSize = 16
    static let cursorType = 0xFFFD_0002
    static let imageChunkHeaderSize = 36

    public static func matches(firstBytes: Data) -> Bool {
        [UInt8](firstBytes.prefix(4)) == Array("Xcur".utf8)
    }

    public static func read(_ data: Data) throws -> AnimatedCursor {
        var reader = BinaryReader(data)
        guard try reader.readBytes(4, context: "magic") == Array("Xcur".utf8) else {
            throw CursorReadError.notThisFormat("not an Xcursor file")
        }
        guard try reader.u32le("header size") == headerSize else {
            throw CursorReadError.malformed("header size is not \(headerSize)")
        }
        _ = try reader.u32le("version")
        let nToc = try reader.u32le("toc count")

        var offsetsBySize: [Int: [Int]] = [:]
        for _ in 0 ..< nToc {
            let type = try reader.u32le("toc type")
            let subtype = try reader.u32le("toc subtype")
            let position = try reader.u32le("toc position")
            if type == cursorType {
                offsetsBySize[subtype, default: []].append(position)
            }
        }
        guard !offsetsBySize.isEmpty else {
            throw CursorReadError.malformed("no cursor images in Xcursor file")
        }

        var chunkReader = reader
        let chunks = try offsetsBySize.values.joined().map { position -> Range<Int> in
            try chunkReader.seek(to: position + 16)
            let (width, height) = try readImageSize(&chunkReader)
            return position ..< position + imageChunkHeaderSize + width * height * 4
        }
        guard !CURReader.imageRangesOverlap(chunks) else {
            throw CursorReadError.malformed("Xcursor image chunks overlap")
        }

        let frameCount = offsetsBySize.values.map(\.count).max() ?? 0
        var frames: [AnimatedCursor.Frame] = []
        for frameIndex in 0 ..< frameCount {
            var cursor = Cursor()
            var delays: [Int] = []
            for (nominal, offsets) in offsetsBySize.sorted(by: { $0.key < $1.key }) {
                guard frameIndex < offsets.count else { continue }
                let (image, hotX, hotY, delayMS) = try readImageChunk(
                    reader, at: offsets[frameIndex], nominalSize: nominal)
                cursor.add(try CursorImage(image: image, hotspot: CGPoint(x: hotX, y: hotY)))
                delays.append(delayMS)
            }
            frames.append(.init(cursor: cursor, delayMS: delays.max() ?? 0))
        }
        return AnimatedCursor(frames: frames)
    }

    private static func readImageSize(_ reader: inout BinaryReader) throws -> (Int, Int) {
        let width = try reader.u32le("width")
        let height = try reader.u32le("height")
        guard width <= 0x7FFF, height <= 0x7FFF, width > 0, height > 0 else {
            throw CursorReadError.malformed("invalid Xcursor image dimensions \(width)x\(height)")
        }
        return (width, height)
    }

    private static func readImageChunk(
        _ file: BinaryReader, at offset: Int, nominalSize: Int
    ) throws -> (CGImage, Int, Int, Int) {
        var reader = file
        try reader.seek(to: offset)
        guard try reader.u32le("chunk header size") == imageChunkHeaderSize else {
            throw CursorReadError.malformed("image chunks must be \(imageChunkHeaderSize) bytes")
        }
        guard try reader.u32le("chunk type") == cursorType else {
            throw CursorReadError.malformed("chunk type does not match TOC")
        }
        guard try reader.u32le("chunk subtype") == nominalSize else {
            throw CursorReadError.malformed("nominal sizes in TOC and image header don't match")
        }
        guard try reader.u32le("chunk version") == 1 else {
            throw CursorReadError.malformed("unsupported image chunk version")
        }
        let (width, height) = try readImageSize(&reader)
        var hotX = try reader.u32le("xhot")
        var hotY = try reader.u32le("yhot")
        let delayMS = try reader.u32le("delay")

        if !(0 ..< width).contains(hotX) { hotX = 0 }
        if !(0 ..< height).contains(hotY) { hotY = 0 }

        let pixels = try reader.readBytes(width * height * 4, context: "pixel data")
        var rgba = [UInt8](repeating: 0, count: pixels.count)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            rgba[i] = pixels[i + 2]
            rgba[i + 1] = pixels[i + 1]
            rgba[i + 2] = pixels[i]
            rgba[i + 3] = pixels[i + 3]
        }
        let image = try ImageScaler.makeImage(rgba: rgba, width: width, height: height)
        return (image, hotX, hotY, delayMS)
    }
}

public protocol CursorFormat: Sendable {
    static var identifier: String { get }

    static func matches(firstBytes: Data) -> Bool

    static func read(_ data: Data) throws -> AnimatedCursor
}

public enum CursorFormatRegistry {
    public static let all: [any CursorFormat.Type] = [
        CURReader.self,
        ANIReader.self,
        XCursorReader.self,
    ]

    public static func format(matching data: Data) -> (any CursorFormat.Type)? {
        let head = data.prefix(12)
        return all.first { $0.matches(firstBytes: head) }
    }

    public static func readCursorFile(_ data: Data) throws -> AnimatedCursor? {
        guard let format = format(matching: data) else { return nil }
        return try format.read(data)
    }
}
