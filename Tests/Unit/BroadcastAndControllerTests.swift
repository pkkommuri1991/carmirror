import XCTest
import AVFoundation
@testable import CarMirror

/// EXT-01…04 (SampleHandler), CTL-01…03 (MirrorController), NET-01, SHR-01.
/// These use the real App Group container, the same one the app and extension share.
final class SampleHandlerTests: XCTestCase {

    override func tearDown() {
        // Leave the shared container in a "not broadcasting" state for the host app.
        BroadcastStatus(state: .stopped, sessionID: "", updated: Date()).write()
        try? FileManager.default.removeItem(at: Shared.streamDir)
    }

    private func status() -> BroadcastStatus? { BroadcastStatus.read() }

    func test_EXT01_02_04_lifecycleAndStaticScreen() throws {
        let handler = SampleHandler()
        handler.broadcastStarted(withSetupInfo: nil)
        let started = try XCTUnwrap(status())
        XCTAssertEqual(started.state, .live)
        XCTAssertFalse(started.sessionID.isEmpty)

        // One real frame, then a static screen for 4 s: the repeat timer must keep the stream alive.
        handler.processSampleBuffer(Frames.make(), with: .video)
        Thread.sleep(forTimeInterval: 4)
        let p = try Playlist(contentsOf: Shared.streamDir)
        XCTAssertGreaterThanOrEqual(p.segments.count, 2, "static screen starved the stream")
        let modified = try FileManager.default.attributesOfItem(
            atPath: Shared.streamDir.appendingPathComponent("live.m3u8").path)[.modificationDate] as! Date
        XCTAssertLessThan(Date().timeIntervalSince(modified), 2.5, "playlist not being refreshed")

        handler.broadcastFinished()
        XCTAssertEqual(status()?.state, .stopped)
        XCTAssertTrue(try Playlist(contentsOf: Shared.streamDir).ended)
    }

    func test_EXT03_realFrameAfterRepeatIsKept() throws {
        let handler = SampleHandler()
        handler.broadcastStarted(withSetupInfo: nil)
        defer { handler.broadcastFinished() }

        let first = Frames.now
        handler.processSampleBuffer(Frames.make(pts: first), with: .video)
        Thread.sleep(forTimeInterval: 0.6)                 // repeat timer has now stamped frames past `first + 0.3`

        // ReplayKit delivers a frame captured shortly after `first` – older than the repeats.
        let late = Frames.make(shade: 10, pts: first + CMTime(seconds: 0.1, preferredTimescale: 600))
        handler.processSampleBuffer(late, with: .video)

        let shown: CMSampleBuffer? = privateValue(handler, "lastFrame")
        XCTAssertTrue(shown === late, "new screen content was dropped; display would freeze on the old frame")
        let lastPTS: CMTime = try XCTUnwrap(privateValue(handler, "lastAppendedPTS"))
        XCTAssertGreaterThan(lastPTS, first + CMTime(seconds: 0.3, preferredTimescale: 600), "timestamps must stay increasing")
    }

    func test_audioBuffersIgnored() throws {
        let handler = SampleHandler()
        handler.broadcastStarted(withSetupInfo: nil)
        defer { handler.broadcastFinished() }
        handler.processSampleBuffer(Frames.make(), with: .audioApp)
        let shown: CMSampleBuffer? = privateValue(handler, "lastFrame")
        XCTAssertNil(shown)
    }
}

@MainActor
final class MirrorControllerTests: XCTestCase {
    private var playlist: URL { Shared.streamDir.appendingPathComponent(Shared.playlistName) }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: Shared.streamDir, withIntermediateDirectories: true)
        try Data("#EXTM3U\n".utf8).write(to: playlist)
    }

    override func tearDown() async throws {
        BroadcastStatus(state: .stopped, sessionID: "", updated: Date()).write()
        try? FileManager.default.removeItem(at: Shared.streamDir)
    }

    func test_CTL01_liveAndFresh() {
        BroadcastStatus(state: .live, sessionID: "S1", updated: Date()).write()
        XCTAssertEqual(MirrorController.liveSessionID(), "S1")
    }

    func test_CTL02_extensionKilledIsNotLive() throws {
        BroadcastStatus(state: .live, sessionID: "S2", updated: Date()).write()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: playlist.path)
        XCTAssertNil(MirrorController.liveSessionID())
    }

    func test_CTL03_stoppedIsNotLive() {
        BroadcastStatus(state: .stopped, sessionID: "", updated: Date()).write()
        XCTAssertNil(MirrorController.liveSessionID())
    }

    func test_CTL04_noPlaylistYetIsNotLive() throws {
        try FileManager.default.removeItem(at: playlist)
        BroadcastStatus(state: .live, sessionID: "S4", updated: Date()).write()
        XCTAssertNil(MirrorController.liveSessionID())
    }
}

final class EnvironmentTests: XCTestCase {
    func test_NET01_localIPv4() {
        if let ip = NetworkInfo.localIPv4() {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 4, ip)
            XCTAssertTrue(parts.allSatisfy { (0...255).contains($0) }, ip)
        }
    }

    func test_SHR01_appGroupRoundTrip() throws {
        XCTAssertEqual(Shared.appGroup, "group.com.pradeepkommuri.carmirror")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Shared.containerURL.path))
        BroadcastStatus(state: .stopped, sessionID: "rt", updated: Date()).write()
        XCTAssertEqual(BroadcastStatus.read()?.sessionID, "rt")
    }
}
