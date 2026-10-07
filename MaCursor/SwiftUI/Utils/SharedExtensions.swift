import AppKit
import CryptoKit
import Foundation

extension UUID {
    public init(v5Namespace namespace: UUID, name: String) {
        var message = withUnsafeBytes(of: namespace.uuid) { [UInt8]($0) }
        message.append(contentsOf: Array(name.utf8))
        let digest = Insecure.SHA1.hash(data: Data(message))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension NSBitmapImageRep {

    var canonicalRGBA: NSBitmapImageRep {
        if bitsPerPixel == 32, samplesPerPixel == 4, hasAlpha, !isPlanar,
           bytesPerRow == pixelsWide * 4 {
            return self
        }
        guard pixelsWide > 0, pixelsHigh > 0,
              let source = cgImage,
              let target = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelsWide,
                  pixelsHigh: pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: pixelsWide * 4,
                  bitsPerPixel: 32
              ),
              let context = NSGraphicsContext(bitmapImageRep: target)
        else { return self }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.interpolationQuality = .none
        context.cgContext.draw(source,
                               in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }
}
