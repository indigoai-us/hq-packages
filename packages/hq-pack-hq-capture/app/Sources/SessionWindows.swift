// Windows that sit on screen during a recording: the Recording badge and the teleprompter.
// Both use sharingType none from creation, so they never appear in the screen track.

import AppKit
import SwiftUI

/// A panel that is never captured. CaptureHiding.restore leaves these hidden after recording.
final class NeverCapturedPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        sharingType = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The panel stays out of capture whatever a caller sets.
    override var sharingType: NSWindow.SharingType {
        get { super.sharingType }
        set { super.sharingType = .none }
    }
}

/// Where the Recording badge sits: the far lower-right corner of the recorded screen.
enum RecordingBadgePlacement {
    static let size = CGSize(width: 136, height: 38)
    static let margin: CGFloat = 6

    /// The badge frame in screen coordinates for a screen whose full frame is `screenFrame`.
    static func frame(in screenFrame: CGRect, size: CGSize = size, margin: CGFloat = margin) -> CGRect {
        CGRect(x: screenFrame.maxX - size.width - margin, y: screenFrame.minY + margin,
               width: size.width, height: size.height)
    }

    /// The screen being recorded: the chosen display, or the screen holding most of the chosen
    /// window. Falls back to the main screen.
    @MainActor
    static func screen(for source: ScreenSource?, windowFrame: CGRect? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        switch source?.kind {
        case .display:
            if let match = screens.first(where: { displayID(of: $0) == source?.id }) { return match }
        case .window:
            if let windowFrame, let match = screens.max(by: {
                area($0.frame.intersection(windowFrame)) < area($1.frame.intersection(windowFrame))
            }), area(match.frame.intersection(windowFrame)) > 0 { return match }
        case nil:
            break
        }
        return NSScreen.main ?? screens.first
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// A window's frame in AppKit screen coordinates, from the window server's top-left bounds.
    @MainActor
    static func windowFrame(_ windowID: UInt32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID))
                as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let primary = NSScreen.screens.first else { return nil }
        return flipped(rect, primaryHeight: primary.frame.height)
    }

    /// Converts a top-left-origin rect to AppKit's bottom-left origin.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The badge's words. Color only marks the state.
    static func label(paused: Bool) -> String { paused ? "Paused" : "Recording" }
}

/// The always-on-top badge shown while any capture is active.
@MainActor
final class RecordingBadgeWindow {
    private var panel: NeverCapturedPanel?
    private let model = BadgeModel()

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    func show(on screen: NSScreen?, paused: Bool) {
        model.paused = paused
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen { panel.setFrame(RecordingBadgePlacement.frame(in: screen.frame), display: true) }
        panel.orderFrontRegardless()
    }

    func setPaused(_ paused: Bool) { model.paused = paused }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NeverCapturedPanel {
        let panel = NeverCapturedPanel(contentRect: CGRect(origin: .zero, size: RecordingBadgePlacement.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                       defer: false)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: BadgeView(model: model))
        panel.setAccessibilityIdentifier("recordingBadge")
        return panel
    }

    @MainActor @Observable
    final class BadgeModel { var paused = false }

    struct BadgeView: View {
        let model: BadgeModel
        private let access = HQAccessibility()

        var body: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.paused ? Color.secondary : Color.red)
                    .frame(width: 8, height: 8)
                Text(RecordingBadgePlacement.label(paused: model.paused))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("recordingBadgeLabel")
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hqGlass(in: Capsule(), clear: true)
            .padding(3)
            .animation(HQMotion.smooth(access.reduceMotion), value: model.paused)
        }
    }
}

/// The teleprompter window: movable and resizable on any display, never captured.
@MainActor
final class TeleprompterWindow: NSObject, NSWindowDelegate {
    let model: TeleprompterModel
    private var panel: NeverCapturedPanel?

    init(model: TeleprompterModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        model.isOpen = true
    }

    func close() {
        panel?.orderOut(nil)
        model.isOpen = false
        model.scroll.pause()
    }

    func windowWillClose(_ notification: Notification) {
        model.isOpen = false
        model.scroll.pause()
    }

    /// A capturable copy of the panel for screenshot staging. The real panel is never captured.
    static func makeStagedPanel(model: TeleprompterModel, editing: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 520, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel,
                                        .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Teleprompter"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: TeleprompterView(model: model, editing: editing))
        panel.center()
        return panel
    }

    private func makePanel() -> NeverCapturedPanel {
        let panel = NeverCapturedPanel(contentRect: CGRect(x: 0, y: 0, width: 520, height: 360),
                                       styleMask: [.titled, .closable, .resizable, .utilityWindow,
                                                   .nonactivatingPanel, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        panel.title = "Teleprompter"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = CGSize(width: 260, height: 180)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TeleprompterView(model: model))
        panel.setAccessibilityIdentifier("teleprompterWindow")
        panel.center()
        return panel
    }
}

/// The teleprompter script and scroll state shared by the window and the session.
@MainActor @Observable
final class TeleprompterModel {
    var script = TeleprompterScript(text: "")
    var scroll = TeleprompterScroll()
    var isOpen = false
    /// Height of the laid-out text minus the visible height, set by the view.
    var scrollLimit = 0.0
}

struct TeleprompterView: View {
    @Bindable var model: TeleprompterModel
    @CaptureState private var editing: Bool
    @CaptureState private var lastTick: Date?
    @Namespace private var glass
    @Environment(\.colorScheme) private var colorScheme
    private let access = HQAccessibility()

    init(model: TeleprompterModel, editing: Bool = true) {
        self.model = model
        _editing = State(initialValue: editing)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if editing {
                    TextEditor(text: $model.script.text)
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .contentMargins(.horizontal, 12, for: .scrollContent)
                        .contentMargins(.bottom, 64, for: .scrollContent)
                        .accessibilityIdentifier("teleprompterEditor")
                        .transition(.opacity)
                } else {
                    reader.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls.padding(10)
        }
        .background {
            // Editing sits on the window's glass; reading stays black so the script reads clearly.
            if editing {
                HQWindowGlass()
            } else {
                Color.black.clipShape(.rect(cornerRadius: HQRadius.window, style: .continuous))
                    .ignoresSafeArea()
            }
        }
        .animation(HQMotion.smooth(access.reduceMotion), value: editing)
        .animation(HQMotion.snappy(access.reduceMotion), value: model.scroll.isPlaying)
    }

    private var reader: some View {
        GeometryReader { outer in
            TimelineView(.animation(paused: !model.scroll.isPlaying)) { context in
                Text(model.script.text)
                    .font(.system(size: model.script.fontSize, weight: .regular))
                    .frame(width: outer.size.width - 32, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { inner in
                        Color.clear.onAppear { model.scrollLimit = inner.size.height - outer.size.height / 2 }
                            .onChange(of: inner.size.height) { _, height in
                                model.scrollLimit = height - outer.size.height / 2
                            }
                    })
                    .offset(y: -model.scroll.position)
                    .padding(.horizontal, 16)
                    .onChange(of: context.date) { _, now in tick(now) }
            }
            .frame(width: outer.size.width, height: outer.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .accessibilityIdentifier("teleprompterText")
    }

    private func tick(_ now: Date) {
        defer { lastTick = model.scroll.isPlaying ? now : nil }
        guard let lastTick else { return }
        model.scroll.advance(by: now.timeIntervalSince(lastTick), speed: model.script.scrollSpeed,
                             limit: model.scrollLimit)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    editing.toggle()
                    model.scroll.pause()
                } label: {
                    Image(systemName: editing ? "checkmark" : "pencil")
                        .contentTransition(.symbolEffect(.replace))
                }
                .hqGlassButton(circle: true)
                .accessibilityLabel(editing ? "Done editing" : "Edit")
                .help(editing ? "Done editing" : "Edit")
                .accessibilityIdentifier("teleprompterEdit")
                .glassEffectID("edit", in: glass)
                Button {
                    editing = false
                    lastTick = nil
                    model.scroll.togglePlay()
                } label: {
                    Image(systemName: model.scroll.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .hqGlassButton(prominent: true, circle: true)
                .disabled(model.script.isEmpty)
                .accessibilityLabel(model.scroll.isPlaying ? "Pause" : "Play")
                .help(model.scroll.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("teleprompterPlay")
                .glassEffectID("play", in: glass)
                Button { model.scroll.rewind() } label: { Image(systemName: "backward.end.fill") }
                    .hqGlassButton(circle: true)
                    .accessibilityLabel("Back to top")
                    .help("Back to top")
                    .accessibilityIdentifier("teleprompterRewind")
                    .glassEffectID("rewind", in: glass)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size")
                        .accessibilityLabel("Size")
                    Slider(value: $model.script.fontSize, in: TeleprompterScript.fontSizes)
                        .frame(width: 80)
                        .accessibilityIdentifier("teleprompterSize")
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .accessibilityLabel("Speed")
                    Slider(value: $model.script.scrollSpeed, in: TeleprompterScript.scrollSpeeds)
                        .frame(width: 80)
                        .accessibilityIdentifier("teleprompterSpeed")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .controlSize(.small)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .hqGlass(in: Capsule())
                .glassEffectID("sliders", in: glass)
            }
            .symbolRenderingMode(.hierarchical)
        }
        // The reader is always white on black, so its controls stay in the dark appearance.
        .environment(\.colorScheme, editing ? colorScheme : .dark)
    }
}
