import CoreGraphics
import CoreText
import Metal

/// Where a rasterized glyph sits in the atlas, and how to place it relative to its pen position.
struct AtlasEntry {
    /// Pixels in the atlas texture.
    let region: CGRect
    /// Offset from the (pixel-snapped) pen position to the bitmap's top-left, in pixels.
    let offset: CGPoint
    let isColor: Bool
}

/// Every glyph drawn, rasterized once by CoreGraphics into one BGRA texture: coverage in alpha
/// (white) for ordinary glyphs, which the shader tints, and full color for emoji. Keyed by font,
/// glyph, screen scale and a quarter-pixel horizontal position, so text sits where CoreText put
/// it rather than snapped to whole pixels.
@MainActor
final class GlyphAtlas {
    private(set) var texture: MTLTexture
    private(set) var size: Int
    private let device: MTLDevice
    static let subpixelSteps = 4
    /// It starts small (4 MB) and doubles when a document needs more glyphs than fit, up to this
    /// (64 MB); past it, it starts over. Most documents never grow it.
    static let maximumSize = 4096

    private struct Key: Hashable {
        let font: String
        let pointSize: CGFloat
        let glyph: CGGlyph
        let subpixel: Int
        let scale: CGFloat
    }

    private var entries: [Key: AtlasEntry] = [:]
    /// Client images (a typeset formula), by the client's key.
    private var images: [String: AtlasEntry] = [:]
    private var penX = 1
    private var penY = 1
    private var shelfHeight = 0
    /// Bumped when the atlas fills and starts over; a frame drawn from older entries redraws.
    private(set) var generation = 0

    init(device: MTLDevice, size: Int = 1024) {
        self.device = device
        self.size = size
        texture = Self.makeTexture(device: device, size: size)
    }

    private static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)!
    }

    var count: Int { entries.count }

    /// Each font's name and size, asked of CoreText once: copying and bridging the name for
    /// every glyph of every frame was a tenth of a scrolling frame (2026-10-01). The fonts are
    /// held, so an address can't be reused by another font while it's a key.
    private var fontKeys: [ObjectIdentifier: (font: CTFont, name: String, size: CGFloat)] = [:]

    private func fontKey(_ font: CTFont) -> (name: String, size: CGFloat) {
        let id = ObjectIdentifier(font)
        if let known = fontKeys[id] { return (known.name, known.size) }
        if fontKeys.count > 64 { fontKeys.removeAll() }
        let name = CTFontCopyPostScriptName(font) as String, size = CTFontGetSize(font)
        fontKeys[id] = (font, name, size)
        return (name, size)
    }

    func entry(font: CTFont, glyph: CGGlyph, subpixel: Int, scale: CGFloat, isColor: Bool) -> AtlasEntry? {
        let (name, pointSize) = fontKey(font)
        let key = Key(font: name, pointSize: pointSize, glyph: glyph, subpixel: subpixel, scale: scale)
        if let cached = entries[key] { return cached }
        var glyphCopy = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphCopy, &bounds, 1)
        // A space has no ink: remember an empty entry so it isn't asked for again.
        guard bounds.width > 0, bounds.height > 0 else {
            let empty = AtlasEntry(region: .zero, offset: .zero, isColor: isColor)
            entries[key] = empty
            return empty
        }
        let shift = CGFloat(subpixel) / CGFloat(Self.subpixelSteps)
        let padding: CGFloat = 1
        let minX = floor(bounds.minX * scale + shift) - padding
        let maxX = ceil(bounds.maxX * scale + shift) + padding
        let minY = floor(bounds.minY * scale) - padding
        let maxY = ceil(bounds.maxY * scale) + padding
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        guard width < size, height < size else { return nil }

        allocate(width: width, height: height)

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.scaleBy(x: scale, y: scale)
            var position = CGPoint(x: (-minX + shift) / scale, y: -minY / scale)
            CTFontDrawGlyphs(font, &glyphCopy, &position, 1, context)
        }
        texture.replace(region: MTLRegionMake2D(penX, penY, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        // The bitmap's top-left relative to the pen at the baseline, y down.
        let entry = AtlasEntry(region: CGRect(x: penX, y: penY, width: width, height: height),
                               offset: CGPoint(x: minX - shift, y: -maxY), isColor: isColor)
        entries[key] = entry
        penX += width + 1
        shelfHeight = max(shelfHeight, height)
        return entry
    }

    /// Makes room for a bitmap at the pen: the next shelf, or a bigger atlas (or a fresh one).
    private func allocate(width: Int, height: Int) {
        if penX + width + 1 > size {
            penX = 1
            penY += shelfHeight + 1
            shelfHeight = 0
        }
        if penY + height + 1 > size {
            // Full: twice the size if it can grow, else start over. Either way the text on
            // screen is re-rasterized on the next frame.
            if size < Self.maximumSize {
                size *= 2
                texture = Self.makeTexture(device: device, size: size)
            }
            entries.removeAll()
            images.removeAll()
            penX = 1
            penY = 1
            shelfHeight = 0
            generation += 1
        }
    }

    /// A client's image (drawn in its own colors), placed with its top `ascent` points above the
    /// pen at the baseline. Pixels as given: the client renders at the screen's scale.
    func entry(image: CGImage, key: String, ascent: CGFloat, scale: CGFloat) -> AtlasEntry? {
        let full = key + "@\(scale)"
        if let cached = images[full] { return cached }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width + 2 < size || size < Self.maximumSize, height + 2 < Self.maximumSize, width + 2 < Self.maximumSize else { return nil }
        while width + 2 >= size || height + 2 >= size {
            size *= 2
            texture = Self.makeTexture(device: device, size: size)
            entries.removeAll()
            images.removeAll()
            penX = 1; penY = 1; shelfHeight = 0
            generation += 1
        }
        allocate(width: width, height: height)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        texture.replace(region: MTLRegionMake2D(penX, penY, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        let entry = AtlasEntry(region: CGRect(x: penX, y: penY, width: width, height: height), offset: CGPoint(x: 0, y: -(ascent * scale).rounded()), isColor: true)
        images[full] = entry
        penX += width + 1
        shelfHeight = max(shelfHeight, height)
        return entry
    }
}
