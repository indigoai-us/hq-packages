// Recording controls shown while capturing: the duration readout, the global pause shortcut and
// the live composition preview with its movable camera bubble.

import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI

enum RecordingDuration {
    /// Recorded time as m:ss, or h:mm:ss from one hour. Bad input shows 0:00.
    static func text(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Where the camera bubble sits over the screen preview. `x` and `y` are the bubble's top-left
/// corner as fractions of the screen size, measured from the top-left; `width` is a fraction of
/// the screen width. The bubble keeps the camera's 16:9 shape.
enum WebcamBubble {
    static let aspect = 16.0 / 9.0

    /// Smallest bubble the editor lets the camera shrink to, as a fraction of the screen width.
    static let minimumWidth = 0.08

    /// Where the bubble sits on a screen of `size`. Placement is stored as fractions of the screen,
    /// so the same placement scales with the output. On an output whose aspect differs from the one
    /// it was placed on, the bubble keeps its 16:9 shape and is pulled back wholly inside the screen.
    static func frame(_ placement: RecordingProject.WebcamPlacement, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(max(0, placement.width) * size.width, size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: min(max(0, placement.x * size.width), size.width - width),
                      y: min(max(0, placement.y * size.height), size.height - height),
                      width: width, height: height)
    }

    /// The placement after dragging by `translation` points over a preview of `size`. The bubble
    /// stays wholly inside the screen.
    static func moved(_ placement: RecordingProject.WebcamPlacement, by translation: CGSize,
                      in size: CGSize) -> RecordingProject.WebcamPlacement {
        guard size.width > 0, size.height > 0, translation.width.isFinite, translation.height.isFinite
        else { return placement }
        let bubble = frame(placement, in: size)
        let maxX = max(0, 1 - bubble.width / size.width)
        let maxY = max(0, 1 - bubble.height / size.height)
        var next = placement
        next.x = min(max(0, placement.x + translation.width / size.width), maxX)
        next.y = min(max(0, placement.y + translation.height / size.height), maxY)
        return next
    }

    /// The placement after dragging the bubble's lower-right corner by `translation` points over a
    /// preview of `size`. The top-left corner stays put, the shape stays 16:9, and the bubble stays
    /// between `minimumWidth` and the edges of the screen.
    static func resized(_ placement: RecordingProject.WebcamPlacement, by translation: CGSize,
                        in size: CGSize) -> RecordingProject.WebcamPlacement {
        guard size.width > 0, size.height > 0, translation.width.isFinite, translation.height.isFinite
        else { return placement }
        let bubble = frame(placement, in: size)
        // Whichever direction the corner moved further sets the new size.
        let across = translation.width, down = translation.height * aspect
        let change = abs(across) >= abs(down) ? across : down
        let largest = min(size.width - bubble.minX, (size.height - bubble.minY) * aspect)
        let smallest = min(minimumWidth * size.width, largest)
        let width = min(max(smallest, bubble.width + change), largest)
        var next = placement
        next.x = bubble.minX / size.width
        next.y = bubble.minY / size.height
        next.width = width / size.width
        return next
    }
}

/// Option-Command-P pauses and resumes from any app while recording. Registered only while a
/// recording is running.
@MainActor
final class PauseHotKey {
    static let keyCode = UInt32(kVK_ANSI_P)
    static let modifiers = UInt32(cmdKey | optionKey)
    static let label = "Option-Command-P"

    /// The hint under the controls. When the system refuses the shortcut, it works only while
    /// the recorder is in front.
    static func hint(global: Bool) -> String {
        global ? "\(label) pauses and resumes from any app."
            : "\(label) pauses and resumes while this window is in front."
    }

    private static var action: (@MainActor () -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { hotKey != nil }

    /// Returns false, after logging, when the system refuses the shortcut.
    @discardableResult
    func register(_ action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in PauseHotKey.fire() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else {
            NSLog("HQ recorder: pause shortcut handler not installed: \(installed)")
            handler = nil
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x4851_5243), id: 1)
        let registered = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            NSLog("HQ recorder: pause shortcut not registered: \(registered)")
            hotKey = nil
            unregister()
            return false
        }
        Self.action = action
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        Self.action = nil
    }

    private static func fire() { action?() }
}

/// The live composition: the latest screen still with the camera bubble on top. The two come
/// from their own streams; the bubble can be dragged and its placement saves with the recording.
struct CompositionPreview: View {
    let screen: ScreenPreviewTap
    let camera: AVCaptureSession?
    let placement: RecordingProject.WebcamPlacement
    let place: (RecordingProject.WebcamPlacement) -> Void
    @State private var dragStart: RecordingProject.WebcamPlacement?
    @State private var dragging: RecordingProject.WebcamPlacement?

    var body: some View {
        GeometryReader { proxy in
            let shown = dragging ?? placement
            let bubble = WebcamBubble.frame(shown, in: proxy.size)
            ZStack(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: screen.interval)) { _ in
                    if let still = screen.latest {
                        Image(decorative: still, scale: 1)
                            .resizable()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        Color.black
                    }
                }
                .accessibilityIdentifier("screenPreview")
                if let camera {
                    CameraPreview(session: camera)
                        .frame(width: bubble.width, height: bubble.height)
                        .background(.black)
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                        .offset(x: bubble.minX, y: bubble.minY)
                        .gesture(DragGesture()
                            .onChanged { value in
                                let start = dragStart ?? placement
                                dragStart = start
                                dragging = WebcamBubble.moved(start, by: value.translation, in: proxy.size)
                            }
                            .onEnded { value in
                                let start = dragStart ?? placement
                                place(WebcamBubble.moved(start, by: value.translation, in: proxy.size))
                                dragStart = nil
                                dragging = nil
                            })
                        .accessibilityIdentifier("webcamBubble")
                }
            }
        }
        .background(Color.black)
        .clipped()
        .accessibilityIdentifier("compositionPreview")
    }
}
