import AppKit
import GhosttyKit
import Harness

// Setup D: full libghostty, embedded the way Ghostty.app embeds it (Ghostty.App.swift,
// SurfaceView_AppKit.swift): one app, one surface on an NSView, Ghostty's own IO thread,
// emulator and Metal renderer. Its config is ours only (no ~/.config/ghostty).

@MainActor var app: ghostty_app_t?
@MainActor var exited = false

final class SurfaceHost: NSView {
    override var acceptsFirstResponder: Bool { true }
    var surface: ghostty_surface_t?

    /// A typed key (TERMBENCH_KEYS=events), handed to Ghostty as Ghostty.app's keyDown hands it
    /// (SurfaceView_AppKit): through the text input system first (interpretKeyEvents, as an
    /// NSTextInputClient), then a press with its keycode, the text the input system produced and
    /// the unshifted codepoint.
    private var typed: String?
    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        Stages.mark("keyDown")
        typed = nil
        interpretKeyEvents([event])
        let text = typed ?? ""
        text.withCString { c in
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.mods = GHOSTTY_MODS_NONE
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.keycode = UInt32(event.keyCode)
            key.text = text.isEmpty ? nil : c
            key.unshifted_codepoint = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first.map { $0.value } ?? 0
            key.composing = false
            _ = ghostty_surface_key(surface, key)
            Stages.mark("keySent")
        }
    }
}

extension SurfaceHost: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

@MainActor
func startD(options: Options, view: SurfaceHost) {
    let configPath = NSTemporaryDirectory() + "termbench-ghostty.conf"
    let config = """
    font-family = \(options.fontName)
    font-size = \(Int(options.fontSize))
    background = \(String(format: "%06x", Theme.background))
    foreground = \(String(format: "%06x", Theme.foreground))
    window-padding-x = 0
    window-padding-y = 0
    window-padding-balance = false
    cursor-style-blink = false
    shell-integration = none
    confirm-close-surface = false
    wait-after-command = true
    scrollback-limit = 10000000
    \(ProcessInfo.processInfo.environment["TERMBENCH_GHOSTTY_CONFIG"] ?? "")
    """
    try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new") }
    ghostty_config_load_file(cfg, configPath)
    ghostty_config_finalize(cfg)

    var runtime = ghostty_runtime_config_s(
        userdata: nil,
        supports_selection_clipboard: false,
        wakeup_cb: { _ in Stages.mark("wakeup"); DispatchQueue.main.async { MainActor.assumeIsolated { if let app { ghostty_app_tick(app) } } } },
        action_cb: { _, _, action in
            if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
                DispatchQueue.main.async { MainActor.assumeIsolated { checkExited() } }
                return true
            }
            return false
        },
        read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
        confirm_read_clipboard_cb: { _, _, _, _ in },
        write_clipboard_cb: { _, _, _, _, _ in },
        close_surface_cb: { _, _ in }
    )
    app = ghostty_app_new(&runtime, cfg)
    guard let app else { fatalError("ghostty_app_new") }

    // Ghostty starts commands through login and bash -c exec on macOS; the clock starts only
    // once the shell is waiting, so that startup isn't measured.
    let command = options.command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let scale = view.window?.backingScaleFactor ?? 2
    // One surface per session: the first shown, the rest in hidden tabs (hidden and occluded).
    var hosts: [SurfaceHost] = [view]
    let extra = options.mode == "latency" ? options.load : options.sessions - 1
    for _ in 0..<max(0, extra) {
        let hidden = SurfaceHost(frame: view.frame)
        hidden.isHidden = true
        view.superview?.addSubview(hidden)
        hosts.append(hidden)
    }
    for (i, host) in hosts.enumerated() {
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(host).toOpaque()))
        sc.scale_factor = Double(scale)
        sc.font_size = Float(options.fontSize)
        sc.wait_after_command = true
        var made: ghostty_surface_t?
        let loadCommand = options.loadCommand.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        (options.mode == "latency" && i > 0 ? loadCommand : command).withCString { c in
            sc.command = c
            made = ghostty_surface_new(app, &sc)
        }
        guard let made else { fatalError("ghostty_surface_new") }
        ghostty_surface_set_content_scale(made, scale, scale)
        // Ghostty's cell size, then the size that holds exactly the grid asked for.
        let cell = ghostty_surface_size(made)
        let points = NSSize(width: CGFloat(UInt32(options.cols) * cell.cell_width_px) / scale, height: CGFloat(UInt32(options.rows) * cell.cell_height_px) / scale)
        if i == 0 { view.window?.setContentSize(points) }
        host.frame = NSRect(origin: .zero, size: points)
        ghostty_surface_set_size(made, UInt32(points.width * scale), UInt32(points.height * scale))
        ghostty_surface_set_occlusion(made, i == 0)
        // As Ghostty.app does (SurfaceView_AppKit): the display its frames are paced to.
        if ProcessInfo.processInfo.environment["TERMBENCH_NO_DISPLAY_ID"] == nil,
           let n = view.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(made, n.uint32Value)
        }
        ghostty_surface_set_focus(made, i == 0)
        host.surface = made
        surfaces.append(made)
    }
    ghostty_app_set_focus(app, true)
    let size = ghostty_surface_size(surfaces[0])
    Run.shared.grid = "\(size.columns)x\(size.rows)"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Run.shared.begin()
        if options.mode == "latency" { ghostty_surface_text(surfaces[0], "\n", 1) } else { for s in surfaces { ghostty_surface_text(s, "\n", 1) } }
    }
    if options.mode == "latency" {
        let cell = CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
        let first = surfaces[0]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let row = Latency.echoRow(view: view, cellSize: cell)
            Latency.run(window: view.window!, cell: { _ in row }, send: { ghostty_surface_text(first, "X", 1) })
        }
    }
    // The exit action prompts a check; polling catches a missed one.
    Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in MainActor.assumeIsolated { checkExited() } }
}

@MainActor var surfaces: [ghostty_surface_t] = []

@MainActor
func checkExited() {
    guard !exited, !surfaces.isEmpty, surfaces.allSatisfy({ ghostty_surface_process_exited($0) }) else { return }
    exited = true
    Run.shared.finish()
}

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { fatalError("ghostty_init") }
let nsapp = NSApplication.shared
Metrics.captureMainThread()
let options = MainActor.assumeIsolated { Run.shared.options }
var window: NSWindow?
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        let view = SurfaceHost(frame: NSRect(x: 0, y: 0, width: options.width, height: options.height))
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        window = makeWindow(content: container, options: options)
        window?.makeFirstResponder(view)
        Run.shared.shot = { path in
            // Ghostty draws into an IOSurface it sets as a layer's contents.
            func find(_ layer: CALayer?) -> IOSurface? {
                guard let layer else { return nil }
                if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() { return (contents as! IOSurface) }
                for sub in layer.sublayers ?? [] { if let s = find(sub) { return s } }
                return nil
            }
            guard let io = find(view.layer) else { print("no IOSurface found"); return }
            let image = CIImage(ioSurface: io)
            let rep = NSBitmapImageRep(ciImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startD(options: options, view: view) }
    }
}
nsapp.run()
