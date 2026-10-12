// The floating control bar shown over the screen while recording: elapsed time, Pause/Resume,
// Stop and the teleprompter toggle. It is never captured, joins every Space and sits over
// full-screen apps. Its buttons call the same session methods as the main window and
// Option-Command-P, through RecordingControlTarget.

import AppKit
import SwiftUI

/// What the bar's buttons drive. SessionController conforms with the methods the main window uses.
@MainActor
protocol RecordingControlTarget: AnyObject {
    func toggleRecording()
    func togglePause()
    func toggleTeleprompter()
}

extension SessionController: RecordingControlTarget {}

enum ControlBarAction: Equatable {
    case pauseResume
    case stop
    case teleprompter
}

/// The bar's state, derived from the session's recording flags.
@MainActor @Observable
final class ControlBarModel {
    enum Phase: Equatable {
        case hidden
        case recording
        case paused
    }

    private(set) var phase: Phase = .hidden
    /// True while the bar is on screen. The view scales and fades with it, so the panel can stay
    /// ordered in until the hide animation has finished.
    var presented = false
    private var teleprompterFlag = false
    /// The session's teleprompter. When set, the bar follows it directly, so closing the
    /// teleprompter from its own window also updates the bar.
    @ObservationIgnored weak var teleprompter: TeleprompterModel?
    var teleprompterOpen: Bool { teleprompter?.isOpen ?? teleprompterFlag }
    /// Recorded seconds so far, with paused time left out.
    @ObservationIgnored var elapsed: () -> Double? = { nil }
    @ObservationIgnored weak var target: RecordingControlTarget?

    static func phase(isCapturing: Bool, isPaused: Bool, isStopping: Bool) -> Phase {
        guard isCapturing, !isStopping else { return .hidden }
        return isPaused ? .paused : .recording
    }

    func update(isCapturing: Bool, isPaused: Bool, isStopping: Bool, teleprompterOpen: Bool) {
        phase = Self.phase(isCapturing: isCapturing, isPaused: isPaused, isStopping: isStopping)
        teleprompterFlag = teleprompterOpen
    }

    /// Runs a button's action on the session. Does nothing while the bar is hidden, so a late
    /// click can never start a new recording.
    func perform(_ action: ControlBarAction) {
        guard phase != .hidden, let target else { return }
        switch action {
        case .pauseResume: target.togglePause()
        case .stop: target.toggleRecording()
        case .teleprompter: target.toggleTeleprompter()
        }
    }

    var pauseTitle: String { phase == .paused ? "Resume" : "Pause" }
    var teleprompterTitle: String { teleprompterOpen ? "Hide teleprompter" : "Teleprompter" }
    var statusTitle: String { phase == .paused ? "Paused" : "Recording" }
}

/// Where the bar sits: where it was last dragged on that display, or top center by default.
enum ControlBarPlacement {
    static let size = CGSize(width: 420, height: 48)
    static let topMargin: CGFloat = 12

    /// The bar frame on a screen. A saved origin is used only while the whole bar still fits on
    /// that screen, so a changed resolution never leaves it off screen.
    static func frame(saved: CGPoint?, screenFrame: CGRect, visibleFrame: CGRect,
                      size: CGSize = size) -> CGRect {
        if let saved, saved.x.isFinite, saved.y.isFinite {
            let candidate = CGRect(origin: saved, size: size)
            if screenFrame.contains(candidate) { return candidate }
        }
        return CGRect(x: visibleFrame.midX - size.width / 2,
                      y: visibleFrame.maxY - size.height - topMargin,
                      width: size.width, height: size.height)
    }
}

/// Remembers the bar's position per display.
struct ControlBarPositionStore: @unchecked Sendable {
    let defaults: UserDefaults

    static func key(display: UInt32) -> String { "controlBarOrigin.v1.\(display)" }

    func load(display: UInt32) -> CGPoint? {
        guard let values = defaults.array(forKey: Self.key(display: display)) as? [Double],
              values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    func save(_ origin: CGPoint, display: UInt32) {
        defaults.set([Double(origin.x), Double(origin.y)], forKey: Self.key(display: display))
    }
}

/// The floating panel that hosts the bar.
@MainActor
final class RecordingControlBarWindow: NSObject, NSWindowDelegate {
    let model: ControlBarModel
    private let positions: ControlBarPositionStore
    private var panel: NeverCapturedPanel?
    /// Set while the bar is being placed, so programmatic moves are not saved as drags.
    private var placing = false

    init(model: ControlBarModel = ControlBarModel(),
         positions: ControlBarPositionStore = ControlBarPositionStore(defaults: .standard)) {
        self.model = model
        self.positions = positions
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    func show(on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen {
            let saved = RecordingBadgePlacement.displayID(of: screen).flatMap { positions.load(display: $0) }
            placing = true
            panel.setFrame(ControlBarPlacement.frame(saved: saved, screenFrame: screen.frame,
                                                     visibleFrame: screen.visibleFrame), display: true)
            placing = false
        }
        let wasShown = model.presented && panel.isVisible
        if !wasShown { model.presented = false }
        panel.orderFrontRegardless()
        guard !wasShown else { return }
        // Let the panel draw the collapsed state once, then spring it in.
        DispatchQueue.main.async { [model] in model.presented = true }
    }

    func hide() {
        guard let panel else { return }
        model.presented = false
        // The panel stays ordered in until the view has faded out, unless it was shown again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak panel] in
            guard let self, !self.model.presented else { return }
            panel?.orderOut(nil)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, let panel, let screen = panel.screen,
              let display = RecordingBadgePlacement.displayID(of: screen) else { return }
        positions.save(panel.frame.origin, display: display)
    }

    private func makePanel() -> NeverCapturedPanel {
        let panel = NeverCapturedPanel(contentRect: CGRect(origin: .zero, size: ControlBarPlacement.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                       defer: false)
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ControlBarView(model: model))
        panel.setAccessibilityIdentifier("recordingControlBar")
        return panel
    }
}

struct ControlBarView: View {
    let model: ControlBarModel
    @Namespace private var glass
    private let access = HQAccessibility()

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                status
                if model.phase != .hidden {
                    button(model.pauseTitle, symbol: model.phase == .paused ? "play.fill" : "pause.fill",
                           action: .pauseResume, id: "controlBarPause", prominent: model.phase == .paused)
                    button("Stop", symbol: "stop.fill", action: .stop, id: "controlBarStop",
                           prominent: model.phase == .recording, showsTitle: true)
                    button(model.teleprompterTitle, symbol: model.teleprompterOpen ? "text.alignleft" : "text.justify.left",
                           action: .teleprompter, id: "controlBarTeleprompter", prominent: false)
                }
            }
            .padding(5)
            // The whole bar is one capsule of clear glass; the status and buttons sit on it.
            .hqGlass(in: Capsule(), clear: true)
            .glassEffectID("bar", in: glass)
        }
        .tint(model.phase == .paused ? .orange : .red)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(model.presented || access.reduceMotion ? 1 : 0.86)
        .opacity(model.presented ? 1 : 0)
        .animation(HQMotion.smooth(access.reduceMotion), value: model.phase)
        .animation(HQMotion.appear(access.reduceMotion), value: model.presented)
        .animation(HQMotion.snappy(access.reduceMotion), value: model.teleprompterOpen)
        .gesture(WindowDragGesture())
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.phase == .recording ? Color.red : Color.clear)
                .overlay(Circle().strokeBorder(model.phase == .hidden ? Color.secondary
                                               : model.phase == .paused ? Color.orange : Color.red,
                                               lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .accessibilityLabel(model.statusTitle)
                .accessibilityIdentifier("controlBarStatus")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(RecordingDuration.text(model.elapsed() ?? 0))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.phase == .paused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("controlBarElapsed")
            }
            .frame(width: 46, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .glassEffectID("status", in: glass)
    }

    private func button(_ title: String, symbol: String, action: ControlBarAction, id: String,
                        prominent: Bool, showsTitle: Bool = false) -> some View {
        Button { model.perform(action) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                if showsTitle { Text(title) }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(minWidth: 16, minHeight: 20)
        }
        .hqGlassButton(prominent: prominent, circle: !showsTitle)
        .controlSize(.regular)
        .accessibilityLabel(title)
        .help(title)
        .accessibilityIdentifier(id)
        .glassEffectID(id, in: glass)
        .glassEffectTransition(access.reduceMotion ? .identity : .matchedGeometry)
        .transition(.opacity)
    }
}
