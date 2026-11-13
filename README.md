# CarMirror

Mirror your iPhone screen to a CarPlay display. It uses the same approach as CarDash: ReplayKit, a local live stream, and AirPlay video in the car.

## How it works

```
 iPhone screen
     │  ReplayKit "Screen Broadcast" (system-wide, any app)
     ▼
 BroadcastExtension/SampleHandler.swift
     │  H.264 encode + HLS segmenting (AVAssetWriter, 1 s fMP4 segments)
     ▼
 App Group folder:  init-<id>.mp4  seg-<id>-41.m4s … seg-<id>-46.m4s  live.m3u8
     │
     ▼
 App/LocalHLSServer.swift   http://127.0.0.1:8089/live.m3u8
     │
     ▼
 AVPlayer (allowsExternalPlayback)  ──AirPlay──►  CarPlay display (parked)
```

- **SampleHandler**: receives every screen frame while broadcasting. When the screen is static it resends the last frame so the live stream doesn't stall.
- **HLSSegmenter**: encodes to H.264, capped at 1280px so it stays under the extension's ~50 MB memory limit. Keeps a sliding window of 6 segments. File names include a per-broadcast ID so a restarted broadcast never replays cached segments from the previous one.
- **LocalHLSServer**: a tiny Network.framework HTTP server in the main app.
- **MirrorController**: notices when a broadcast goes live (and treats it as stopped if the playlist stops updating for 5 s, e.g. the extension was killed) and plays the stream in an AVPlayer that's allowed to AirPlay. The `audio` background mode keeps it running while you use other apps.

## Setup (Mac with Xcode 16+)

1. `brew install xcodegen`
2. Edit the top of `project.yml`:
   - `DEVELOPMENT_TEAM`: your Team ID
   - `APP_BUNDLE_ID`: something unique, e.g. `com.pradeep.CarMirror`
   - `APP_GROUP`: e.g. `group.com.pradeep.carmirror`
3. `cd CarMirror && xcodegen generate && open CarMirror.xcodeproj`
4. Run on a **real iPhone**. Broadcast extensions don't run in the Simulator.

## Testing without a car

Any AirPlay video receiver uses the same path:

- **A Mac** (macOS 12+): System Settings → General → AirDrop & Handoff → AirPlay Receiver.
- **An Apple TV**.

In the app, pick the Mac or Apple TV with the AirPlay button, tap **Start screen mirroring**, choose CarMirror, tap **Start Sharing** (iOS 27) / **Start Broadcast** (older iOS), then switch apps. The receiver should show your screen about 3–5 seconds behind.

## In the car

- The iPhone needs iOS 26 or later.
- The head unit must support "CarPlay with AirPlay video". The automaker decides this, and support is still rare. Video only plays while parked.
- If the car only does CarPlay audio, this won't show video. That's the same limitation CarDash warns about.

## Known limitations

| Issue | Why | Workaround |
|---|---|---|
| 3–5 s delay | AVPlayer stays at least 3 × `#EXT-X-TARGETDURATION` (1 s) behind live | Going lower needs Low-Latency HLS (partial segments + blocking reloads) |
| Netflix and other DRM apps show black | iOS blanks protected content in ReplayKit | None |
| No audio | Kept out for simplicity; car audio already goes over CarPlay/Bluetooth | Add an AAC input to the writer for `.audioApp` buffers |
| Orientation fixed at start | Track transform is set once | Rotate first, then start the broadcast |
| Receiver says it can't play | Some receivers fetch the URL themselves | Turn on "Serve on local network" in Advanced |

## Untested assumptions

This code hasn't been compiled. It was written outside Xcode. Check these first:

1. AVFoundation should push a `127.0.0.1` HLS stream to the AirPlay receiver itself rather than handing it the URL. If not, use the network-address toggle.
2. If landscape comes out upside down, swap the `.left` and `.right` angles in `HLSSegmenter.transform(for:)`.

## App Store notes

The app uses only public APIs. Apple will look hard at anything showing video in cars, so keep the "parked only" messaging. Don't claim CarPlay support unless you also add a CarPlay scene, which needs an Apple entitlement.
