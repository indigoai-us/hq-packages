// Screenshot staging for design review. `--screenshot-stage <surface>` opens one surface in a
// state that can be photographed with `screencapture -l <window>` and prints that window's number
// as `stage-window <number>`. Glass is see-through, so each staged surface also gets a busy,
// colorful backdrop window just behind it, and the launch prints `stage-rect <x>,<y>,<w>,<h>`: the
// screen region, in `screencapture -R` coordinates, that holds the surface over its backdrop. The bar, badge and teleprompter are shown in plain capturable copies
// of their panels; the real ones stay never-captured. `--reduce-motion` and
// `--reduce-transparency` force the accessibility fallbacks so they can be shot without changing
// system settings. Nothing is recorded and no status is written for the staged copies.

import AppKit
import SwiftUI

enum ScreenshotStage {
    enum Surface: String, CaseIterable {
        /// The main window as launched.
        case workspace
        /// The main window after a save, with the resume prompt.
        case saved
        /// The floating bar as it collapses when a recording stops.
        case barIdle = "bar-idle"
        case barRecording = "bar-recording"
        case barPaused = "bar-paused"
        case badge
        case badgePaused = "badge-paused"
        case teleprompter
        case teleprompterReading = "teleprompter-reading"
    }

    static func surface(_ arguments: [String]) -> Surface? {
        guard let index = arguments.firstIndex(of: "--screenshot-stage"),
              arguments.indices.contains(index + 1) else { return nil }
        return Surface(rawValue: arguments[index + 1])
    }

    /// True when the shot asks for the Reduce Motion fallback.
    static var reduceMotion: Bool { CommandLine.arguments.contains("--reduce-motion") }
    /// True when the shot asks for the Reduce Transparency fallback.
    static var reduceTransparency: Bool { CommandLine.arguments.contains("--reduce-transparency") }

    static let sampleScript = """
        Open the company vault and choose Recordings.
        Start a new capture and pick the display you want to show.
        Talk through each step as you go. The narration becomes the guide.
        """

    /// Kept alive for the life of the staged launch.
    @MainActor private static var stagedWindows: [NSWindow] = []
    @MainActor private static var stagedTeleprompter: TeleprompterModel?

    @MainActor
    static func present(_ surface: Surface, session: SessionController) {
        switch surface {
        case .workspace, .saved:
            if surface == .saved { session.stageSavedForScreenshot() }
            report(mainWindowAfter: 2.5)
        case .barIdle, .barRecording, .barPaused:
            let model = ControlBarModel()
            model.update(isCapturing: surface != .barIdle, isPaused: surface == .barPaused, isStopping: false,
                         teleprompterOpen: false)
            model.elapsed = { surface == .barIdle ? 0 : 83 }
            model.presented = true
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let frame = ControlBarPlacement.frame(saved: nil, screenFrame: screen.frame,
                                                  visibleFrame: screen.visibleFrame)
            show(stagedPanel(frame: frame, content: ControlBarView(model: model)))
        case .badge, .badgePaused:
            let model = RecordingBadgeWindow.BadgeModel()
            model.paused = surface == .badgePaused
            let screen = NSScreen.main ?? NSScreen.screens[0]
            show(stagedPanel(frame: RecordingBadgePlacement.frame(in: screen.frame),
                             content: RecordingBadgeWindow.BadgeView(model: model)))
        case .teleprompter, .teleprompterReading:
            let model = TeleprompterModel()
            model.script = TeleprompterScript(text: sampleScript)
            model.isOpen = true
            stagedTeleprompter = model
            let panel = TeleprompterWindow.makeStagedPanel(
                model: model, editing: surface == .teleprompter)
            show(panel)
        }
    }

    @MainActor
    private static func stagedPanel(frame: CGRect, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
        panel.setFrame(frame, display: true)
        return panel
    }

    @MainActor
    private static func show(_ window: NSWindow) {
        stagedWindows.append(window)
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            emit(window)
        }
    }

    /// A borderless window of colored shapes and text one level below `window`, a little larger
    /// than it, so the glass has something to blur and the rim something to disperse.
    @MainActor
    private static func backdrop(behind window: NSWindow) -> CGRect {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        // The full screen frame, not the visible one: the badge sits in the corner the Dock and
        // menu bar may cover.
        let frame = window.frame.insetBy(dx: -56, dy: -40).intersection(screen.frame)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: window.level.rawValue - 1)
        backdrop.isReleasedWhenClosed = false
        backdrop.ignoresMouseEvents = true
        backdrop.collectionBehavior.insert(.canJoinAllSpaces)
        backdrop.contentView = NSHostingView(rootView: StageBackdrop())
        backdrop.setFrame(frame, display: true)
        stagedWindows.append(backdrop)
        backdrop.order(.below, relativeTo: window.windowNumber)
        return frame
    }

    @MainActor
    private static func report(mainWindowAfter delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain })
            else {
                let seen = NSApplication.shared.windows.map { "\(type(of: $0)) visible=\($0.isVisible) main=\($0.canBecomeMain)" }
                FileHandle.standardError.write(Data("screenshot stage: no main window \(seen)\n".utf8))
                return
            }
            // A staged launch is not frontmost, so Stage Manager would show only a thumbnail.
            // Floating the window on all Spaces keeps it full size for the shot.
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.level = .floating
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            emit(window)
        }
    }

    @MainActor
    private static func emit(_ window: NSWindow) {
        let frame = backdrop(behind: window)
        window.orderFrontRegardless()
        Task { @MainActor in
            // Let the glass pick up the new backdrop before the shot.
            try? await Task.sleep(for: .seconds(0.8))
            // `screencapture -R` counts from the top left of the primary display.
            let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
            print("stage-window \(window.windowNumber)")
            print("stage-rect \(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))")
            fflush(stdout)
        }
    }
}

/// The busy, colorful backdrop behind staged surfaces. Fixed shapes, so every shot matches.
private struct StageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.2), Color(red: 0.85, green: 0.15, blue: 0.55),
                                    Color(red: 0.2, green: 0.35, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geometry in
                let w = geometry.size.width, h = geometry.size.height
                Circle().fill(Color.yellow).frame(width: h * 0.7).position(x: w * 0.18, y: h * 0.3)
                Circle().fill(Color.green).frame(width: h * 0.5).position(x: w * 0.55, y: h * 0.85)
                Circle().fill(Color.cyan).frame(width: h * 0.6).position(x: w * 0.88, y: h * 0.2)
                ForEach(0..<14, id: \.self) { index in
                    Rectangle().fill(index.isMultiple(of: 2) ? Color.white.opacity(0.85) : Color.black.opacity(0.7))
                        .frame(width: 6, height: h * 1.6)
                        .rotationEffect(.degrees(28))
                        .position(x: w * Double(index) / 13, y: h / 2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<12, id: \.self) { _ in
                        Text("Quarterly roadmap · Vault sync · Recordings · Design review · Launch checklist")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .padding(12)
            }
        }
        .ignoresSafeArea()
    }
}
