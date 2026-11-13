import AVFoundation
import Combine

/// Watches for a live broadcast, serves it over local HTTP, and plays it in an
/// AVPlayer that is allowed to go out over AirPlay (the car display).
@MainActor
final class MirrorController: ObservableObject {
    @Published private(set) var broadcastLive = false
    @Published private(set) var externalPlaybackActive = false
    @Published private(set) var serverError: String?
    /// Short player health readout for the Advanced section, e.g. "Playing · 12.4 s".
    @Published private(set) var playbackInfo = "Idle"
    @Published var useNetworkAddress = false {
        didSet { restartServer(); reloadPlayer() }
    }

    let player = AVPlayer()
    private let server = LocalHLSServer(root: Shared.streamDir)
    private var pollTimer: Timer?
    private var currentSession: String?
    private var externalObservation: NSKeyValueObservation?
    private var serverRetryPending = false
    private var itemStatusObservation: NSKeyValueObservation?
    /// Stall watchdog: last observed position and how many polls it hasn't moved.
    private var lastPosition: Double = -1
    private var stuckPolls = 0

    /// The extension rewrites the playlist about once a second (it re-sends the last
    /// frame on a static screen). If it stops for this long, the extension was killed
    /// (e.g. its ~50 MB memory limit) without getting to write a "stopped" status.
    private static let staleAfter: TimeInterval = 5

    /// AVPlayer refuses to sit closer than 3 x TARGETDURATION (1 s) to the live edge.
    private static let liveOffset = CMTime(seconds: 3, preferredTimescale: 600)

    init() {
        // Set the category now but don't activate it: activating a non-mixable
        // playback session would stop the user's music as soon as they open the app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)

        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.isMuted = true                               // stream has no audio track anyway

        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalPlaybackActive = active }
        }

        server.onStateChange = { [weak self] message in self?.serverStateChanged(message) }
        restartServer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    var streamURL: URL {
        let host = useNetworkAddress ? (NetworkInfo.localIPv4() ?? "127.0.0.1") : "127.0.0.1"
        return URL(string: "http://\(host):\(Shared.port)/\(Shared.playlistName)")!
    }

    /// Call from the "Start screen mirroring" button. The app is in the foreground
    /// here, which is when iOS lets us activate the session that keeps us running
    /// in the background once the user switches apps.
    func prepareForMirroring() {
        setAudioSessionActive(true)
    }

    // MARK: - Private

    private func setAudioSessionActive(_ active: Bool) {
        let session = AVAudioSession.sharedInstance()
        if active {
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func restartServer() {
        do {
            try server.start(port: Shared.port, loopbackOnly: !useNetworkAddress)
            serverError = nil
        } catch {
            serverError = error.localizedDescription
        }
    }

    private func serverStateChanged(_ message: String?) {
        serverError = message
        guard message != nil, !serverRetryPending else { return }
        // Port still held by the previous listener, or iOS tore the socket down while
        // we were suspended. Try again shortly instead of staying dead.
        serverRetryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.serverRetryPending = false
            self.restartServer()
        }
    }

    /// Session ID of a broadcast that is live *and* still producing segments.
    static func liveSessionID() -> String? {
        guard let status = BroadcastStatus.read(), status.state == .live else { return nil }
        let playlist = Shared.streamDir.appendingPathComponent(Shared.playlistName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: playlist.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < staleAfter else { return nil }
        return status.sessionID
    }

    private func updatePlaybackInfo() {
        guard let item = player.currentItem else { playbackInfo = "Idle"; return }
        let state: String
        switch (item.status, player.timeControlStatus) {
        case (.failed, _): state = "Failed: \(item.error?.localizedDescription ?? "unknown error")"
        case (.unknown, _): state = "Loading"
        case (_, .playing): state = "Playing"
        case (_, .waitingToPlayAtSpecifiedRate): state = "Buffering"
        default: state = "Paused"
        }
        playbackInfo = String(format: "%@ · %.1f s", state, max(0, item.currentTime().seconds))
    }

    private func poll() {
        defer { updatePlaybackInfo() }
        if let session = Self.liveSessionID() {
            if !broadcastLive {
                broadcastLive = true
                setAudioSessionActive(true)
            }
            if session != currentSession {
                currentSession = session
                reloadPlayer()
            } else if player.currentItem == nil || player.currentItem?.status == .failed {
                reloadPlayer()                              // recover from a failed item
            } else if player.timeControlStatus == .paused {
                setAudioSessionActive(true)                 // e.g. after a phone call interruption
                player.play()
            } else {
                checkForSilentStall()
            }
        } else if broadcastLive {
            broadcastLive = false
            currentSession = nil
            itemStatusObservation = nil
            player.replaceCurrentItem(with: nil)
            setAudioSessionActive(false)
        }
    }

    /// AVPlayer can report `.playing` while the system player underneath sits at rate 0
    /// (see `reloadPlayer`). A live stream's position must move; if it doesn't for 3 s,
    /// re-issue play, and if that doesn't help, reload the item.
    private func checkForSilentStall() {
        guard let item = player.currentItem, item.status == .readyToPlay else { stuckPolls = 0; return }
        let position = item.currentTime().seconds
        if abs(position - lastPosition) < 0.05 {
            stuckPolls += 1
        } else {
            stuckPolls = 0
        }
        lastPosition = position
        switch stuckPolls {
        case 3:
            NSLog("CarMirror: playback stuck at \(position)s, re-issuing play")
            player.pause()
            player.play()
        case 6...:
            NSLog("CarMirror: playback still stuck, reloading stream")
            reloadPlayer()
        default:
            break
        }
    }

    private func reloadPlayer() {
        guard broadcastLive else { return }
        let item = AVPlayerItem(url: streamURL)
        item.preferredForwardBufferDuration = 1
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = Self.liveOffset
        stuckPolls = 0
        lastPosition = -1
        // On iOS the player runs out of process. play() can arrive before the new item
        // and be reset to rate 0 ("CurrentItemChanged") while AVPlayer still reports
        // .playing, so nothing ever plays. Re-assert play once the item is ready.
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.player.play()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }
}
