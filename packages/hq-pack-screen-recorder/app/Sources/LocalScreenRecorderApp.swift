import AppKit
import SwiftUI

@main
struct LocalScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WorkspaceView(session: appDelegate.session)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = SessionController(arguments: CommandLine.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.begin()
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
    private var channel: ControlChannel?
    private var state: SessionState = .awaitingStart
    private var pollTask: Task<Void, Never>?

    init(arguments: [String]) {
        do {
            context = try HQLaunchContext.parse(arguments)
            channel = context.map { ControlChannel(directory: $0.controlDirectory) }
        } catch {
            context = nil
            problem = "invalid-launch-arguments"
        }
    }

    func begin() {
        guard let context, channel != nil else { return }
        if let reason = DestinationCheck.problem(with: context.destination) {
            problem = reason
            publish(.failed, reason: reason)
        } else {
            publish(.awaitingStart)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let channel = self.channel else { return }
                if channel.stopRequested {
                    // No capture exists yet, so a stop request closes the helper.
                    try? channel.clearStopRequest()
                    NSApplication.shared.terminate(nil)
                    return
                }
            }
        }
    }

    func close() {
        pollTask?.cancel()
        guard state != .closed else { return }
        publish(.closed, reason: problem)
    }

    private func publish(_ newState: SessionState, reason: String? = nil) {
        guard let context, let channel else { return }
        state = newState
        let status = SessionStatus(state: newState, company: context.company,
                                   destination: context.destination.path,
                                   pid: ProcessInfo.processInfo.processIdentifier,
                                   updatedAt: SessionStatus.now(), reason: reason)
        do {
            try channel.write(status)
        } catch {
            NSLog("HQ recorder: failed to write status: \(error)")
        }
    }
}

struct WorkspaceView: View {
    let session: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Local Screen Recorder")
                .font(.system(size: 32, weight: .regular, design: .serif))
                .accessibilityIdentifier("workspaceTitle")
            Text("Record a process. Keep the original layers.")
                .font(.system(size: 17))
            Divider()
            companySection
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("CAPTURE").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Screen, webcam, and narration")
                    Text("Capture is being built. This development build does not record yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("captureStatus")
                    Button("Start recording") {}.disabled(true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    Text("LOCAL AI").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(LocalAIAvailability.message)
                        .accessibilityIdentifier("aiAvailability")
                    Text("Audio, video, and drafts are processed on this Mac. No cloud model receives them.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            Divider()
            Text("Development build")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(32)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var companySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVES TO").font(.system(size: 12)).foregroundStyle(.secondary)
            if let context = session.context {
                Text(context.company)
                    .accessibilityIdentifier("companyName")
                Text(context.destination.path)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("destinationPath")
                if session.problem != nil {
                    Text("This company folder can't be written to. Check that it exists and that you have access, then run /record-process again.")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("destinationProblem")
                }
            } else {
                Text("Open the recorder with /record-process from an HQ company session. Recordings save to that company's vault.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("missingCompany")
            }
        }
    }
}
