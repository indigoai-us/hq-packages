import AVFoundation
import Foundation

/// Builds playback from a saved recording's timeline. The screen, camera and narration stay
/// separate tracks, so hiding the webcam drops only the camera segments and leaves the rest as recorded.
enum PlaybackLayers {
    /// A composition and the track that carries each layer.
    struct Playback {
        let composition: AVMutableComposition
        let tracks: [RecordingProject.Track.Kind: AVMutableCompositionTrack]
    }

    /// Timeline entries that play under the current webcam placement.
    static func visibleEntries(_ timeline: RecordingTimeline,
                               webcam: RecordingProject.WebcamPlacement) -> [RecordingTimeline.Entry] {
        timeline.entries.filter { webcam.visible || $0.kind != .camera }
    }

    /// One composition with a track per visible layer (video for screen and camera, audio for
    /// narration), each segment placed at its offset from the recording start. Gaps stay empty.
    /// Source files are only read.
    static func composition(package: URL, timeline: RecordingTimeline,
                            webcam: RecordingProject.WebcamPlacement) async throws -> sending AVMutableComposition {
        try await layers(package: package, timeline: timeline, webcam: webcam).composition
    }

    /// The recording lasts as long as its screen. A camera or narration file that runs past the
    /// end of the screen is cut there, so one long file can't stretch the whole recording. A
    /// recording without a screen layer lasts as long as its longest layer.
    static func layers(package: URL, timeline: RecordingTimeline,
                       webcam: RecordingProject.WebcamPlacement) async throws -> sending Playback {
        let composition = AVMutableComposition()
        var tracks: [RecordingProject.Track.Kind: AVMutableCompositionTrack] = [:]
        var screenEnd: CMTime?
        for entry in visibleEntries(timeline, webcam: webcam) {
            // Narration is the audio of the microphone segments; screen and camera are video.
            let media: AVMediaType = entry.kind == .microphone ? .audio : .video
            let asset = AVURLAsset(url: try RecordingPackageStore.contained(entry.relativePath, in: package))
            guard let source = try await asset.loadTracks(withMediaType: media).first else { continue }
            let range = try await source.load(.timeRange)
            guard range.duration > .zero else { continue }
            let track = tracks[entry.kind]
                ?? composition.addMutableTrack(withMediaType: media, preferredTrackID: kCMPersistentTrackID_Invalid)
            guard let track else { continue }
            tracks[entry.kind] = track
            let start = CMTime(seconds: entry.startOffsetSeconds, preferredTimescale: 600)
            try track.insertTimeRange(range, of: source, at: start)
            if entry.kind == .screen { screenEnd = max(screenEnd ?? .zero, start + range.duration) }
        }
        if let screenEnd, composition.duration > screenEnd {
            composition.removeTimeRange(CMTimeRange(start: screenEnd, end: composition.duration))
        }
        return Playback(composition: composition, tracks: tracks)
    }

    /// Every layer, camera included even when it is hidden, for the editor's player. Hiding or
    /// showing the camera then only swaps the video composition, which draws the camera or leaves
    /// it out, so the picture matches an export that drops the camera.
    static func preview(package: URL, timeline: RecordingTimeline,
                        webcam: RecordingProject.WebcamPlacement) async throws -> sending Playback {
        var shown = webcam
        shown.visible = true
        return try await layers(package: package, timeline: timeline, webcam: shown)
    }

    /// The layers cut to the kept ranges, played back to back. Every gap is removed from all tracks
    /// at once, so screen, camera and narration stay in sync. `kept` nil keeps the one `trim`
    /// range. Ranges that are invalid, too short or past the end are refused, so nothing
    /// downstream can play or export an empty or wrong-length result as a success.
    static func trimmed(package: URL, timeline: RecordingTimeline, webcam: RecordingProject.WebcamPlacement,
                        trim: RecordingProject.TrimRange?,
                        kept: [RecordingProject.TrimRange]? = nil) async throws -> sending Playback {
        let playback = try await layers(package: package, timeline: timeline, webcam: webcam)
        let total = playback.composition.duration
        let ranges = try KeptRanges.resolve(trim: trim, kept: kept, duration: total.seconds)
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        // Remove from the end backwards so each earlier gap keeps its recorded position.
        if let last = ranges.last, time(last.end) < total {
            playback.composition.removeTimeRange(CMTimeRange(start: time(last.end), end: total))
        }
        for index in ranges.indices.reversed() {
            let gapStart = index == 0 ? CMTime.zero : time(ranges[index - 1].end)
            let gapEnd = time(ranges[index].start)
            if gapEnd > gapStart { playback.composition.removeTimeRange(CMTimeRange(start: gapStart, end: gapEnd)) }
        }
        return playback
    }

    /// Draws the camera over the screen at the saved placement, so one player shows both video
    /// layers. The camera fills its 16:9 bubble, cropped evenly on the long side when the camera
    /// has another shape, and never spills outside the bubble. Where the camera has no footage the
    /// screen underneath shows. Nil when there is no screen layer.
    static func videoComposition(_ playback: Playback,
                                 webcam: RecordingProject.WebcamPlacement) -> AVVideoComposition? {
        guard let screen = playback.tracks[.screen] else { return nil }
        let size = screen.naturalSize
        guard size.width > 0, size.height > 0 else { return nil }
        var instruction = AVVideoCompositionInstruction.Configuration(
            timeRange: CMTimeRange(start: .zero, duration: playback.composition.duration))
        var layers: [AVVideoCompositionLayerInstruction] = []
        let source = playback.tracks[.camera]?.naturalSize ?? .zero
        if webcam.visible, let camera = playback.tracks[.camera], source.width > 0, source.height > 0 {
            let bubble = WebcamBubble.frame(webcam, in: size)
            let crop = cameraCrop(source)
            let scale = bubble.width / crop.width
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: camera)
            layer.setCropRectangle(crop, at: .zero)
            layer.setTransform(CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: bubble.minX, y: bubble.minY)), at: .zero)
            layers.append(AVVideoCompositionLayerInstruction(configuration: layer))
        }
        layers.append(AVVideoCompositionLayerInstruction(configuration: .init(assetTrack: screen)))
        instruction.layerInstructions = layers
        var video = AVVideoComposition.Configuration()
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [AVVideoCompositionInstruction(configuration: instruction)]
        return AVVideoComposition(configuration: video)
    }

    /// The centered 16:9 part of a camera frame of `size` that fills the bubble.
    static func cameraCrop(_ size: CGSize) -> CGRect {
        let aspect = WebcamBubble.aspect
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }

    /// Writes the trimmed layers to a new file at `destination` and confirms the file plays for the
    /// kept length. An invalid range writes nothing; a file that comes out empty, unreadable or the
    /// wrong length is deleted and reported as a failure. An existing file at `destination` is
    /// refused and left alone. Returns the exported duration in seconds.
    static func exportTrimmed(package: URL, timeline: RecordingTimeline, webcam: RecordingProject.WebcamPlacement,
                              trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]? = nil,
                              to destination: URL) async throws -> Double {
        try await export(package: package, timeline: timeline, webcam: webcam, trim: trim, kept: kept, to: destination,
                         composed: false)
    }

    /// Like `exportTrimmed`, but renders one video picture: the screen with the camera drawn at its
    /// placement, exactly as the editor's player shows it, plus the narration. A hidden camera
    /// leaves only the screen. The recorded files are only read.
    static func exportComposed(package: URL, timeline: RecordingTimeline, webcam: RecordingProject.WebcamPlacement,
                               trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]? = nil,
                              to destination: URL) async throws -> Double {
        try await export(package: package, timeline: timeline, webcam: webcam, trim: trim, kept: kept, to: destination,
                         composed: true)
    }

    /// A shareable MP4 of the trimmed recording: the same composed picture as `exportComposed`,
    /// encoded as H.264 video with AAC narration. `beforeWriting` runs with the kept length once
    /// it is known and before any file is written, so a caller can refuse, for example when the
    /// disk is too full. The file is checked for duration and codecs and deleted when it fails.
    static func exportVideo(package: URL, timeline: RecordingTimeline, webcam: RecordingProject.WebcamPlacement,
                            trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]? = nil,
                            to destination: URL,
                            beforeWriting: (@Sendable (Double) throws -> Void)? = nil) async throws -> Double {
        try await export(package: package, timeline: timeline, webcam: webcam, trim: trim, kept: kept, to: destination,
                         composed: true, fileType: .mp4, beforeWriting: beforeWriting)
    }

    /// Video and audio codecs of a written file, as four-character media subtypes.
    static func codecs(of url: URL) async throws -> (video: [FourCharCode], audio: [FourCharCode]) {
        let asset = AVURLAsset(url: url)
        func subtypes(_ media: AVMediaType) async throws -> [FourCharCode] {
            var result: [FourCharCode] = []
            for track in try await asset.loadTracks(withMediaType: media) {
                for format in try await track.load(.formatDescriptions) {
                    result.append(CMFormatDescriptionGetMediaSubType(format))
                }
            }
            return result
        }
        return try await (subtypes(.video), subtypes(.audio))
    }

    private static func export(package: URL, timeline: RecordingTimeline, webcam: RecordingProject.WebcamPlacement,
                               trim: RecordingProject.TrimRange?, kept: [RecordingProject.TrimRange]? = nil,
                            to destination: URL,
                               composed: Bool, fileType: AVFileType = .mov,
                               beforeWriting: (@Sendable (Double) throws -> Void)? = nil) async throws -> Double {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let playback = try await trimmed(package: package, timeline: timeline, webcam: webcam, trim: trim,
                                          kept: kept)
        let expected = playback.composition.duration.seconds
        let video = composed ? videoComposition(playback, webcam: webcam) : nil
        if composed && video == nil { throw TrimEditor.TrimError.emptyRecording }
        try beforeWriting?(expected)
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: playback.composition,
                                                 presetName: composed ? AVAssetExportPresetHighestQuality
                                                                      : AVAssetExportPresetPassthrough)
        else { throw TrimEditor.TrimError.exportMismatch }
        session.videoComposition = video
        let hasNarration = playback.tracks[.microphone] != nil
        // Written to a hidden file beside the destination, so a failure only ever removes its own file.
        let temp = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp.\(destination.pathExtension)")
        do {
            try await session.export(to: temp, as: fileType)
            try Task.checkCancellation()
            let exported = try await AVURLAsset(url: temp).load(.duration).seconds
            guard exported.isFinite, exported >= TrimEditor.minimumLength,
                  abs(exported - expected) <= TrimEditor.tolerance * 2
            else { throw TrimEditor.TrimError.exportMismatch }
            if fileType == .mp4 {
                let found = try await codecs(of: temp)
                guard found.video == [kCMVideoCodecType_H264],
                      found.audio.allSatisfy({ $0 == kAudioFormatMPEG4AAC }),
                      !hasNarration || !found.audio.isEmpty
                else { throw TrimEditor.TrimError.exportMismatch }
            }
            // A hard link fails when the destination exists, so a file saved meanwhile is kept.
            guard link(temp.path, destination.path) == 0 else {
                throw errno == EEXIST
                    ? CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
                    : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            removeTemp(temp)
            return exported
        } catch {
            NSLog("HQ recorder: trimmed export failed: \(error)")
            removeTemp(temp)
            throw error
        }
    }

    private static func removeTemp(_ temp: URL) {
        guard FileManager.default.fileExists(atPath: temp.path) else { return }
        do { try FileManager.default.removeItem(at: temp) } catch {
            NSLog("HQ recorder: could not remove unfinished export: \(error)")
        }
    }
}
