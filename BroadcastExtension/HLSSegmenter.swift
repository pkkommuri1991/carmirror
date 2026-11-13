import AVFoundation
import ReplayKit
import UniformTypeIdentifiers

/// Encodes screen frames to H.264 and writes a sliding-window live HLS stream
/// (fragmented MP4: init.mp4 + segN.m4s + live.m3u8) using AVAssetWriter's
/// built-in HLS segmentation (iOS 14+).
///
/// Broadcast extensions have a ~50 MB memory limit, so output is capped at
/// 1280px on the long side and old segments are deleted as we go.
final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    private let dir: URL
    private let segmentInterval: Double = 1.0     // ~1 s segments
    // AVPlayer won't sit closer than 3 x TARGETDURATION to the live edge, so this
    // sets the floor on latency (3 s). Raised only if a segment ever runs long.
    private var targetDuration = 1
    private let windowSize = 6                    // segments kept in the live playlist

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private let lock = NSLock()
    private var segments: [(name: String, duration: Double)] = []
    private var nextIndex = 0
    private var mediaSequence = 0

    /// File names are unique per broadcast. The server lets players cache segments,
    /// so reusing "seg0.m4s" across sessions could replay the previous broadcast.
    private let prefix: String
    private var initName: String { "init-\(prefix).mp4" }

    /// Non-nil once the encoder has failed; the stream can't continue.
    var error: Error? { writer?.status == .failed ? (writer?.error ?? CocoaError(.fileWriteUnknown)) : nil }

    init(directory: URL, sessionID: String) throws {
        dir = directory
        prefix = String(sessionID.prefix(8)).lowercased()
        super.init()
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Returns false once the writer has failed (see `error`).
    @discardableResult
    func append(_ buffer: CMSampleBuffer) -> Bool {
        if writer == nil { setUpWriter(firstBuffer: buffer) }
        guard let writer, let input else { return true }   // not set up yet; try again next frame
        guard writer.status == .writing else { return writer.status != .failed }
        if input.isReadyForMoreMediaData, !input.append(buffer) {
            return writer.status != .failed
        }
        // If the encoder is busy we just drop the frame; it's a live mirror.
        return true
    }

    func finish(completion: @escaping () -> Void) {
        guard let writer, writer.status == .writing else { completion(); return }
        input?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { completion(); return }
            self.lock.lock()
            self.writePlaylist(ended: true)
            self.lock.unlock()
            completion()
        }
    }

    // MARK: - Writer setup

    private func setUpWriter(firstBuffer buffer: CMSampleBuffer) {
        guard let pixelBuffer = buffer.imageBuffer else { return }
        let pts = buffer.presentationTimeStamp

        let srcW = Double(CVPixelBufferGetWidth(pixelBuffer))
        let srcH = Double(CVPixelBufferGetHeight(pixelBuffer))
        let scale = min(1.0, 1280.0 / max(srcW, srcH))
        let outW = Int(srcW * scale / 2) * 2      // H.264 needs even dimensions
        let outH = Int(srcH * scale / 2) * 2

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentInterval, preferredTimescale: 600)
        writer.initialSegmentStartTime = pts
        writer.delegate = self

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: segmentInterval,   // a keyframe starts every segment
                AVVideoAllowFrameReorderingKey: false,                   // no B-frames = lower latency
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = Self.transform(for: buffer)

        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("CarMirror: writer failed to start: \(String(describing: writer.error))")
            return
        }
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.input = input
    }

    /// ReplayKit always gives portrait-shaped buffers and tags the real orientation.
    /// We apply it once at start, so rotate the phone *before* starting the broadcast.
    private static func transform(for buffer: CMSampleBuffer) -> CGAffineTransform {
        guard let raw = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString,
                                        attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) else {
            return .identity
        }
        switch orientation {
        case .left:  return CGAffineTransform(rotationAngle: .pi / 2)
        case .right: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down:  return CGAffineTransform(rotationAngle: .pi)
        default:     return .identity
        }
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }

        switch segmentType {
        case .initialization:
            save(segmentData, as: initName)

        case .separable:
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? segmentInterval
            let name = "seg-\(prefix)-\(nextIndex).m4s"
            nextIndex += 1
            save(segmentData, as: name)
            segments.append((name, duration))
            // HLS rule: every EXTINF, rounded, must be <= TARGETDURATION.
            targetDuration = max(targetDuration, Int(duration.rounded()))

            while segments.count > windowSize {
                let old = segments.removeFirst()
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.name))
                mediaSequence += 1
            }
            writePlaylist(ended: false)

        @unknown default:
            break
        }
    }

    // MARK: - Files

    private func save(_ data: Data, as name: String) {
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// Caller must hold `lock`.
    private func writePlaylist(ended: Bool) {
        var m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXT-X-MEDIA-SEQUENCE:\(mediaSequence)
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="\(initName)"

        """
        for segment in segments {
            m3u8 += String(format: "#EXTINF:%.3f,\n", segment.duration) + segment.name + "\n"
        }
        if ended { m3u8 += "#EXT-X-ENDLIST\n" }
        save(Data(m3u8.utf8), as: Shared.playlistName)
    }
}
