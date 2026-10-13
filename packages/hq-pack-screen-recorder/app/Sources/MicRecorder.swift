// MicRecorder — records one chosen microphone to its own AAC file and reports
// the peak level so an all-silent recording is never treated as a success.

import AVFoundation
import Foundation

final class MicRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let device: AVCaptureDevice
    let url: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var error: String?
    private(set) var startHostTime: Double?

    init(device: AVCaptureDevice, url: URL) throws {
        self.device = device
        self.url = url
        super.init()
        try? FileManager.default.removeItem(at: url)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "probe", code: 10, userInfo: [NSLocalizedDescriptionKey: "cannot configure microphone"])
        }
        session.addInput(input)
        session.addOutput(output)
        output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
    }

    func start() {
        session.startRunning()
        startHostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
    }

    func stop() async -> [String: Any] {
        output.stopRecording()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if finished { return true }
                continuation = c
                return false
            }
            if done { c.resume() }
        }
        session.stopRunning()
        let peak = MicRecorder.peakDB(url)
        return [
            "file": url.lastPathComponent,
            "microphone": device.localizedName,
            "start_host_time": startHostTime ?? NSNull(),
            "recording_error": error ?? NSNull(),
            "peak_dbfs": peak,
            "silent": peak < -60,
        ]
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            self.error = error.map { "\($0)" }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }

    /// Peak sample level in dBFS (-120 when unreadable or empty).
    static func peakDB(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000) else { return -120 }
        var peak: Float = 0
        while (try? file.read(into: buf)) != nil, buf.frameLength > 0 {
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
            }
        }
        return peak > 0 ? Double(20 * log10(peak)) : -120
    }
}
