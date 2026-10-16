import Foundation

/// macOS privacy state for one capture permission.
enum PermissionState: String, Sendable {
    case granted
    case notDetermined = "not-determined"
    case denied
}

/// A screen source the user can pick: one whole display or one window.
struct ScreenSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case display, window }
    var kind: Kind
    /// CGDirectDisplayID for a display, CGWindowID for a window.
    var id: UInt32
    /// Owning app of a window. With the title, finds the same window after a relaunch.
    var bundleID: String?
    var title: String

    var tag: String { "\(kind.rawValue):\(id)" }
}

/// A camera or microphone, addressed by its stable AVCaptureDevice unique ID.
struct DeviceSource: Codable, Hashable, Sendable {
    var uniqueID: String
    var name: String
}

/// The sources the user picked for one company. A nil camera or microphone means None.
struct SourceSelection: Codable, Equatable, Sendable {
    var screen: ScreenSource?
    var camera: DeviceSource?
    var microphone: DeviceSource?
}

/// What is connected right now. Windows are listed only when screen access is granted.
struct AvailableSources: Equatable, Sendable {
    var displays: [ScreenSource] = []
    var windows: [ScreenSource] = []
    var cameras: [DeviceSource] = []
    var microphones: [DeviceSource] = []

    func contains(_ screen: ScreenSource) -> Bool {
        (screen.kind == .display ? displays : windows).contains { $0.id == screen.id }
    }

    /// The current entry for a saved screen source. Window IDs change between launches,
    /// so a window is matched by ID first, then by owning app and title.
    func current(_ screen: ScreenSource) -> ScreenSource? {
        switch screen.kind {
        case .display: displays.first { $0.id == screen.id }
        case .window:
            windows.first { $0.id == screen.id }
                ?? windows.first { $0.bundleID == screen.bundleID && $0.title == screen.title }
        }
    }
}

struct CapturePermissions: Equatable, Sendable {
    var screen: PermissionState
    var camera: PermissionState
    var microphone: PermissionState
}

/// One reason recording cannot start, with the repair the user can take.
enum CaptureBlocker: Equatable, Sendable {
    enum Row: Sendable { case destination, screen, camera, microphone }
    enum Repair: Equatable, Sendable {
        case checkDestination
        case requestScreenAccess
        case requestAccess(Row)
        case openSettings(Row)
        /// The picker on the same row is the repair.
        case chooseAgain
    }

    case destination(String)
    case noScreen
    case screenPermission
    case screenGone(String)
    case cameraPermission(PermissionState)
    case cameraGone(String)
    case microphonePermission(PermissionState)
    case microphoneGone(String)

    var row: Row {
        switch self {
        case .destination: .destination
        case .noScreen, .screenPermission, .screenGone: .screen
        case .cameraPermission, .cameraGone: .camera
        case .microphonePermission, .microphoneGone: .microphone
        }
    }

    /// Short code written to status.json for the HQ session.
    var reason: String {
        switch self {
        case .destination(let reason): reason
        case .noScreen: "screen-not-selected"
        case .screenPermission: "screen-permission-needed"
        case .screenGone: "screen-source-unavailable"
        case .cameraPermission(let state): state == .denied ? "camera-permission-denied" : "camera-permission-needed"
        case .cameraGone: "camera-disconnected"
        case .microphonePermission(let state):
            state == .denied ? "microphone-permission-denied" : "microphone-permission-needed"
        case .microphoneGone: "microphone-disconnected"
        }
    }

    var message: String {
        switch self {
        case .destination:
            "Recording is off until the company folder can be saved to."
        case .noScreen:
            "Choose a display or a window to record."
        case .screenPermission:
            "Screen Recording permission lets the recorder capture the display or window you pick. Nothing is captured until you press Start. After you turn it on in System Settings, quit and run /record-process again."
        case .screenGone(let name):
            "\(name) is no longer available. Choose another display or window."
        case .cameraPermission(.denied):
            "Camera access is off for HQ Capture. Turn it on in System Settings > Privacy & Security > Camera, or choose None."
        case .cameraPermission:
            "Camera access lets the recorder preview and record the camera you picked as its own track. macOS will ask once."
        case .cameraGone(let name):
            "\(name) is disconnected. Reconnect it, or choose another camera or None."
        case .microphonePermission(.denied):
            "Microphone access is off for HQ Capture. Turn it on in System Settings > Privacy & Security > Microphone, or choose None."
        case .microphonePermission:
            "Microphone access lets the recorder check your level and record narration as its own track. macOS will ask once."
        case .microphoneGone(let name):
            "\(name) is disconnected. Reconnect it, or choose another microphone or None."
        }
    }

    var repair: Repair {
        switch self {
        case .destination: .checkDestination
        case .noScreen, .screenGone, .cameraGone, .microphoneGone: .chooseAgain
        case .screenPermission: .requestScreenAccess
        case .cameraPermission(let state): state == .denied ? .openSettings(.camera) : .requestAccess(.camera)
        case .microphonePermission(let state):
            state == .denied ? .openSettings(.microphone) : .requestAccess(.microphone)
        }
    }
}

enum CaptureReadiness {
    /// Everything that stops recording from starting, in the order the user should fix it.
    /// An empty result means every picked source is connected and permitted.
    static func blockers(selection: SourceSelection, available: AvailableSources,
                         permissions: CapturePermissions, destinationProblem: String?) -> [CaptureBlocker] {
        var result: [CaptureBlocker] = []
        if let destinationProblem { result.append(.destination(destinationProblem)) }

        if let screen = selection.screen {
            if permissions.screen != .granted {
                result.append(.screenPermission)
            } else if !available.contains(screen) {
                result.append(.screenGone(screen.title))
            }
        } else {
            result.append(.noScreen)
        }

        if let camera = selection.camera {
            if !available.cameras.contains(where: { $0.uniqueID == camera.uniqueID }) {
                result.append(.cameraGone(camera.name))
            } else if permissions.camera != .granted {
                result.append(.cameraPermission(permissions.camera))
            }
        }
        if let microphone = selection.microphone {
            if !available.microphones.contains(where: { $0.uniqueID == microphone.uniqueID }) {
                result.append(.microphoneGone(microphone.name))
            } else if permissions.microphone != .granted {
                result.append(.microphonePermission(permissions.microphone))
            }
        }
        return result
    }

    /// The selection to show at launch. Without a saved choice: the first display, no camera,
    /// no microphone. A saved device that is gone is kept so the user sees it is missing;
    /// it is never silently swapped for None or another device.
    static func restore(_ saved: SourceSelection?, available: AvailableSources) -> SourceSelection {
        guard var selection = saved else {
            return SourceSelection(screen: available.displays.first, camera: nil, microphone: nil)
        }
        if let screen = selection.screen, let current = available.current(screen) {
            selection.screen = current
        }
        return selection
    }
}

/// Remembers the source selection separately for each company.
struct SelectionStore: @unchecked Sendable {
    let defaults: UserDefaults

    static func key(company: String) -> String { "sourceSelection.v1.\(company)" }

    func load(company: String) -> SourceSelection? {
        guard let data = defaults.data(forKey: Self.key(company: company)) else { return nil }
        return try? JSONDecoder().decode(SourceSelection.self, from: data)
    }

    func save(_ selection: SourceSelection, company: String) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.key(company: company))
    }
}
