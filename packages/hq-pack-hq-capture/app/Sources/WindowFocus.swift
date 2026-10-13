// Brings the main window to the front at the two moments the user expects it: when HQ launches
// the recorder (or it relaunches after Quit & Reopen), and when a recording stops, so the saved
// state and the resume prompt are in view. Nothing else in the app takes focus while recording.

import AppKit

/// The part of a window the focus coordinator uses. NSWindow conforms; tests use a fake.
@MainActor
protocol FocusableWindow: AnyObject {
    var isMiniaturized: Bool { get }
    func deminiaturize(_ sender: Any?)
    func makeKeyAndOrderFront(_ sender: Any?)
    func orderFrontRegardless()
}

extension NSWindow: FocusableWindow {}

/// The app and its main window, as the focus coordinator sees them.
@MainActor
protocol WindowFocusHost: AnyObject {
    /// The HQ Capture window, once SwiftUI has created it.
    var mainWindow: FocusableWindow? { get }
    var isActive: Bool { get }
    func activate()
}

/// The running app. The main window is the first one that is not a panel: the badge, the bar
/// and the teleprompter are all panels.
@MainActor
final class AppKitFocusHost: WindowFocusHost {
    var mainWindow: FocusableWindow? {
        NSApplication.shared.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }

    var isActive: Bool { NSApplication.shared.isActive }

    func activate() { NSApplication.shared.activate() }
}

@MainActor
final class WindowFocusCoordinator {
    enum Reason: Equatable {
        case launch
        case stop
    }

    typealias Schedule = @MainActor (Double, @escaping @MainActor @Sendable () -> Void) -> Void

    let host: WindowFocusHost
    private let schedule: Schedule
    /// Called each time the window is brought forward, so the view can play its arrival.
    var onBringForward: ((Reason) -> Void)?

    init(host: WindowFocusHost, schedule: @escaping Schedule = WindowFocusCoordinator.later) {
        self.host = host
        self.schedule = schedule
    }

    static func later(_ delay: Double, _ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    /// Whether a stop brings the window back. Quitting closes the window anyway, so it doesn't.
    static func surfacesWindow(afterStop reason: String) -> Bool { reason != "app-quit" }

    /// Activates the app and puts the main window in front as the key window, restoring it from
    /// the Dock first if it was minimized. Returns false when there is no window yet.
    @discardableResult
    func bringForward(_ reason: Reason) -> Bool {
        guard let window = host.mainWindow else { return false }
        host.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // A launch from the background (`open -n` from a terminal) may not be allowed to take
        // activation. The window still goes in front of other apps' windows.
        if !host.isActive { window.orderFrontRegardless() }
        onBringForward?(reason)
        return true
    }

    /// At launch SwiftUI creates the window a moment after the app finishes launching, so this
    /// tries again every `interval` seconds until the window exists, up to `attempts` times.
    func bringForwardWhenReady(_ reason: Reason, attempts: Int = 20, interval: Double = 0.1) {
        guard !bringForward(reason), attempts > 1 else { return }
        schedule(interval) { [weak self] in
            self?.bringForwardWhenReady(reason, attempts: attempts - 1, interval: interval)
        }
    }
}
