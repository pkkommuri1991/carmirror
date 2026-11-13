# CarMirror – Test Plan

Device under test: iPhone 15 Pro (iOS 27), Xcode 27.2, free Personal Team signing.
Run all: `xcodebuild test -project CarMirror.xcodeproj -scheme CarMirror -destination 'id=<UDID>' -allowProvisioningUpdates`
Phone must stay **unlocked** during the run.

## A. Unit tests (on device, `CarMirrorTests`)

| ID | Area | Case | Expected |
|---|---|---|---|
| SRV-01 | HTTP server | GET existing playlist | 200, `application/vnd.apple.mpegurl`, `Cache-Control: no-cache`, body matches file |
| SRV-02 | HTTP server | HEAD segment | 200, correct `Content-Length`, empty body |
| SRV-03 | HTTP server | GET missing file | 404 |
| SRV-04 | HTTP server | POST | 405 |
| SRV-05 | HTTP server | Path traversal `/../../x` and `/..` | 404, nothing outside root served |
| SRV-06 | HTTP server | Query string `?t=1` | ignored, 200 |
| SRV-07 | HTTP server | Restart on same port (network toggle) | second server answers; no lingering failure |
| SRV-08 | HTTP server | Port already taken | `onStateChange` reports an error message |
| SEG-01 | Segmenter | 4 s of 1170×2532 frames | `init-<id>.mp4` + `seg-<id>-N.m4s` + `live.m3u8` written |
| SEG-02 | Segmenter | Playlist validity | `TARGETDURATION:1`, every EXTINF rounds ≤ target, ≤ 6 segments, MAP points at init file, sequence matches first segment |
| SEG-03 | Segmenter | Output size | ≤ 1280 px long side, even dimensions, portrait aspect kept |
| SEG-04 | Segmenter | finish() | `#EXT-X-ENDLIST` appended |
| SEG-05 | Segmenter | Session isolation | two sessions → different file names |
| SEG-06 | Playback | AVPlayer plays the stream from the local server | item `readyToPlay`, presentation size = encoded size |
| EXT-01 | SampleHandler | broadcastStarted | `status.json` = live with session ID |
| EXT-02 | SampleHandler | Static screen | repeat timer keeps producing segments with no new frames |
| EXT-03 | SampleHandler | Real frame arriving after a repeated frame with an older PTS | frame kept (becomes `lastFrame`), not dropped |
| EXT-04 | SampleHandler | broadcastFinished | `status.json` = stopped, ENDLIST written |
| CTL-01 | MirrorController | live status + fresh playlist | detected live |
| CTL-02 | MirrorController | live status + playlist older than 5 s (extension killed) | not live |
| CTL-03 | MirrorController | stopped status | not live |
| NET-01 | NetworkInfo | localIPv4() | nil or a valid dotted IPv4 |
| SHR-01 | Shared | App Group container | resolvable, status round-trips |

## B. UI tests (on device, `CarMirrorUITests`)

| ID | Case | Expected |
|---|---|---|
| UI-01 | Cold launch | Title "CarMirror"; "Screen broadcast: Off"; "Car display: Not connected"; Start button; parked-only footer |
| UI-02 | Advanced toggle on/off | URL switches 127.0.0.1 ↔ LAN IP (when on Wi-Fi); no server error shown; back to 127.0.0.1 |
| UI-03 | Start broadcast (E2E) | Apple sheet opens with CarMirror; after Start Broadcast, status becomes **Live** within 20 s |
| UI-04 | Broadcast while app in background 15 s | Returning shows still **Live** (segments kept flowing) |
| UI-05 | Stop broadcast from app | Status returns to **Off** within 10 s |

## C. Manual only (needs hardware the automation can't drive)

| ID | Case | Expected |
|---|---|---|
| MAN-01 | AirPlay to Mac/Apple TV | Receiver shows phone screen ~3–5 s behind; "Car display: Connected" |
| MAN-02 | CarPlay head unit with AirPlay video, parked | Same as MAN-01 on car display |
| MAN-03 | Landscape start | Orientation correct on receiver |
| MAN-04 | Phone call during mirroring | Playback resumes after call |
