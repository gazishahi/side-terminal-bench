import AppKit
import CoreText
import Metal
import QuartzCore
import Synchronization

// The Alloy terminal renderer prototype for setups B and C: Alloy's glyph atlas and quad shaders
// (vendored from Alloy's AlloyRender, github.com/gazishahi/alloy, the atlas minus @MainActor), with a cell grid in place of
// document layout. Backgrounds, glyphs, underlines and the cursor are instanced quads in one
// draw call; a row's quads are rebuilt only when that row changed.

public struct Cell: Equatable {
    public static let bold: UInt8 = 1, italic: UInt8 = 2, underline: UInt8 = 4, wide: UInt8 = 8, spacer: UInt8 = 16, defaultBG: UInt8 = 32
    public var scalar: UInt32 = 0
    /// Set for a grapheme of more than one scalar (ZWJ emoji, flags, combining marks).
    public var cluster: String? = nil
    public var fg: UInt32 = Theme.foreground
    public var bg: UInt32 = Theme.background
    public var flags: UInt8 = Cell.defaultBG
    public init() {}
}

/// What an emulator hands the renderer once a frame.
public final class Grid {
    public let cols: Int, rows: Int
    public var cells: [[Cell]]
    public var dirty: [Bool]
    public var cursor: (x: Int, y: Int, visible: Bool) = (0, 0, true)
    public init(cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        cells = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        dirty = Array(repeating: true, count: rows)
    }
}

/// An emulator behind the renderer: copies what changed into `grid` (on the main thread, at a
/// frame) and says whether anything did.
public protocol GridSource: AnyObject {
    func snapshot(into grid: Grid) -> Bool
}

struct Quad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var kind: Float
    var padding: SIMD3<Float> = .zero
}

@MainActor
public final class GridView: NSView {
    public nonisolated let grid: Grid
    public nonisolated(unsafe) weak var source: GridSource?
    public nonisolated(unsafe) private(set) var frames = 0
    public static func cellSize(fontName: String, fontSize: CGFloat) -> CGSize {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var glyph: CGGlyph = 0; var m: UniChar = 77 // "M"
        CTFontGetGlyphsForCharacters(font, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return CGSize(width: advance.width, height: ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
    }

    // Render state: touched only by whichever thread renders (the main thread, or the render
    // thread with TERMBENCH_EXP=renderthread), never both.
    private nonisolated let font: CTFont, boldFont: CTFont
    private nonisolated let cell: CGSize
    private nonisolated let ascent: CGFloat
    private nonisolated let device = MTLCreateSystemDefaultDevice()!
    private nonisolated(unsafe) var queue: MTLCommandQueue!
    private nonisolated(unsafe) var pipeline: MTLRenderPipelineState!
    private nonisolated(unsafe) var sampler: MTLSamplerState!
    private nonisolated(unsafe) var atlas: GlyphAtlas!
    private nonisolated let metal = CAMetalLayer()
    private nonisolated(unsafe) var scale: CGFloat = 2
    private nonisolated(unsafe) var bgQuads: [[Quad]] = []
    private nonisolated(unsafe) var glyphQuads: [[Quad]] = []
    private nonisolated(unsafe) var ring: [MTLBuffer] = []
    private nonisolated(unsafe) var ringIndex = 0
    private nonisolated let inFlight = DispatchSemaphore(value: 3)
    private nonisolated(unsafe) var atlasGeneration = 0
    private var link: CADisplayLink?

    private struct GlyphKey: Hashable { let scalar: UInt32; let cluster: String?; let bold: Bool }
    private struct Placed { let entry: AtlasEntry; let dx: CGFloat }
    private nonisolated(unsafe) var glyphCache: [GlyphKey: [Placed]] = [:]

    public init(cols: Int, rows: Int, fontName: String, fontSize: CGFloat, frame: NSRect) {
        grid = Grid(cols: cols, rows: rows)
        font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        boldFont = CTFontCreateCopyWithSymbolicTraits(font, fontSize, nil, .traitBold, .traitBold) ?? font
        cell = Self.cellSize(fontName: fontName, fontSize: fontSize)
        ascent = CTFontGetAscent(font)
        super.init(frame: frame)
        queue = device.makeCommandQueue()!
        atlas = GlyphAtlas(device: device)
        wantsLayer = true
        layer = metal
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.maximumDrawableCount = Self.experiments.contains("drawables3") ? 3 : 2
        // Latency experiments (Side's terminal engine RFC, Phase 0), TERMBENCH_EXP=a,b:
        // nosync presents without waiting for the display's vsync (CAMetalLayer.displaySyncEnabled,
        // macOS only); opaque marks the layer opaque, which the window server can composite more
        // cheaply.
        if Self.experiments.contains("nosync") { metal.displaySyncEnabled = false }
        if Self.experiments.contains("opaque") { metal.isOpaque = true }
        // TERMBENCH_TXN=1: present with the Core Animation transaction, as AppKit's own drawing
        // does, instead of on Metal's schedule.
        metal.presentsWithTransaction = Self.withTransaction
        bgQuads = Array(repeating: [], count: rows)
        glyphQuads = Array(repeating: [], count: rows)
        let library = try! device.makeLibrary(source: Self.shaders, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "quadVertex")
        d.fragmentFunction = library.makeFunction(name: "quadFragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
        let s = MTLSamplerDescriptor(); s.minFilter = .nearest; s.magFilter = .nearest
        sampler = device.makeSamplerState(descriptor: s)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var acceptsFirstResponder: Bool { true }

    /// A typed key (TERMBENCH_KEYS=events): the setup writes its text to the PTY. It goes through
    /// the text input system first (interpretKeyEvents, as an NSTextInputClient), as SwiftTerm's
    /// view and Ghostty.app's do, since that's the path a real terminal view's keys take (IME).
    public var onKey: ((String) -> Void)?
    public override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        metal.contentsScale = window.backingScaleFactor
        scale = window.backingScaleFactor
        metal.drawableSize = CGSize(width: bounds.width * window.backingScaleFactor, height: bounds.height * window.backingScaleFactor)
        if Self.experiments.contains("metaldl") {
            // metaldl: vsync kept, but frames are drawn when CAMetalDisplayLink hands out a
            // drawable timed for an upcoming refresh, preferredFrameLatency frames ahead
            // (TERMBENCH_FRAME_LATENCY, default 1, the least it allows), instead of presenting
            // whenever output arrives and waiting for the refresh after that.
            let dl = CAMetalDisplayLink(metalLayer: metal)
            dl.preferredFrameLatency = Float(ProcessInfo.processInfo.environment["TERMBENCH_FRAME_LATENCY"] ?? "") ?? 1
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            metalLinkProxy.view = self
            dl.delegate = metalLinkProxy
            dl.add(to: .main, forMode: .common)
            metalLink = dl
            return
        }
        if Self.experiments.contains("renderthread") { return } // requestFrame drives the render thread
        link = displayLink(target: self, selector: #selector(tick))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)
    }

    private var metalLink: CAMetalDisplayLink?
    private let metalLinkProxy = MetalLinkProxy()

    fileprivate func metalLinkUpdate(_ drawable: CAMetalDrawable) {
        guard let source, source.snapshot(into: grid) else { return }
        _ = encode(assemble(scale: scale), into: drawable.texture, drawable: drawable)
        frames += 1
    }

    /// Output arrived: draw now rather than at the next display-link tick (which added up to a
    /// refresh interval of latency). Callable from any thread; coalesced to one pending frame.
    nonisolated static let withTransaction = ProcessInfo.processInfo.environment["TERMBENCH_TXN"] == "1"
    public nonisolated static let experiments = Set((ProcessInfo.processInfo.environment["TERMBENCH_EXP"] ?? "").split(separator: ",").map(String.init))

    public nonisolated func requestFrame() {
        if Self.experiments.contains("metaldl") { return } // the display link draws
        guard !framePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if Self.experiments.contains("renderthread") {
            // renderthread: draw on a thread of our own, as Ghostty does, instead of the main thread.
            renderQueue.async { self.framePending.store(false, ordering: .releasing); self.tick() }
            return
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.framePending.store(false, ordering: .releasing); self.tick() } }
    }
    private nonisolated let framePending = Atomic<Bool>(false)
    private nonisolated let renderQueue = DispatchQueue(label: "termbench.render", qos: .userInteractive)

    @objc private nonisolated func tick() {
        guard let source else { return }
        if source.snapshot(into: grid) { render() }
    }

    private nonisolated func color(_ rgb: UInt32) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255, 1)
    }

    /// The glyphs for one cell's text, cached: a font fallback and a shaping pass for anything
    /// the base font lacks or that is more than one scalar.
    private nonisolated func placed(_ c: Cell, scale: CGFloat) -> [Placed] {
        let bold = c.flags & Cell.bold != 0
        let key = GlyphKey(scalar: c.scalar, cluster: c.cluster, bold: bold)
        if let known = glyphCache[key] { return known }
        let base = bold ? boldFont : font
        var result: [Placed] = []
        if c.cluster == nil, c.scalar < 0x10000, let u = UnicodeScalar(c.scalar) {
            var ch = UniChar(u.value), g: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(base, &ch, &g, 1), g != 0 {
                if let e = atlas.entry(font: base, glyph: g, subpixel: 0, scale: scale, isColor: false) { result = [Placed(entry: e, dx: 0)] }
                glyphCache[key] = result
                return result
            }
        }
        let text = c.cluster ?? String(UnicodeScalar(c.scalar).map(Character.init) ?? " ")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: base]))
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attrs[kCTFontAttributeName] as! CTFont)
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for i in 0..<n {
                if let e = atlas.entry(font: runFont, glyph: glyphs[i], subpixel: 0, scale: scale, isColor: isColor) { result.append(Placed(entry: e, dx: positions[i].x)) }
            }
        }
        glyphCache[key] = result
        return result
    }

    private nonisolated func rebuild(row y: Int, scale: CGFloat) {
        var bgs: [Quad] = [], glyphs: [Quad] = []
        let cw = Float(cell.width * scale), ch = Float((cell.height * scale).rounded())
        let top = Float(y) * ch
        let baseline = top + Float((ascent * scale).rounded())
        let cells = grid.cells[y]
        var x = 0
        while x < grid.cols {
            let c = cells[x]
            if c.flags & Cell.defaultBG == 0 {
                var end = x + 1
                while end < grid.cols, cells[end].flags & Cell.defaultBG == 0, cells[end].bg == c.bg { end += 1 }
                bgs.append(Quad(rect: SIMD4(Float(x) * cw, top, Float(end - x) * cw, ch), uv: .zero, color: color(c.bg), kind: 0))
                x = end
            } else { x += 1 }
        }
        for x in 0..<grid.cols {
            let c = cells[x]
            if c.flags & Cell.underline != 0 {
                bgs.append(Quad(rect: SIMD4(Float(x) * cw, baseline + Float(scale), cw, Float(scale)), uv: .zero, color: color(c.fg), kind: 0))
            }
            guard c.flags & Cell.spacer == 0, c.scalar > 32 || c.cluster != nil else { continue }
            let penX = (Float(x) * cw).rounded(.down)
            for p in placed(c, scale: scale) where p.entry.region.width > 0 {
                let r = p.entry.region
                glyphs.append(Quad(rect: SIMD4(penX + Float(p.dx * scale + p.entry.offset.x), baseline + Float(p.entry.offset.y), Float(r.width), Float(r.height)),
                                   uv: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                                   color: p.entry.isColor ? SIMD4(1, 1, 1, 1) : color(c.fg), kind: p.entry.isColor ? 2 : 1))
            }
        }
        bgQuads[y] = bgs
        glyphQuads[y] = glyphs
    }

    private nonisolated func render() {
        let quads = assemble(scale: scale)
        guard let drawable = metal.nextDrawable() else { return }
        encode(quads, into: drawable.texture, drawable: drawable)
        frames += 1
    }

    /// Frame cost without a window: the dirty rows rebuilt, the frame encoded into a texture of
    /// `pixels`, and the GPU waited for. CPU is assembly and encoding; GPU is Metal's own timing.
    public func measureFrame(scale: CGFloat, pixels: CGSize) -> (cpuMs: Double, gpuMs: Double, quads: Int) {
        if offscreen == nil || offscreen!.width != Int(pixels.width) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(pixels.width), height: Int(pixels.height), mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            offscreen = device.makeTexture(descriptor: d)
        }
        let start = Metrics.now()
        let quads = assemble(scale: scale)
        let buffer = encode(quads, into: offscreen!, drawable: nil)
        let cpu = (Metrics.now() - start) * 1000
        buffer?.waitUntilCompleted()
        let gpu = buffer.map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 } ?? -1
        return (cpu, gpu, quads.count)
    }
    private nonisolated(unsafe) var offscreen: MTLTexture?

    private nonisolated func assemble(scale: CGFloat) -> [Quad] {
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            glyphCache.removeAll()
            for y in 0..<grid.rows { grid.dirty[y] = true }
        }
        for y in 0..<grid.rows where grid.dirty[y] {
            rebuild(row: y, scale: scale)
            grid.dirty[y] = false
        }
        // An atlas that restarted while rebuilding dropped entries rows already use.
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            glyphCache.removeAll()
            for y in 0..<grid.rows { rebuild(row: y, scale: scale) }
        }
        var quads: [Quad] = []
        quads.reserveCapacity(grid.cols * grid.rows + 64)
        for row in bgQuads { quads += row }
        if grid.cursor.visible, grid.cursor.y < grid.rows {
            let cw = Float(cell.width * scale), ch = Float((cell.height * scale).rounded())
            quads.append(Quad(rect: SIMD4(Float(grid.cursor.x) * cw, Float(grid.cursor.y) * ch, cw, ch), uv: .zero, color: SIMD4(0.8, 0.8, 0.8, 0.7), kind: 0))
        }
        for row in glyphQuads { quads += row }
        return quads
    }

    private nonisolated(unsafe) var lastQuads: [Quad] = []

    @discardableResult
    private nonisolated func encode(_ quads: [Quad], into target: MTLTexture, drawable: CAMetalDrawable?, wait: Bool = false) -> MTLCommandBuffer? {
        lastQuads = quads
        inFlight.wait()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = color(Theme.background)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return nil }
        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        if !quads.isEmpty {
            let length = quads.count * MemoryLayout<Quad>.stride
            ringIndex = (ringIndex + 1) % 3
            if ring.count < 3 { ring.append(device.makeBuffer(length: max(length, 1 << 20), options: .storageModeShared)!); ringIndex = ring.count - 1 }
            if ring[ringIndex].length < length { ring[ringIndex] = device.makeBuffer(length: length * 2, options: .storageModeShared)! }
            quads.withUnsafeBytes { ring[ringIndex].contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
            var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
            var atlasSize = Float(atlas.size)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(ring[ringIndex], offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&atlasSize, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quads.count)
        }
        encoder.endEncoding()
        if let drawable, !Self.withTransaction { buffer.present(drawable) }
        buffer.commit()
        if let drawable, Self.withTransaction { buffer.waitUntilScheduled(); drawable.present() }
        if wait { buffer.waitUntilCompleted() }
        return buffer
    }

    /// The current frame, drawn again into a readable texture and written as a PNG.
    public func writeShot(to path: String) {
        if Self.experiments.contains("renderthread") { renderQueue.sync { self.writeShotNow(to: path) }; return }
        writeShotNow(to: path)
    }

    private nonisolated func writeShotNow(to path: String) {
        lastQuads = assemble(scale: scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(metal.drawableSize.width), height: Int(metal.drawableSize.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let texture = device.makeTexture(descriptor: d)!
        encode(lastQuads, into: texture, drawable: nil, wait: true)
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // Alloy's shaders, unchanged (TextRenderer.shaders).
    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 uv; float4 color; float kind; float3 padding; };
    struct Varyings { float4 position [[position]]; float2 uv; float4 color; float kind; };
    vertex Varyings quadVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
        const float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
        Quad q = quads[iid];
        float2 corner = corners[vid];
        float2 pixel = q.rect.xy + corner * q.rect.zw;
        Varyings out;
        out.position = float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0, 1);
        out.uv = q.uv.xy + corner * q.uv.zw;
        out.color = q.color;
        out.kind = q.kind;
        return out;
    }
    fragment float4 quadFragment(Varyings in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                 sampler s [[sampler(0)]], constant float &atlasSize [[buffer(0)]]) {
        if (in.kind < 0.5) { return float4(in.color.rgb * in.color.a, in.color.a); }
        float4 texel = atlas.sample(s, in.uv / atlasSize);
        if (in.kind < 1.5) { float coverage = texel.a; return float4(in.color.rgb * in.color.a * coverage, in.color.a * coverage); }
        return texel;
    }
    """
}

/// The standard xterm 256-color palette, for setups whose emulator leaves colors to the renderer.
public let xterm256: [UInt32] = {
    var p: [UInt32] = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                       0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
    let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
    for r in steps { for g in steps { for b in steps { p.append(r << 16 | g << 8 | b) } } }
    for i in 0..<24 { let v = UInt32(8 + i * 10); p.append(v << 16 | v << 8 | v) }
    return p
}()


/// The least a terminal view needs to be a text input client: text is inserted, nothing is ever
/// marked. Enough for the input system to run its usual path for every key.
extension GridView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        onKey?(text)
    }
    public override func doCommand(by selector: Selector) {}
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    public func unmarkText() {}
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func hasMarkedText() -> Bool { false }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// CAMetalDisplayLink's delegate, on the main run loop it was added to.
private final class MetalLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    weak var view: GridView?
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let drawable = update.drawable
        MainActor.assumeIsolated { view?.metalLinkUpdate(drawable) }
    }
}
