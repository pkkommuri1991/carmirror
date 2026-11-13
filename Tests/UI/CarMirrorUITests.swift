import XCTest

/// UI-01 … UI-05 on a real device. Keep the phone unlocked while these run.
final class CarMirrorUITests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
        app.launch()
        dismissSystemAlerts()
    }

    /// e.g. "Live Broadcast to CarMirror has stopped …" left over when a previous run's
    /// broadcast was killed by reinstalling the app.
    private func dismissSystemAlerts() {
        for _ in 0..<3 {
            var tapped = false
            for host in [springboard, app] {
                let ok = host.alerts.buttons["OK"].firstMatch
                if ok.waitForExistence(timeout: 1.5) { ok.tap(); tapped = true }
            }
            if !tapped { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: helpers

    private func statusLabel(_ title: String) -> XCUIElement {
        // The Label has an icon ("Selected") and a text; read the text.
        app.staticTexts.matching(identifier: "status.\(title)").firstMatch
    }

    private func waitForStatus(_ title: String, _ text: String, timeout: TimeInterval,
                               file: StaticString = #filePath, line: UInt = #line) {
        let element = statusLabel(title)
        let predicate = NSPredicate(format: "label == %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "\(title) expected '\(text)', got '\(element.exists ? element.label : "<missing>")'",
                       file: file, line: line)
    }

    /// The ReplayKit sheet is system UI; depending on iOS it's hosted in our app or SpringBoard.
    /// iOS 26 and earlier say "Start Broadcast"; iOS 27 says "Start Sharing".
    private func sheetButton(_ labels: [String], timeout: TimeInterval = 8) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for host in [app, springboard] {
                for label in labels {
                    let button = host.buttons[label].firstMatch
                    if button.exists && button.isHittable { return button }
                    let text = host.staticTexts[label].firstMatch      // some iOS versions expose it as text
                    if text.exists && text.isHittable { return text }
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Ends any broadcast left over from a previous (failed) run.
    private func ensureNotBroadcasting() {
        guard statusLabel("Screen broadcast").label == "Live" else { return }
        app.buttons["mirror.button"].tap()
        sheetButton(["Stop Sharing", "Stop Broadcast"])?.tap()
        dismissSheetIfShown()
        waitForStatus("Screen broadcast", "Off", timeout: 12)
    }

    /// iOS 27 keeps the Screen Sharing sheet open (with a timer) after starting/stopping.
    /// It lives in a system process XCUITest can't see, so tap the dimmed area above it.
    /// Harmless when no sheet is up (lands on the navigation bar area).
    private func dismissSheetIfShown() {
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            Thread.sleep(forTimeInterval: 1.2)
        }
    }

    // MARK: tests

    func test_UI01_coldLaunchState() {
        XCTAssertTrue(app.navigationBars["CarMirror"].waitForExistence(timeout: 5))
        ensureNotBroadcasting()
        waitForStatus("Screen broadcast", "Off", timeout: 3)
        waitForStatus("Car display", "Not connected", timeout: 3)
        XCTAssertTrue(app.buttons["mirror.button"].exists)
        XCTAssertTrue(app.buttons["mirror.button"].label.contains("Start screen mirroring"))
        XCTAssertTrue(app.staticTexts["Only watch while parked."].exists)
        XCTAssertFalse(app.staticTexts["advanced.error"].exists, "server error on launch")
        attach("UI-01 launch")
    }

    func test_UI02_advancedToggle() {
        let url = app.staticTexts["advanced.url"]
        url.swipeUpIfNeeded(in: app)
        XCTAssertEqual(url.label, "http://127.0.0.1:8089/live.m3u8")

        let toggle = app.switches["advanced.toggle"]
        toggle.switches.firstMatch.tap()
        // Opening the server to the LAN may trigger the Local Network permission prompt.
        let deny = springboard.alerts.buttons["Don’t Allow"]
        if deny.waitForExistence(timeout: 2) { deny.tap() }

        let changed = NSPredicate(format: "label != %@", "http://127.0.0.1:8089/live.m3u8")
        _ = XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: url)], timeout: 2)
        attach("UI-02 toggle on")
        let warning = app.staticTexts["advanced.noNetwork"]
        if url.label == "http://127.0.0.1:8089/live.m3u8" {
            // Phone has no Wi-Fi/hotspot address: the app must say so instead of failing silently.
            XCTAssertTrue(warning.exists, "toggle on, no LAN address, and no warning shown")
        } else {
            XCTAssertNotNil(url.label.range(of: #"^http://\d+\.\d+\.\d+\.\d+:8089/live\.m3u8$"#, options: .regularExpression), url.label)
            XCTAssertFalse(warning.exists, "warning shown although a LAN address exists")
        }
        Thread.sleep(forTimeInterval: 2.5)    // give a failed listener time to report + retry
        XCTAssertFalse(app.staticTexts["advanced.error"].exists,
                       "server error after toggle: \(app.staticTexts["advanced.error"].label)")

        toggle.switches.firstMatch.tap()
        let back = NSPredicate(format: "label == %@", "http://127.0.0.1:8089/live.m3u8")
        _ = XCTWaiter.wait(for: [expectation(for: back, evaluatedWith: url)], timeout: 3)
        XCTAssertEqual(url.label, "http://127.0.0.1:8089/live.m3u8", "toggle value: \(String(describing: toggle.value))")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(app.staticTexts["advanced.error"].exists,
                       "server error after toggling back: \(app.staticTexts["advanced.error"].label)")
    }

    /// UI-03 + UI-04 + UI-05: the real ReplayKit → encoder → HTTP → AVPlayer pipeline.
    func test_UI03_04_05_broadcastEndToEnd() throws {
        ensureNotBroadcasting()
        // Never leave a broadcast running: the next install would kill it mid-session.
        addTeardownBlock { [self] in
            app.activate()
            ensureNotBroadcasting()
        }

        // UI-03 start
        app.buttons["mirror.button"].tap()
        attach("UI-03 picker sheet")
        let start = try XCTUnwrap(sheetButton(["Start Sharing", "Start Broadcast"]), "ReplayKit sheet didn't show a start button")
        start.tap()
        Thread.sleep(forTimeInterval: 4)        // countdown
        attach("UI-03 after start")
        dismissSheetIfShown()
        waitForStatus("Screen broadcast", "Live", timeout: 25)
        attach("UI-03 live")
        XCTAssertTrue(app.buttons["mirror.button"].label.contains("Stop or change broadcast"))

        // UI-03b the stream must actually play (clock advances), not just exist
        let playback = app.descendants(matching: .any)["advanced.playback"].firstMatch
        playback.swipeUpIfNeeded(in: app)
        func seconds() -> Double? {
            let text = [playback.label, (playback.value as? String) ?? ""].joined(separator: " ")
            guard let m = text.range(of: #"[0-9]+\.[0-9] s"#, options: .regularExpression) else { return nil }
            return Double(text[m].dropLast(2))
        }
        Thread.sleep(forTimeInterval: 4)
        let p0 = seconds()
        Thread.sleep(forTimeInterval: 6)
        let p1 = seconds()
        attach("UI-03b player readout")
        let readout = [playback.label, (playback.value as? String) ?? ""].joined(separator: " ")
        XCTContext.runActivity(named: "Player readout: \(readout) (p0=\(String(describing: p0)) p1=\(String(describing: p1)))") { _ in }
        if let p0, let p1 {
            XCTAssertGreaterThan(p1 - p0, 4, "video isn't advancing on the player: \(readout)")
        } else {
            XCTFail("couldn't read player position: \(readout)")
        }
        app.swipeDown(); app.swipeDown()

        // UI-04 background for 15 s (other app in front), stream must keep flowing
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 15)
        app.activate()
        waitForStatus("Screen broadcast", "Live", timeout: 5)
        attach("UI-04 back from background")

        // UI-05 stop
        app.buttons["mirror.button"].tap()
        let stop = try XCTUnwrap(sheetButton(["Stop Sharing", "Stop Broadcast"]), "no stop button")
        stop.tap()
        waitForStatus("Screen broadcast", "Off", timeout: 12)
        dismissSheetIfShown()
        attach("UI-05 stopped")
    }
}

extension CarMirrorUITests {
    /// UI-06: AirPlay to a receiver (e.g. a Mac with AirPlay Receiver on) while broadcasting.
    /// Run with: TEST_RUNNER_AIRPLAY_TARGET="<receiver name>" xcodebuild test ...
    func test_UI06_airplayToReceiver() throws {
        guard let target = ProcessInfo.processInfo.environment["AIRPLAY_TARGET"], !target.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_AIRPLAY_TARGET to an AirPlay receiver name to run this test")
        }
        ensureNotBroadcasting()
        addTeardownBlock { [self] in
            app.activate()
            ensureNotBroadcasting()
            disconnectAirPlay()
        }

        // Pick the receiver in the system AirPlay menu.
        let routeButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'AirPlay'")).firstMatch
        XCTAssertTrue(routeButton.waitForExistence(timeout: 5), "AirPlay button not found")
        routeButton.tap()
        attach("UI-06 route menu")
        let receiver = try XCTUnwrap(findAnywhere(target, timeout: 12), "receiver '\(target)' not listed in AirPlay menu")
        receiver.tap()
        Thread.sleep(forTimeInterval: 2)
        attach("UI-06 after picking receiver")
        dismissSheetIfShown()

        // Start the broadcast; video should go out over AirPlay.
        app.buttons["mirror.button"].tap()
        try XCTUnwrap(sheetButton(["Start Sharing", "Start Broadcast"]), "no start button").tap()
        Thread.sleep(forTimeInterval: 4)
        dismissSheetIfShown()
        waitForStatus("Screen broadcast", "Live", timeout: 25)
        waitForStatus("Car display", "Connected", timeout: 20)
        attach("UI-06 connected")

        // Stays connected and live with the app in the background.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 20)
        app.activate()
        waitForStatus("Screen broadcast", "Live", timeout: 5)
        waitForStatus("Car display", "Connected", timeout: 5)
        attach("UI-06 after 20 s in background")
    }

    private func findAnywhere(_ label: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", label)
        while Date() < deadline {
            for host in [app, springboard] {
                for query in [host.buttons, host.cells, host.staticTexts] {
                    let element = query.matching(predicate).firstMatch
                    if element.exists && element.isHittable { return element }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func disconnectAirPlay() {
        let routeButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'AirPlay'")).firstMatch
        guard routeButton.waitForExistence(timeout: 3) else { return }
        routeButton.tap()
        findAnywhere("iPhone", timeout: 5)?.tap()
        Thread.sleep(forTimeInterval: 1)
        dismissSheetIfShown()
    }
}

private extension XCUIElement {
    func swipeUpIfNeeded(in app: XCUIApplication) {
        var tries = 0
        while !isHittable && tries < 5 { app.swipeUp(); tries += 1 }
    }
}
