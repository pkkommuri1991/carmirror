import XCTest

/// SRV-01 … SRV-08. Uses its own port so it doesn't clash with the host app's server on 8089.
final class LocalHLSServerTests: XCTestCase {
    private let port: UInt16 = 18089
    private var root: URL!
    private var server: LocalHLSServer!

    override func setUpWithError() throws {
        root = tempDir()
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n".utf8).write(to: root.appendingPathComponent("live.m3u8"))
        try Data(repeating: 7, count: 1234).write(to: root.appendingPathComponent("seg-abc-0.m4s"))
        server = LocalHLSServer(root: root)
        try server.start(port: port, loopbackOnly: true)
        try waitUntilServing()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func waitUntilServing(file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? RawHTTP.get("/live.m3u8", port: port))?.status == 200 { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("server never answered", file: file, line: line)
    }

    func test_SRV01_getPlaylist() throws {
        let r = try RawHTTP.get("/live.m3u8", port: port)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(r.headers["cache-control"], "no-cache")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "#EXTM3U\n#EXT-X-TARGETDURATION:1\n")
    }

    func test_SRV02_headSegment() throws {
        let r = try RawHTTP.get("/seg-abc-0.m4s", port: port, method: "HEAD")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-length"], "1234")
        XCTAssertEqual(r.headers["content-type"], "video/iso.segment")
        XCTAssertTrue(r.body.isEmpty)
    }

    func test_SRV03_missingIs404() throws {
        XCTAssertEqual(try RawHTTP.get("/nope.m4s", port: port).status, 404)
        XCTAssertEqual(try RawHTTP.get("/", port: port).status, 404)
    }

    func test_SRV04_postIs405() throws {
        XCTAssertEqual(try RawHTTP.get("/live.m3u8", port: port, method: "POST").status, 405)
    }

    func test_SRV05_traversalBlocked() throws {
        // A file one level above the served root must never be reachable.
        let secret = root.deletingLastPathComponent().appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        for path in ["/../\(secret.lastPathComponent)", "/..", "/%2e%2e/\(secret.lastPathComponent)", "/../../etc/passwd"] {
            let r = try RawHTTP.get(path, port: port)
            XCTAssertEqual(r.status, 404, path)
            XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains("secret"), path)
        }
    }

    func test_SRV06_queryStringIgnored() throws {
        XCTAssertEqual(try RawHTTP.get("/live.m3u8?_HLS_msn=3&t=1", port: port).status, 200)
    }

    func test_SRV07_restartOnSamePort() throws {
        var errors: [String?] = []
        server.onStateChange = { errors.append($0) }
        for _ in 0..<3 {
            try server.start(port: port, loopbackOnly: true)
            try waitUntilServing()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // let main-queue callbacks land
        XCTAssertFalse(errors.contains { $0 != nil }, "restart reported errors: \(errors)")
    }

    func test_SRV08_portInUseIsReported() throws {
        let second = LocalHLSServer(root: root)
        let reported = expectation(description: "error reported")
        second.onStateChange = { message in if message != nil { reported.fulfill() } }
        try second.start(port: port, loopbackOnly: true)
        wait(for: [reported], timeout: 5)
        second.stop()
    }
}
