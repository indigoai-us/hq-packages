// SourcePicker — pre-start source selection, moved from Probes/Shared.
//
// Shows one native dialog with pop-ups for screen (each display or a single
// window), camera (None or any connected camera) and microphone (None or any
// connected microphone). Returns nil when the user cancels.

import AVFoundation
import AppKit
import ScreenCaptureKit

struct SourceChoice {
    enum Screen {
        case display(SCDisplay)
        case window(SCWindow)
    }
    var screen: Screen?
    var camera: AVCaptureDevice?
    var microphone: AVCaptureDevice?

    var summary: [String: Any] {
        var s: [String: Any] = [:]
        switch screen {
        case .display(let d): s["screen"] = "display \(d.displayID) \(d.width)x\(d.height)"
        case .window(let w): s["screen"] = "window \(w.owningApplication?.applicationName ?? "?"): \(w.title ?? "")"
        case nil: s["screen"] = "none"
        }
        s["camera"] = camera?.localizedName ?? "none"
        s["microphone"] = microphone?.localizedName ?? "none"
        return s
    }
}

enum SourcePicker {
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// - Parameters:
    ///   - content: shareable content for the screen pop-up; nil hides the screen row.
    ///   - wantsCamera / wantsMicrophone: show those rows.
    @MainActor
    static func run(title: String, content: SCShareableContent?, wantsCamera: Bool, wantsMicrophone: Bool) -> SourceChoice? {
        var rows: [(String, NSPopUpButton)] = []

        var screenOptions: [SourceChoice.Screen] = []
        if let content {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let mainID = CGMainDisplayID()
            for (i, d) in content.displays.enumerated() {
                let label = "Display \(i + 1)\(d.displayID == mainID ? " (main)" : "") — \(d.width)×\(d.height)"
                popup.addItem(withTitle: label)
                screenOptions.append(.display(d))
            }
            let windows = content.windows.filter {
                $0.windowLayer == 0 && $0.isOnScreen && !($0.title ?? "").isEmpty && $0.frame.width > 120
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            if !windows.isEmpty { popup.menu?.addItem(.separator()) }
            for w in windows {
                popup.addItem(withTitle: "Window — \(w.owningApplication?.applicationName ?? "?"): \(w.title ?? "")")
                screenOptions.append(.window(w))
            }
            rows.append(("Screen", popup))
        }

        let cams = wantsCamera ? cameras() : []
        if wantsCamera {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "None")
            cams.forEach { popup.addItem(withTitle: $0.localizedName) }
            if let def = AVCaptureDevice.default(for: .video), let i = cams.firstIndex(of: def) { popup.selectItem(at: i + 1) }
            rows.append(("Camera", popup))
        }

        let mics = wantsMicrophone ? microphones() : []
        if wantsMicrophone {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "None")
            mics.forEach { popup.addItem(withTitle: $0.localizedName) }
            if let def = AVCaptureDevice.default(for: .audio), let i = mics.firstIndex(of: def) { popup.selectItem(at: i + 1) }
            rows.append(("Microphone", popup))
        }

        let width: CGFloat = 460, rowH: CGFloat = 32
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowH))
        for (i, (name, popup)) in rows.enumerated() {
            let y = CGFloat(rows.count - 1 - i) * rowH
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 0, y: y + 6, width: 90, height: 20)
            popup.frame = NSRect(x: 95, y: y + 2, width: width - 95, height: 26)
            view.addSubview(label)
            view.addSubview(popup)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose what to record. Camera and microphone are optional."
        alert.accessoryView = view
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var choice = SourceChoice()
        var it = rows.makeIterator()
        if content != nil, let (_, p) = it.next(), p.indexOfSelectedItem >= 0 {
            // Separator items shift indices; map by title position among real items.
            let titles = p.itemArray.filter { !$0.isSeparatorItem }.map(\.title)
            if let t = p.titleOfSelectedItem, let idx = titles.firstIndex(of: t) { choice.screen = screenOptions[idx] }
        }
        if wantsCamera, let (_, p) = it.next(), p.indexOfSelectedItem > 0 { choice.camera = cams[p.indexOfSelectedItem - 1] }
        if wantsMicrophone, let (_, p) = it.next(), p.indexOfSelectedItem > 0 { choice.microphone = mics[p.indexOfSelectedItem - 1] }
        return choice
    }
}
