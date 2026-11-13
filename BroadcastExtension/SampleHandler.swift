import ReplayKit
import AVFoundation
import QuartzCore

/// ReplayKit broadcast extension. iOS hands us every frame of the screen while
/// the user is broadcasting (system-wide, even when our app is in the background).
/// We encode frames into a live HLS stream in the shared App Group container.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "carmirror.broadcast")
    private var segmenter: HLSSegmenter?
    private var repeatTimer: DispatchSourceTimer?

    // ReplayKit only delivers frames when the screen changes. A static screen would
    // starve the live stream, so we re-send the last frame with fresh timestamps.
    private var lastFrame: CMSampleBuffer?
    private var lastAppendedPTS = CMTime.invalid
    private var lastAppendWallTime: CFTimeInterval = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.sync {
            do {
                let session = UUID().uuidString
                segmenter = try HLSSegmenter(directory: Shared.streamDir, sessionID: session)
                BroadcastStatus(state: .live, sessionID: session, updated: Date()).write()
                startRepeatTimer()
            } catch {
                finishBroadcastWithError(error)
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }          // video only; car audio stays on CarPlay/Bluetooth
        queue.sync {
            var buffer = sampleBuffer
            var pts = sampleBuffer.presentationTimeStamp
            if lastAppendedPTS.isValid, pts <= lastAppendedPTS {
                // A repeated frame can be stamped slightly ahead of this real frame's
                // capture time (ReplayKit delivers with variable latency). Dropping it
                // would freeze the old screen on the display, so keep the new content
                // and nudge its timestamp just past the last one instead.
                pts = lastAppendedPTS + CMTime(value: 1, timescale: 600)
                guard let retimed = Self.copy(sampleBuffer, pts: pts) else { return }
                buffer = retimed
            }
            append(buffer, pts: pts)
            lastFrame = sampleBuffer
        }
    }

    override func broadcastFinished() {
        let done = DispatchSemaphore(value: 0)
        queue.sync {
            repeatTimer?.cancel()
            repeatTimer = nil
            lastFrame = nil
            if let segmenter {
                segmenter.finish { done.signal() }
            } else {
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 2)
        BroadcastStatus(state: .stopped, sessionID: "", updated: Date()).write()
    }

    // MARK: - Private

    private func append(_ buffer: CMSampleBuffer, pts: CMTime) {
        guard let segmenter else { return }
        guard segmenter.append(buffer) else {
            fail(with: segmenter.error)
            return
        }
        lastAppendedPTS = pts
        lastAppendWallTime = CACurrentMediaTime()
    }

    /// The encoder died (e.g. memory pressure). Without this the stream silently stops
    /// while the app still thinks the broadcast is live. Caller is on `queue`.
    private func fail(with error: Error?) {
        NSLog("CarMirror: encoder failed: \(String(describing: error))")
        repeatTimer?.cancel()
        repeatTimer = nil
        lastFrame = nil
        segmenter = nil
        BroadcastStatus(state: .stopped, sessionID: "", updated: Date()).write()
        finishBroadcastWithError(error ?? NSError(
            domain: "CarMirror", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The screen encoder stopped. Please start mirroring again."]))
    }

    private func startRepeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.repeatLastFrameIfIdle() }
        timer.resume()
        repeatTimer = timer
    }

    private func repeatLastFrameIfIdle() {
        guard let frame = lastFrame, lastAppendedPTS.isValid else { return }
        let idle = CACurrentMediaTime() - lastAppendWallTime
        guard idle > 0.2 else { return }

        let newPTS = lastAppendedPTS + CMTime(seconds: idle, preferredTimescale: 600)
        if let copy = Self.copy(frame, pts: newPTS) { append(copy, pts: newPTS) }
    }

    private static func copy(_ buffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
