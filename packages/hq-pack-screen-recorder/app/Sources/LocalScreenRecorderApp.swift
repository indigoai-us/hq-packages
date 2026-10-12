import AVFoundation
import AppKit
import SwiftUI

@main
struct LocalScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `--measure-sync <package>` measures a saved recording and exits without opening a window.
        if let status = SyncMeasurementCLI.runIfRequested(CommandLine.arguments) { exit(status) }
        // `--extract-screen-evidence <package>` samples screen text from a saved recording and exits.
        if let status = ScreenEvidenceCLI.runIfRequested(CommandLine.arguments) { exit(status) }
        // `--draft-sop <package>` drafts SOP steps from a saved recording's narration and exits.
        if let status = DraftSOPCLI.runIfRequested(CommandLine.arguments) { exit(status) }
        // `--export-sop <package>` exports the newest approved SOP review and exits.
        if let status = ExportSOPCLI.runIfRequested(CommandLine.arguments) { exit(status) }
        // `--sync-package`, `--check-access`, `--retrieve-package`, `--prepare-skill` and `--register-skill`
        // go through the HQ CLI and the company vault, then exit.
        if let status = VaultCLI.runIfRequested(CommandLine.arguments) { exit(status) }
        // `--describe`, `--transcribe`, `--edit`, `--export-video`, `--frame`, `--review-sop`,
        // `--approve-sop` and `--list-frames` let the HQ session agent work with a saved recording
        // and its SOP review, then exit. See AgentCommands.swift and AgentSOPCommands.swift.
        if let status = AgentCommandsCLI.runIfRequested(CommandLine.arguments) { exit(status) }
    }

    var body: some Scene {
        WindowGroup("HQ Capture") {
            WorkspaceView(session: appDelegate.session)
                .frame(minWidth: 760, minHeight: 520)
                // The window is glass edge to edge: a clear window background under full-size
                // content, with the glass drawn by the view.
                .background { HQWindowGlass() }
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = SessionController(arguments: CommandLine.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.begin()
        if let surface = ScreenshotStage.surface(CommandLine.arguments) {
            ScreenshotStage.present(surface, session: session)
        } else if session.context != nil {
            // HQ launched the recorder, or it relaunched after Quit & Reopen: put it on top.
            session.focus.bringForwardWhenReady(.launch)
        }
    }

    /// Quitting while recording finalizes the recording first, so the saved files stay playable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.isCapturing else { return .terminateNow }
        Task {
            await session.stopRecording(reason: "app-quit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Owns the HQ control channel for one helper launch.
@MainActor
@Observable
final class SessionController {
    let context: HQLaunchContext?
    private(set) var problem: String?
    /// Plain-language save and sync state of the current recording, if any.
    private(set) var saveStatus: String?
    private var channel: ControlChannel?
    private var state: SessionState = .awaitingStart
    private var pollTask: Task<Void, Never>?
    /// Bound to the launch company and destination; capture attaches its writers here.
    private(set) var recording: RecordingSession?
    private var recordingPath: String?
    private var syncState: String?

    /// Screen, camera and microphone capture are built.
    static let captureAvailable = true
    /// True from Start until the recording has been finalized.
    private(set) var isCapturing = false
    private(set) var isStopping = false
    /// Shown inline once when Presenter Overlay starts drawing into the screen recording.
    private(set) var effectWarning: String?
    /// Why the last recording stopped, when it did not stop because the user asked.
    private(set) var stopNote: String?
    /// Camera trouble during a recording. The screen keeps recording either way.
    private(set) var cameraNote: String?
    private var capture: ScreenCaptureRun?
    /// The camera recording for the current recording, if a camera was chosen and allowed.
    private(set) var cameraCapture: CameraCaptureRun?
    /// Microphone trouble or silence during a recording. The screen keeps recording either way.
    private(set) var microphoneNote: String?
    /// The narration recording for the current recording, if a microphone was chosen and allowed.
    private(set) var microphoneCapture: MicrophoneCaptureRun?
    private var microphoneTrack: MicrophoneTrack?
    private var captureOrigin: Double?
    private var stopTask: Task<Void, Never>?
    /// True once the last recording ended and its saved or failed status was published.
    private var finished = false
    /// The shared timeline of the current recording. Pausing it pauses every track together.
    private(set) var clock: RecordingClock?
    private(set) var isPaused = false
    /// Host time the last recording stopped, so the final duration stays fixed after saving.
    private var stoppedHost: Double?
    /// Latest screen still for the live preview.
    let screenPreview = ScreenPreviewTap()
    /// Where the camera bubble sits in the live preview, saved with the recording.
    private(set) var webcamPlacement = RecordingProject.WebcamPlacement()
    /// The saved package of the last recording, for "Show recording".
    private(set) var savedPackage: URL?
    /// What to paste back into the HQ session after a save, so editing can continue there even
    /// if that session was interrupted. Also written to status.json.
    private(set) var resumePrompt: String?
    /// A saved file that doesn't match the length the recording gave it. Shown on the existing
    /// note for that layer and written to status.json.
    private var mediaIssue: String?
    let teleprompter = TeleprompterModel()
    @ObservationIgnored private var teleprompterPanel: TeleprompterWindow?
    @ObservationIgnored private let badge = RecordingBadgeWindow()
    @ObservationIgnored private let pauseHotKey = PauseHotKey()
    /// The floating bar shown over the screen while recording.
    @ObservationIgnored private let controlBar = RecordingControlBarWindow()
    /// The control bar's state, for the bar itself and for tests.
    var controlBarModel: ControlBarModel { controlBar.model }
    /// Brings the main window forward at launch and when a recording stops.
    @ObservationIgnored let focus: WindowFocusCoordinator
    /// Counts how often the window was brought forward. The window plays its arrival on each change.
    private(set) var windowArrivals = 0
    /// True while Option-Command-P is registered system-wide. When it isn't, the Pause button
    /// carries the shortcut instead.
    private(set) var pauseShortcutGlobal = false
    private(set) var selection = SourceSelection()
    private(set) var available = AvailableSources()
    private(set) var permissions = CapturePermissions(screen: .notDetermined, camera: .notDetermined,
                                                      microphone: .notDetermined)
    /// Everything stopping a recording from starting. Shown beside the row it belongs to.
    private(set) var blockers: [CaptureBlocker] = []
    let preview = DevicePreview()
    private let store: SelectionStore
    private var restored = false
    private var observers: [NSObjectProtocol] = []

    var canStart: Bool {
        context != nil && recording != nil && blockers.isEmpty && Self.captureAvailable && !isCapturing
    }

    init(arguments: [String], store: SelectionStore = SelectionStore(defaults: .standard),
         bindings: LaunchBindingStore = LaunchBindingStore(defaults: .standard), now: Date = Date(),
         focusHost: WindowFocusHost = AppKitFocusHost()) {
        self.store = store
        focus = WindowFocusCoordinator(host: focusHost)
        // A plain relaunch shortly after an HQ launch (Quit & Reopen) keeps the same binding.
        let arguments = bindings.resolve(arguments, now: now)
        do {
            context = try HQLaunchContext.parse(arguments)
            channel = context.map { ControlChannel(directory: $0.controlDirectory) }
        } catch {
            context = nil
            problem = "invalid-launch-arguments"
        }
        controlBar.model.target = self
        controlBar.model.teleprompter = teleprompter
        controlBar.model.elapsed = { [weak self] in self?.durationSeconds }
        focus.onBringForward = { [weak self] _ in self?.windowArrivals += 1 }
    }

    func begin() {
        guard context != nil, channel != nil else { return }
        recheckDestination()
        watchSources()
        Task { await refreshSources() }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let channel = self.channel else { return }
                tick += 1
                if tick % 4 == 0, self.isCapturing, !self.isStopping, self.state == .recording {
                    self.publish(.recording)
                }
                if channel.stopRequested {
                    await self.handleStopRequest()
                    NSApplication.shared.terminate(nil)
                    return
                }
                if self.isCapturing, let recording = self.recording, !recording.store.hasRoomToRecord() {
                    await self.stopRecording(reason: "low-disk-space")
                } else if let recording = self.recording, await recording.isRecording,
                   (try? await recording.stopIfLowOnDisk()) == true {
                    await self.report(recording, reason: "low-disk-space")
                }
            }
        }
    }

    /// Checks the destination again. This is the repair for an unwritable or full vault folder:
    /// a passing check binds the recording session, a failing one reports failed and binds none.
    func recheckDestination() {
        guard let context, channel != nil, state == .awaitingStart || state == .failed else { return }
        if let reason = Self.destinationProblem(context) {
            problem = reason
            recording = nil
        } else if recording == nil {
            do {
                recording = try RecordingSession(company: context.company, destination: context.destination)
                problem = nil
            } catch {
                problem = "destination-outside-company-recordings"
            }
        }
        evaluate(force: true)
    }

    /// Re-reads permissions and connected sources, then re-evaluates what blocks recording.
    func refreshSources() async {
        guard let context else { return }
        permissions = CaptureDevices.permissions()
        available = await CaptureDevices.available(screenAccess: permissions.screen == .granted)
        if !restored {
            selection = CaptureReadiness.restore(store.load(company: context.company), available: available)
            restored = true
        } else if let screen = selection.screen, let current = available.current(screen) {
            selection.screen = current
        }
        evaluate()
    }

    func chooseScreen(_ screen: ScreenSource?) { update { $0.screen = screen } }
    func chooseCamera(_ camera: DeviceSource?) { update { $0.camera = camera } }
    func chooseMicrophone(_ microphone: DeviceSource?) { update { $0.microphone = microphone } }

    /// Runs the repair offered for a blocker. Permission prompts happen only here, after the
    /// row has explained why the permission is needed.
    func repair(_ blocker: CaptureBlocker) async {
        switch blocker.repair {
        case .checkDestination:
            recheckDestination()
        case .requestScreenAccess:
            if !CGRequestScreenCaptureAccess(), let url = CaptureDevices.settingsURL(.screen) {
                NSWorkspace.shared.open(url)
            }
        case .requestAccess(let row):
            _ = await AVCaptureDevice.requestAccess(for: row == .camera ? .video : .audio)
        case .openSettings(let row):
            if let url = CaptureDevices.settingsURL(row) { NSWorkspace.shared.open(url) }
        case .chooseAgain:
            break
        }
        await refreshSources()
    }

    private func update(_ change: (inout SourceSelection) -> Void) {
        guard let context else { return }
        change(&selection)
        store.save(selection, company: context.company)
        evaluate()
    }

    private var publishedReason: String?

    /// Recomputes blockers, points the preview at permitted devices and tells HQ why
    /// recording cannot start yet.
    private func evaluate(force: Bool = false) {
        blockers = CaptureReadiness.blockers(selection: selection, available: available,
                                             permissions: permissions, destinationProblem: problem)
        let camera = selection.camera.flatMap { c in
            permissions.camera == .granted && available.cameras.contains(c) ? c.uniqueID : nil
        }
        let microphone = selection.microphone.flatMap { m in
            permissions.microphone == .granted && available.microphones.contains(m) ? m.uniqueID : nil
        }
        // While recording, the camera and microphone belong to the recording sessions, which also
        // feed the preview and the level meter.
        preview.show(cameraID: isCapturing ? nil : camera,
                     microphoneID: microphoneCapture == nil ? microphone : nil)

        guard state == .awaitingStart || state == .failed else { return }
        let reason = problem ?? blockers.first?.reason
        guard force || reason != publishedReason else { return }
        publishedReason = reason
        publish(problem == nil ? .awaitingStart : .failed, reason: reason)
    }

    /// Device plug and unplug, display changes and returning from System Settings all refresh.
    private func watchSources() {
        let names: [Notification.Name] = [AVCaptureDevice.wasConnectedNotification,
                                          AVCaptureDevice.wasDisconnectedNotification,
                                          NSApplication.didChangeScreenParametersNotification,
                                          NSApplication.didBecomeActiveNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshSources() }
            }
        }
    }

    /// The destination must be the bound company's recordings folder, writable and with room to record.
    static func destinationProblem(_ context: HQLaunchContext) -> String? {
        guard let root = try? RecordingsRoot.resolve(company: context.company, destination: context.destination)
        else { return "destination-outside-company-recordings" }
        if let reason = DestinationCheck.problem(with: root.url) { return reason }
        return RecordingPackageStore(root: root).hasRoomToRecord() ? nil : "low-disk-space"
    }

    /// HQ asked the helper to stop: finalizes any recording and publishes saved or failed.
    /// The caller then quits the app, and close() keeps that outcome in status.json.
    func handleStopRequest() async {
        if let channel { try? channel.clearStopRequest() }
        await finishRecording(reason: "stop-requested")
    }

    /// Finalizes an active recording before the helper closes. Saved files stay in the package on failure.
    private func finishRecording(reason: String) async {
        if isCapturing { return await stopRecording(reason: reason) }
        guard let recording, await recording.isRecording else { return }
        publish(.finalizing)
        do {
            _ = try await recording.stop(reason: reason)
            await report(recording, reason: nil)
        } catch {
            NSLog("HQ recorder: finalize failed: \(error)")
            finish(.failed, reason: "finalize-failed")
        }
    }

    func toggleRecording() {
        Task { isCapturing ? await stopRecording(reason: "stopped-by-user") : await startRecording() }
    }

    /// Creates the package, hides the recorder's own windows from capture and starts the screen track.
    /// The package is created only after every blocker is clear, so a failed start leaves no empty success.
    func startRecording() async {
        guard canStart, let context, let screen = selection.screen, var recording else { return }
        isCapturing = true
        isPaused = false
        finished = false
        stoppedHost = nil
        savedPackage = nil
        resumePrompt = nil
        mediaIssue = nil
        webcamPlacement = RecordingProject.WebcamPlacement()
        screenPreview.clear()
        effectWarning = nil
        stopNote = nil
        cameraNote = nil
        microphoneNote = nil
        saveStatus = nil
        if await recording.manifest != nil {
            do {
                recording = try RecordingSession(company: context.company, destination: context.destination)
                self.recording = recording
            } catch {
                NSLog("HQ recorder: could not bind a new recording: \(error)")
                isCapturing = false
                problem = "destination-outside-company-recordings"
                evaluate(force: true)
                return
            }
        }
        let origin = ScreenCapture.hostNow()
        captureOrigin = origin
        let clock = RecordingClock(origin: origin)
        self.clock = clock
        do {
            _ = try await recording.start(title: "Screen recording")
            recordingPath = await recording.manifest?.vaultPath
            syncState = nil
            publish(.recording)
            let track = ScreenTrack(session: recording, origin: origin, clock: clock) { [weak self] issue in
                Task { @MainActor in self?.handle(issue) }
            }
            let run = ScreenCaptureRun(track: track, preview: screenPreview) { [weak self] reason in
                Task { @MainActor in await self?.stopRecording(reason: reason) }
            }
            capture = run
            CaptureHiding.hide(NSApplication.shared.windows)
            try await run.start(source: screen)
        } catch {
            NSLog("HQ recorder: screen capture did not start: \(error)")
            await stopRecording(reason: "capture-start-failed")
            return
        }
        let windowFrame = screen.kind == .window ? RecordingBadgePlacement.windowFrame(screen.id) : nil
        let recordedScreen = RecordingBadgePlacement.screen(for: screen, windowFrame: windowFrame)
        badge.show(on: recordedScreen, paused: false)
        syncControlBar()
        controlBar.show(on: recordedScreen)
        pauseShortcutGlobal = pauseHotKey.register { [weak self] in self?.togglePause() }
        await startCamera(recording: recording, origin: origin, clock: clock)
        await startMicrophone(recording: recording, origin: origin, clock: clock)
    }

    /// Recorded seconds so far, with paused time left out. Nil before the first recording.
    var durationSeconds: Double? {
        guard let clock else { return nil }
        return clock.offset(stoppedHost ?? ScreenCapture.hostNow())
    }

    /// Pauses every track together. Pausing again, or pausing while stopping, does nothing.
    func pauseRecording() {
        guard isCapturing, !isStopping, let clock, clock.pause(at: ScreenCapture.hostNow()) else { return }
        isPaused = true
        badge.setPaused(true)
        syncControlBar()
        publish(.recording)
    }

    /// Resumes every track on the same timeline. Resuming when not paused does nothing.
    func resumeRecording() {
        guard isCapturing, !isStopping, let clock, clock.resume(at: ScreenCapture.hostNow()) else { return }
        isPaused = false
        badge.setPaused(false)
        syncControlBar()
        publish(.recording)
    }

    func togglePause() { isPaused ? resumeRecording() : pauseRecording() }

    /// Moves the camera bubble in the live preview and saves where it sits with the recording.
    func placeWebcam(_ placement: RecordingProject.WebcamPlacement) {
        webcamPlacement = placement
        guard let recording else { return }
        Task {
            do {
                try await recording.placeWebcam(placement)
            } catch {
                NSLog("HQ recorder: could not save the camera bubble placement: \(error)")
            }
        }
    }

    func toggleTeleprompter() {
        let window = teleprompterPanel ?? TeleprompterWindow(model: teleprompter)
        teleprompterPanel = window
        window.isVisible ? window.close() : window.show()
        syncControlBar()
    }

    /// Brings the floating bar in line with the recording and teleprompter state.
    private func syncControlBar() {
        controlBar.model.update(isCapturing: isCapturing, isPaused: isPaused, isStopping: isStopping,
                                teleprompterOpen: teleprompter.isOpen)
    }

    /// Shows the saved recording package in Finder.
    func revealSavedRecording() {
        guard let savedPackage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedPackage])
    }

    /// Records the chosen camera as its own track. A camera that won't start leaves a note and
    /// the screen keeps recording.
    private func startCamera(recording: RecordingSession, origin: Double, clock: RecordingClock) async {
        guard let camera = selection.camera, permissions.camera == .granted,
              available.cameras.contains(camera) else { return }
        let track = CameraTrack(session: recording, origin: origin, clock: clock) { [weak self] issue in
            Task { @MainActor in self?.handle(issue) }
        }
        let run = CameraCaptureRun(track: track, deviceID: camera.uniqueID)
        preview.show(cameraID: nil, microphoneID: selection.microphone?.uniqueID)
        cameraCapture = run
        do {
            try await run.start()
        } catch {
            NSLog("HQ recorder: camera capture did not start: \(error)")
            cameraCapture = nil
            await run.stop()
            cameraNote = Self.cameraNoteText(.stopped("camera-start-failed"))
        }
    }

    /// Records the chosen microphone as its own narration track. A microphone that won't start
    /// leaves a note and the screen keeps recording.
    private func startMicrophone(recording: RecordingSession, origin: Double, clock: RecordingClock) async {
        guard let microphone = selection.microphone, permissions.microphone == .granted,
              available.microphones.contains(microphone) else { return }
        let track = MicrophoneTrack(session: recording, origin: origin, clock: clock) { [weak self] issue in
            Task { @MainActor in self?.handle(issue) }
        }
        let run = MicrophoneCaptureRun(track: track, deviceID: microphone.uniqueID)
        // The recording takes the microphone over from the preview; its level drives the meter.
        preview.show(cameraID: nil, microphoneID: nil)
        microphoneTrack = track
        microphoneCapture = run
        do {
            try await run.start()
        } catch {
            NSLog("HQ recorder: microphone capture did not start: \(error)")
            microphoneCapture = nil
            microphoneTrack = nil
            await run.stop()
            microphoneNote = Self.microphoneNoteText(.stopped("microphone-start-failed"))
        }
    }

    /// Stops capture, writes every queued frame, then finalizes the package. Concurrent callers
    /// (Stop, stop.request, Quit, a system stop) all wait for the same finalization.
    func stopRecording(reason: String) async {
        if let stopTask { return await stopTask.value }
        guard isCapturing else { return }
        isStopping = true
        syncControlBar()
        let task = Task { await performStop(reason: reason) }
        stopTask = task
        await task.value
        stopTask = nil
        isStopping = false
        isCapturing = false
        syncControlBar()
    }

    private func performStop(reason: String) async {
        let stopHost = ScreenCapture.hostNow()
        stoppedHost = stopHost
        publish(.finalizing)
        pauseHotKey.unregister()
        pauseShortcutGlobal = false
        badge.hide()
        controlBar.hide()
        // Every stop (the bar, the window, stop.request, a system stop) brings the window back
        // while it saves, so the saved state and the resume prompt are in view.
        if WindowFocusCoordinator.surfacesWindow(afterStop: reason) { focus.bringForward(.stop) }
        if let capture { await capture.stop() }
        capture = nil
        if let cameraCapture { await cameraCapture.stop() }
        cameraCapture = nil
        if let microphoneCapture { await microphoneCapture.stop() }
        microphoneCapture = nil
        // The silence result goes into the manifest before the recording is finalized.
        if let microphoneTrack { await microphoneTrack.finish() }
        microphoneTrack = nil
        evaluate()
        CaptureHiding.restore(NSApplication.shared.windows)
        stopNote = Self.stopNote(reason)
        guard let recording else { return finish(.failed, reason: reason) }
        if let clock {
            // A recording stopped while paused ends at the pause; the open pause is closed so
            // the manifest records how long it lasted.
            clock.resume(at: stopHost)
            isPaused = false
        }
        if await recording.isRecording {
            do {
                try await recording.recordPauses(clock?.pausedRanges() ?? [])
            } catch {
                NSLog("HQ recorder: could not record pauses: \(error)")
            }
            if !teleprompter.script.isEmpty {
                do {
                    try await recording.saveTeleprompter(teleprompter.script)
                } catch {
                    NSLog("HQ recorder: could not save the teleprompter script: \(error)")
                }
            }
            do {
                _ = try await recording.stop(reason: reason, originHostTime: captureOrigin)
            } catch {
                NSLog("HQ recorder: finalize failed: \(error)")
                return finish(.failed, reason: "finalize-failed")
            }
        }
        if reason == "capture-start-failed" {
            // Nothing usable was recorded; the package stays on disk with its stop reason.
            await refreshSources()
            return finish(.failed, reason: reason)
        }
        await report(recording, reason: Self.userStops.contains(reason) ? nil : reason)
    }

    private static let userStops: Set<String> = ["stopped-by-user", "stop-requested", "app-quit"]

    private func handle(_ issue: ScreenTrackIssue) {
        switch issue {
        case .videoEffectStarted:
            effectWarning = Self.effectWarningText
        case .failed(let reason):
            Task { await stopRecording(reason: reason) }
        }
    }

    private func handle(_ issue: CameraTrackIssue) {
        cameraNote = Self.cameraNoteText(issue)
    }

    private func handle(_ issue: MicrophoneTrackIssue) {
        microphoneNote = Self.microphoneNoteText(issue)
    }

    /// Plain text for a microphone problem. Never includes the underlying error.
    static func microphoneNoteText(_ issue: MicrophoneTrackIssue) -> String? {
        switch issue {
        case .silent:
            "The microphone isn't picking up any sound. Check that the right microphone is chosen and, on a laptop, that the lid is open. The screen is still recording."
        case .soundBack:
            "The microphone is picking up sound again. The silent part is marked in the recording."
        case .lost(.disconnected):
            "The microphone was disconnected. The screen is still recording, and the narration so far is saved. Reconnect it to keep recording narration."
        case .lost:
            "The microphone stopped sending sound. The screen is still recording, and the narration so far is saved."
        case .resumed:
            "The microphone is back and recording again. The gap is marked in the recording."
        case .stopped:
            "The narration can't be recorded for the rest of this recording. The screen is still recording, and the narration so far is saved."
        }
    }

    /// Plain text for a camera problem. Never includes the underlying error.
    static func cameraNoteText(_ issue: CameraTrackIssue) -> String? {
        switch issue {
        case .lost(.disconnected):
            "The camera was disconnected. The screen is still recording, and the camera video so far is saved. Reconnect it to keep recording the camera."
        case .lost(.interrupted), .lost(.suspended):
            "Another app or the system paused the camera. The screen is still recording, and the camera video so far is saved. The camera picks up again when it's free."
        case .lost(.runtimeError), .lost(.writerFailed):
            "The camera stopped sending video. The screen is still recording, and the camera video so far is saved."
        case .resumed:
            "The camera is back and recording again. The gap is marked in the recording."
        case .stopped:
            "The camera can't be recorded for the rest of this recording. The screen is still recording, and the camera video so far is saved."
        }
    }

    static let effectWarningText = "Presenter Overlay is on. It is baked into the screen recording, and the camera layer is blank while it is on. Recording continues, and those parts are marked so the camera bubble can't be edited there."

    static func stopNote(_ reason: String) -> String? {
        switch reason {
        case "capture-terminated":
            "Recording stopped because the screen or window being recorded went away. Everything up to that point is saved."
        case "screen-writer-failed", "screen-segment-failed":
            "Recording stopped because the screen video couldn't be written. Everything up to that point is saved."
        case "low-disk-space":
            "Recording stopped because this Mac is low on disk space. Everything up to that point is saved."
        case "capture-start-failed":
            "Recording couldn't start. Check that screen recording is allowed for this app in System Settings, then press Start again."
        default:
            nil
        }
    }

    private func report(_ recording: RecordingSession, reason: String?) async {
        guard let manifest = await recording.manifest else { return }
        recordingPath = manifest.vaultPath
        syncState = manifest.sync.state.rawValue
        saveStatus = Self.saveStatus(manifest)
        savedPackage = manifest.state == .saved ? await recording.package : nil
        resumePrompt = savedPackage.map { Self.resumePrompt(company: recording.company, package: $0) }
        if let issue = manifest.mediaIssues?.first {
            mediaIssue = issue.message
            switch issue.kind {
            case .microphone: microphoneNote = issue.message
            case .camera: cameraNote = issue.message
            case .screen: stopNote = issue.message
            }
        }
        finish(manifest.state == .saved ? .saved : .failed, reason: reason)
    }

    /// The line shown after a save, above the resume prompt.
    static let savedNote = "Saved. Go back to your HQ session to edit and turn this into a guide."

    /// A prompt the user can paste into any HQ session to pick up the saved recording.
    static func resumePrompt(company: String, package: URL) -> String {
        "Continue my HQ Capture recording for \(company) at \(package.standardizedFileURL.path): show me what was "
            + "recorded, then trim, place the camera, export the video and draft the step-by-step guide."
    }

    static func saveStatus(_ manifest: RecordingManifest) -> String {
        let saved = syncStatus(manifest)
        guard manifest.microphoneSilent == true else { return saved }
        return saved + " The narration track is silent: the microphone picked up no sound."
    }

    private static func syncStatus(_ manifest: RecordingManifest) -> String {
        switch manifest.sync.state {
        case .localOnly: "Saved on this Mac in the company vault folder. Not synced yet."
        case .pending: "Saved on this Mac. Waiting for HQ sync to upload it."
        case .synced: "Saved and synced to the company vault."
        case .failedRetry: "Saved on this Mac. Sync didn't finish; HQ sync will retry."
        }
    }

    func close() {
        pollTask?.cancel()
        preview.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard state != .closed else { return }
        // A recording that ended as saved or failed keeps that status, with its package path and
        // resume prompt, so HQ still sees the outcome after the app quits.
        if finished, state == .saved || state == .failed { return }
        publish(.closed, reason: problem)
    }

    /// Publishes how a recording ended. close() leaves this status in place.
    private func finish(_ outcome: SessionState, reason: String?) {
        finished = true
        publish(outcome, reason: reason)
    }

    /// Screenshot staging only: shows the saved state with a sample prompt. Nothing is recorded
    /// or written to status.json.
    func stageSavedForScreenshot() {
        guard let context else { return }
        let package = context.destination.appendingPathComponent("sample.hqrec", isDirectory: true)
        savedPackage = package
        resumePrompt = Self.resumePrompt(company: context.company, package: package)
        saveStatus = "Saved on this Mac in the company vault folder. Not synced yet."
    }

    private func publish(_ newState: SessionState, reason: String? = nil) {
        guard let context, let channel else { return }
        state = newState
        let status = SessionStatus(state: newState, company: context.company,
                                   destination: context.destination.path,
                                   pid: ProcessInfo.processInfo.processIdentifier,
                                   updatedAt: SessionStatus.now(), reason: reason,
                                   recording: recordingPath, sync: syncState,
                                   paused: newState == .recording ? isPaused : nil,
                                   durationSeconds: durationSeconds,
                                   resumePrompt: resumePrompt, issue: mediaIssue)
        do {
            try channel.write(status)
        } catch {
            NSLog("HQ recorder: failed to write status: \(error)")
        }
    }
}

/// The window's scale and opacity while it settles in after being brought forward.
struct WindowArrival {
    var scale: CGFloat = 1
    var opacity: Double = 1
}

struct WorkspaceView: View {
    let session: SessionController
    @Namespace private var glass
    @Namespace private var stage
    @State private var copied = false
    private let access = HQAccessibility()

    var body: some View {
        ScrollView {
            content
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.isCapturing)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.isPaused)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.isStopping)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.savedPackage != nil)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.blockers.count)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.selection.camera?.uniqueID)
        .animation(HQMotion.smooth(access.reduceMotion), value: session.selection.microphone?.uniqueID)
        // When the window is brought forward it settles in on the glass spring. With Reduce
        // Motion it only fades.
        .keyframeAnimator(initialValue: WindowArrival(), trigger: session.windowArrivals) { view, arrival in
            view.scaleEffect(arrival.scale).opacity(arrival.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(access.reduceMotion ? 1 : 0.97)
                SpringKeyframe(1, duration: 0.42, spring: HQMotion.appearSpring)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0.7)
                LinearKeyframe(1, duration: access.reduceMotion ? 0.18 : 0.3)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            companySection
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    if session.context != nil {
                        VStack(alignment: .leading, spacing: 16) { sourceRows }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hqGlass()
                    }
                    Text(captureStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("captureStatus")
                    notes
                    if session.isCapturing || session.durationSeconds != nil { durationRow }
                    actions
                    if session.isCapturing {
                        Text(PauseHotKey.hint(global: session.pauseShortcutGlobal))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    if session.savedPackage != nil, !session.isCapturing {
                        savedSection
                            .transition(access.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                previewStage
            }
            Spacer(minLength: 0)
            Text("Development build")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 36)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
    }

    /// The HQ mark, small and quiet, with the window's name.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HQWordmark()
                .fill(Color.primary.opacity(0.55))
                .frame(width: HQWordmark.width(forHeight: 16), height: 16)
                .accessibilityHidden(true)
            Text("Capture")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .accessibilityLabel("HQ Capture")
                .accessibilityIdentifier("workspaceTitle")
            Text("Record a process. Keep the original layers.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    /// The one primary action for the current state, with Pause and the teleprompter beside it.
    private var actions: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button { session.toggleRecording() } label: {
                    Label(session.isCapturing ? "Stop recording" : "Start recording",
                          systemImage: session.isCapturing ? "stop.fill" : "record.circle")
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 8)
                }
                .font(.system(size: 13, weight: .medium))
                .controlSize(.large)
                .hqGlassButton(prominent: true)
                .tint(session.isCapturing ? .red : .accentColor)
                .disabled(session.isCapturing ? session.isStopping : !session.canStart)
                .accessibilityIdentifier("recordButton")
                .glassEffectID("record", in: glass)
                if session.isCapturing {
                    Button { session.togglePause() } label: {
                        Label(session.isPaused ? "Resume" : "Pause",
                              systemImage: session.isPaused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .controlSize(.large)
                    .hqGlassButton()
                    .disabled(session.isStopping)
                    .keyboardShortcut(session.pauseShortcutGlobal
                                      ? nil : KeyboardShortcut("p", modifiers: [.command, .option]))
                    .accessibilityIdentifier("pauseButton")
                    .glassEffectID("pause", in: glass)
                    .glassEffectTransition(access.reduceMotion ? .identity : .matchedGeometry)
                }
                if session.context != nil {
                    Button { session.toggleTeleprompter() } label: {
                        Label(session.teleprompter.isOpen ? "Hide teleprompter" : "Teleprompter",
                              systemImage: "text.justify.left")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .controlSize(.large)
                    .hqGlassButton()
                    .accessibilityIdentifier("teleprompterButton")
                    .glassEffectID("teleprompter", in: glass)
                }
            }
        }
    }

    /// The camera preview before recording grows into the composition preview while recording.
    @ViewBuilder private var previewStage: some View {
        if session.isCapturing {
            VStack(alignment: .leading, spacing: 8) {
                CompositionPreview(screen: session.screenPreview, camera: session.cameraCapture?.session,
                                   placement: session.webcamPlacement, place: session.placeWebcam)
                    .frame(width: 320, height: 180)
                    .clipShape(.rect(cornerRadius: HQRadius.card, style: .continuous))
                    .matchedGeometryEffect(id: "preview", in: stage)
                if session.cameraCapture != nil {
                    Text("Drag the camera bubble to where it should sit. The camera is still saved as its own track.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 320)
            .transition(.opacity)
        } else if session.context != nil, session.selection.camera != nil,
                  !session.blockers.contains(where: { $0.row == .camera }) {
            CameraPreview(session: session.preview.session)
                .frame(width: 256, height: 144)
                .background(.black)
                .clipShape(.rect(cornerRadius: HQRadius.card, style: .continuous))
                .overlay(HQDispersionRim(shape: .rect(cornerRadius: HQRadius.card, style: .continuous)))
                .matchedGeometryEffect(id: "preview", in: stage)
                .accessibilityIdentifier("cameraPreview")
                .transition(.opacity)
        }
    }

    @ViewBuilder private var notes: some View {
        ForEach([("effectWarning", session.effectWarning), ("cameraNote", session.cameraNote),
                 ("microphoneNote", session.microphoneNote), ("stopNote", session.stopNote)], id: \.0) { id, note in
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(id)
            }
        }
        if let saveStatus = session.saveStatus {
            Text(saveStatus)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("saveStatus")
        }
    }

    /// After a save: where to go next, and the prompt to paste back into the HQ session.
    @ViewBuilder private var savedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SessionController.savedNote)
                .font(.system(size: 13))
                .accessibilityIdentifier("savedNote")
            if let prompt = session.resumePrompt {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.primary.opacity(0.06),
                                in: .rect(cornerRadius: HQRadius.inset, style: .continuous))
                    .accessibilityIdentifier("resumePrompt")
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.6))
                                copied = false
                            }
                        } label: {
                            Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .controlSize(.large)
                        .hqGlassButton(prominent: true)
                        .accessibilityIdentifier("copyResumePrompt")
                        Button { session.revealSavedRecording() } label: {
                            Label("Show recording", systemImage: "folder")
                        }
                        .controlSize(.large)
                        .hqGlassButton()
                        .accessibilityIdentifier("showRecording")
                    }
                    .animation(HQMotion.snappy(access.reduceMotion), value: copied)
                }
            }
        }
        .padding(20)
        .hqGlass()
    }

    /// Recorded time and state. Paused time is left out.
    private var durationRow: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isCapturing && !session.isPaused ? Color.red : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(durationLabel)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("recordingDuration")
            }
        }
    }

    private var durationLabel: String {
        let time = RecordingDuration.text(session.durationSeconds ?? 0)
        if session.isStopping { return "Saving · \(time)" }
        if session.isCapturing { return session.isPaused ? "Paused · \(time)" : "Recording · \(time)" }
        return "Recorded \(time)"
    }

    /// One quiet line: the company the recording saves to and its vault folder.
    @ViewBuilder private var companySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = session.context {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "building.2")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(context.company)
                        .font(.system(size: 13, weight: .medium))
                        .accessibilityIdentifier("companyName")
                    Text(context.destination.path)
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(context.destination.path)
                        .accessibilityIdentifier("destinationPath")
                }
                if let problem = session.problem {
                    Text(Self.problemMessage(problem))
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("destinationProblem")
                    if problem != "destination-outside-company-recordings" {
                        Button("Check again") { session.recheckDestination() }
                            .hqGlassButton()
                            .accessibilityIdentifier("recheckDestination")
                    }
                }
            } else {
                Text("Open the recorder with /record-process from an HQ company session. Recordings save to that company's vault.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("missingCompany")
            }
        }
    }

    private var captureStatus: String {
        if session.isStopping { return "Saving the recording…" }
        if session.isCapturing {
            let tracks = switch (session.cameraCapture != nil, session.microphoneCapture != nil) {
            case (true, true): "Recording the screen, camera and narration as separate tracks."
            case (true, false): "Recording the screen and camera as separate tracks."
            case (false, true): "Recording the screen and narration as separate tracks."
            case (false, false): "Recording the screen."
            }
            return tracks + " The recorder's own window and camera preview are left out."
        }
        if session.context != nil, session.blockers.isEmpty {
            return "Sources ready. The screen, camera and microphone are each recorded as their own track."
        }
        return "Choose a screen and clear the notes above to record."
    }

    /// Screen, camera and microphone pickers, each with its own permission note and repair.
    @ViewBuilder private var sourceRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceRow("display") {
                Picker("Screen", selection: Binding(
                    get: { session.selection.screen?.tag ?? "" },
                    set: { tag in session.chooseScreen(screens.first { $0.tag == tag }) })) {
                    ForEach(screens.filter { $0.kind == .display }, id: \.tag) { Text($0.title).tag($0.tag) }
                    let windows = screens.filter { $0.kind == .window }
                    if !windows.isEmpty { Divider() }
                    ForEach(windows, id: \.tag) { Text($0.title).tag($0.tag) }
                    if session.selection.screen == nil { Text("Choose a screen").tag("") }
                }
                .help("Required. One whole display or one window.")
                .accessibilityIdentifier("screenPicker")
            }
            blockerNotes(.screen)
        }
        VStack(alignment: .leading, spacing: 8) {
            sourceRow("video") {
                devicePicker("Camera", id: "cameraPicker", devices: session.available.cameras,
                             chosen: session.selection.camera, choose: session.chooseCamera)
            }
            blockerNotes(.camera)
        }
        VStack(alignment: .leading, spacing: 8) {
            sourceRow("mic") {
                devicePicker("Microphone", id: "microphonePicker", devices: session.available.microphones,
                             chosen: session.selection.microphone, choose: session.chooseMicrophone)
            }
            if session.selection.microphone != nil, !session.blockers.contains(where: { $0.row == .microphone }) {
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    // -60 dBFS and below shows empty, 0 dBFS full.
                    let level = session.microphoneCapture?.level.map(Float.init) ?? session.preview.microphoneLevel ?? -60
                    LevelMeter(fraction: Double(max(0, min(60, level + 60))) / 60, reduceMotion: access.reduceMotion)
                }
                .padding(.leading, 34)
                .accessibilityIdentifier("microphoneLevel")
                .transition(.opacity)
            }
            blockerNotes(.microphone)
        }
        if session.problem != nil { blockerNotes(.destination) }
    }

    private func sourceRow(_ symbol: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            picker()
        }
    }

    /// The picked screen stays listed after it disappears, so the picker shows what is missing.
    private var screens: [ScreenSource] {
        var list = session.available.displays + session.available.windows
        if let chosen = session.selection.screen, !list.contains(where: { $0.tag == chosen.tag }) {
            list.append(chosen)
        }
        return list
    }

    private func devicePicker(_ title: String, id: String, devices: [DeviceSource], chosen: DeviceSource?,
                              choose: @escaping (DeviceSource?) -> Void) -> some View {
        var list = devices
        if let chosen, !list.contains(chosen) { list.append(chosen) }
        return Picker(title, selection: Binding(
            get: { chosen?.uniqueID ?? "" },
            set: { uid in choose(list.first { $0.uniqueID == uid }) })) {
            Text("None").tag("")
            ForEach(list, id: \.uniqueID) { device in
                Text(devices.contains(device) ? device.name : "\(device.name) (disconnected)").tag(device.uniqueID)
            }
        }
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func blockerNotes(_ row: CaptureBlocker.Row) -> some View {
        ForEach(session.blockers.filter { $0.row == row }, id: \.reason) { blocker in
            Text(blocker.message)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("captureBlocker-\(blocker.reason)")
            if let title = Self.repairTitle(blocker.repair) {
                Button(title) { Task { await session.repair(blocker) } }
                    .controlSize(.regular)
                    .hqGlassButton()
                    .accessibilityIdentifier("repair-\(blocker.reason)")
            }
        }
    }

    static func repairTitle(_ repair: CaptureBlocker.Repair) -> String? {
        switch repair {
        case .checkDestination, .chooseAgain: nil
        case .requestScreenAccess: "Allow screen recording"
        case .requestAccess(let row): row == .camera ? "Allow camera" : "Allow microphone"
        case .openSettings(let row): row == .camera ? "Open Camera settings" : "Open Microphone settings"
        }
    }

    static func problemMessage(_ problem: String) -> String {
        switch problem {
        case "destination-outside-company-recordings":
            "Recordings can only save to this company's recordings folder in the vault. Run /record-process again from the company session."
        case "low-disk-space":
            "This Mac is low on disk space. Free some space, then run /record-process again."
        default:
            "This company folder can't be written to. Check that it exists and that you have access, then run /record-process again."
        }
    }
}

/// The microphone level as a thin bar that eases between readings.
private struct LevelMeter: View {
    let fraction: Double
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: geometry.size.width * fraction)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: fraction)
            }
        }
        .frame(width: 192, height: 4)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
