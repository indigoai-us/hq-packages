import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Reads connected sources and privacy state from the system. Nothing here prompts.
enum CaptureDevices {
    @MainActor
    static func permissions() -> CapturePermissions {
        CapturePermissions(screen: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
                           camera: state(AVCaptureDevice.authorizationStatus(for: .video)),
                           microphone: state(AVCaptureDevice.authorizationStatus(for: .audio)))
    }

    static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Displays come from NSScreen, which needs no permission. Windows need screen access,
    /// so they are listed only when it is granted.
    @MainActor
    static func available(screenAccess: Bool) async -> AvailableSources {
        let mainID = CGMainDisplayID()
        let ids = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.sorted { a, b in a == mainID && b != mainID }
        let displays = ids.enumerated().map { index, id in
            ScreenSource(kind: .display, id: id, bundleID: nil,
                         title: "Display \(index + 1)\(id == mainID ? " (main)" : "") — \(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id))")
        }
        return AvailableSources(
            displays: displays,
            windows: screenAccess ? await windows() : [],
            cameras: SourcePicker.cameras().map { DeviceSource(uniqueID: $0.uniqueID, name: $0.localizedName) },
            microphones: SourcePicker.microphones().map { DeviceSource(uniqueID: $0.uniqueID, name: $0.localizedName) })
    }

    /// Normal app windows other than the recorder's own, using the probe's filter.
    nonisolated static func windows() async -> [ScreenSource] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return [] }
        let own = Bundle.main.bundleIdentifier
        return content.windows.filter {
            $0.windowLayer == 0 && $0.isOnScreen && !($0.title ?? "").isEmpty && $0.frame.width > 120
                && $0.owningApplication?.bundleIdentifier != own
        }.map {
            ScreenSource(kind: .window, id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier,
                         title: "\($0.owningApplication?.applicationName ?? "Window"): \($0.title ?? "")")
        }
    }

    static func settingsURL(_ row: CaptureBlocker.Row) -> URL? {
        let pane = switch row {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        default: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// Live preview of the picked camera and microphone, before recording. Runs only for
/// devices whose permission is already granted, and writes nothing to disk.
final class DevicePreview: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.indigo.local-screen-recorder.preview")
    private let audioOutput = AVCaptureAudioDataOutput()

    func show(cameraID: String?, microphoneID: String?) {
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            for id in [cameraID, microphoneID].compactMap({ $0 }) {
                if let device = AVCaptureDevice(uniqueID: id),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
            }
            if session.outputs.isEmpty, session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(audioOutput)
            }
            session.commitConfiguration()
            if session.inputs.isEmpty {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    /// Average microphone level in dBFS, or nil when no microphone is previewing.
    var microphoneLevel: Float? {
        audioOutput.connections.first?.audioChannels.first?.averagePowerLevel
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    /// During a recording the preview switches to the recording's camera session.
    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer as? AVCaptureVideoPreviewLayer, layer.session !== session {
            layer.session = session
        }
    }
}
