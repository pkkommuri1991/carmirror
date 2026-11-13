import XCTest
import AVFoundation

/// SEG-01 … SEG-06: real H.264 encoding on the device's hardware encoder.
final class HLSSegmenterTests: XCTestCase {

    private func record(seconds: Double, session: String = UUID().uuidString, into dir: URL) throws -> HLSSegmenter {
        let segmenter = try HLSSegmenter(directory: dir, sessionID: session)
        feed(seconds: seconds) { XCTAssertTrue(segmenter.append($0), "append reported failure: \(String(describing: segmenter.error))") }
        return segmenter
    }

    private func finish(_ segmenter: HLSSegmenter) {
        let done = expectation(description: "finish")
        segmenter.finish { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func test_SEG01_02_filesAndPlaylistAreValid() throws {
        let dir = tempDir().appendingPathComponent("stream")
        let segmenter = try record(seconds: 8.5, session: "ABCDEF12-3456", into: dir)
        defer { finish(segmenter) }
        XCTAssertNil(segmenter.error)

        let p = try Playlist(contentsOf: dir)
        XCTAssertEqual(p.mapURI, "init-abcdef12.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(p.mapURI).path))
        XCTAssertEqual(p.targetDuration, 1)
        XCTAssertGreaterThanOrEqual(p.segments.count, 6, "expected a full window after 8.5 s")
        XCTAssertLessThanOrEqual(p.segments.count, 6, "sliding window must cap at 6")
        XCTAssertFalse(p.ended)

        for s in p.segments {
            XCTAssertTrue(s.name.hasPrefix("seg-abcdef12-"), s.name)
            XCTAssertLessThanOrEqual(Int(s.duration.rounded()), p.targetDuration, "\(s.name) \(s.duration)s breaks TARGETDURATION")
            XCTAssertGreaterThan(s.duration, 0.3)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(s.name).path), s.name)
        }
        // MEDIA-SEQUENCE must equal the index of the first listed segment.
        let firstIndex = Int(p.segments.first!.name.split(separator: "-").last!.dropLast(4))!
        XCTAssertEqual(p.mediaSequence, firstIndex)

        // Old segments are deleted from disk, so the folder doesn't grow.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".m4s") }
        XCTAssertEqual(Set(onDisk), Set(p.segments.map(\.name)))
    }

    func test_SEG03_outputDimensions() throws {
        let dir = tempDir().appendingPathComponent("stream")
        let segmenter = try record(seconds: 2.5, into: dir)
        finish(segmenter)
        let p = try Playlist(contentsOf: dir)
        let asset = AVURLAsset(url: dir.appendingPathComponent(p.mapURI))
        let exp = expectation(description: "tracks")
        var size = CGSize.zero
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                size = (try? await track.load(.naturalSize)) ?? .zero
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(max(size.width, size.height), 1280, "long side capped at 1280 (got \(size))")
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(size.width / size.height, 1170.0 / 2532.0, accuracy: 0.01)
    }

    func test_SEG04_finishEndsPlaylist() throws {
        let dir = tempDir().appendingPathComponent("stream")
        finish(try record(seconds: 2.5, into: dir))
        XCTAssertTrue(try Playlist(contentsOf: dir).ended)
    }

    func test_SEG05_sessionsUseDifferentNames() throws {
        let dirA = tempDir().appendingPathComponent("a"), dirB = tempDir().appendingPathComponent("b")
        let a = try record(seconds: 2.5, session: "11111111-x", into: dirA)
        let b = try record(seconds: 2.5, session: "22222222-x", into: dirB)
        finish(a); finish(b)
        let pa = try Playlist(contentsOf: dirA), pb = try Playlist(contentsOf: dirB)
        XCTAssertNotEqual(pa.mapURI, pb.mapURI)
        XCTAssertTrue(Set(pa.segments.map(\.name)).isDisjoint(with: pb.segments.map(\.name)))
    }

    /// SEG-06: the stream actually decodes in AVPlayer when served over HTTP.
    @MainActor
    func test_SEG06_avPlayerPlaysServedStream() throws {
        let dir = tempDir().appendingPathComponent("stream")
        let segmenter = try HLSSegmenter(directory: dir, sessionID: UUID().uuidString)
        let server = LocalHLSServer(root: dir)
        try server.start(port: 18090, loopbackOnly: true)
        defer { server.stop() }

        let feeding = Thread { self.feed(seconds: 12) { segmenter.append($0) } }
        feeding.start()
        RunLoop.main.run(until: Date().addingTimeInterval(4))    // build up a few segments

        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:18090/live.m3u8")!)
        // Same configuration MirrorController uses.
        item.preferredForwardBufferDuration = 1
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = CMTime(seconds: 3, preferredTimescale: 600)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        // A video-only HLS item doesn't start its clock without a video output that
        // consumes frames (the app has an on-screen AVPlayerLayer). Stand in for one.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let puller = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t) { _ = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) }
        }
        defer { puller.invalidate() }
        player.play()

        let ready = expectation(description: "readyToPlay")
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay {
                // iOS: play() can reach the out-of-process player before the item and get reset
                // to rate 0 ("CurrentItemChanged"). Re-assert once the item is ready (as the app does).
                player.play()
                ready.fulfill()
            }
            if item.status == .failed { XCTFail("player failed: \(String(describing: item.error))"); ready.fulfill() }
        }
        wait(for: [ready], timeout: 8)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let t0 = item.currentTime().seconds
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let t1 = item.currentTime().seconds
        observation.invalidate()
        let diag = "t0=\(t0) t1=\(t1) control=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "-") " +
            "likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) seekable=\(item.seekableTimeRanges.map { $0.timeRangeValue.end.seconds }) " +
            "errors=\(item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])"
        print("SEG06 " + diag)
        if let disk = try? Playlist(contentsOf: dir) {
            let age = Date().timeIntervalSince((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("live.m3u8").path)[.modificationDate] as? Date) ?? .distantPast)
            print("SEG06 disk seq=\(disk.mediaSequence) count=\(disk.segments.count) last=\(disk.segments.last?.name ?? "-") ageSec=\(age) writerError=\(String(describing: segmenter.error))")
        }
        for e in item.accessLog()?.events ?? [] {
            print("SEG06 access uri=\(e.uri ?? "-") mediaReq=\(e.numberOfMediaRequests) stalls=\(e.numberOfStalls) watched=\(e.durationWatched) transferred=\(e.numberOfBytesTransferred) dropped=\(e.numberOfDroppedVideoFrames)")
        }

        XCTAssertEqual(item.presentationSize.height, 1280, "decoded size \(item.presentationSize)")
        XCTAssertGreaterThan(t1 - t0, 2.0, "playback didn't advance in real time: \(diag)")
        let offsetErrors = item.errorLog()?.events.filter { $0.errorStatusCode == -12640 } ?? []
        XCTAssertTrue(offsetErrors.isEmpty, "AVPlayer rejected the configured live offset")
        player.pause()
        while feeding.isExecuting { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let done = expectation(description: "finish")
        segmenter.finish { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}
