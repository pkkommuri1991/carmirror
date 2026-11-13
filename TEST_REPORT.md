# CarMirror – QA Test Report

**Date:** 2026-11-13 · **Device:** iPhone 15 Pro, iOS 27 · **Toolchain:** Xcode 27.2, free Personal Team signing
**Final result: 25 / 25 automated tests pass on device** (`results/full1.xcresult`); UI suite re-run for stability: 3 / 3 pass again (`results/ui_rerun.xcresult`, Player 7.0 s → 14.0 s)

How to run:
```bash
cd CarMirror_src/CarMirror
xcodegen generate
xcodebuild test -project CarMirror.xcodeproj -scheme CarMirror -destination 'id=<UDID>' -allowProvisioningUpdates
```
Keep the phone unlocked (Auto-Lock → Never) while tests run.

## Results

| Suite | Tests | Result |
|---|---|---|
| HTTP server (SRV-01…08) | 8 | ✅ |
| Encoder / HLS segmenter (SEG-01…05) | 5 | ✅ |
| AVPlayer plays the served stream (SEG-06) | 1 | ✅ (was ❌) |
| Broadcast extension (EXT-01…04, audio ignored) | 3 | ✅ |
| Live/stale detection (CTL-01…04) | 4 | ✅ |
| Environment (NET-01, SHR-01) | 2 | ✅ |
| UI: launch (UI-01), network toggle (UI-02) | 2 | ✅ |
| UI: real broadcast end-to-end (UI-03…05) | 1 | ✅ (was ❌) — Player 8.0 s → 14.0 s in 6 s |
| UI: AirPlay to a Mac receiver + 20 s in background (UI-06) | 1 | ✅ — "Pradeep's MacBook Air": Live + Connected after 20 s backgrounded (`results/ui06.xcresult`) |
| Manual: picture shown on the Mac during UI-06 (MAN-01) | — | ✅ confirmed by tester (iPhone screen visible on the Mac) |

## Defects found and fixed

| # | Severity | Defect | Found by | Fix |
|---|---|---|---|---|
| D1 | **Critical** | **Mirrored video never played.** On iOS AVPlayer runs out of process; `play()` reached it before the new item and was reset to rate 0 (`CurrentItemChanged`), while AVPlayer still reported `.playing`. Car/AirPlay display would show a frozen first frame. Present in the original code. | SEG-06, UI-03b, device log (`mediaplaybackd`) | `MirrorController.reloadPlayer` re-asserts `play()` when the item becomes `readyToPlay`; new watchdog re-plays / reloads if a live stream's position stops moving for 3 s. |
| D2 | High | Video-only stream needs a ready video output; the only `AVPlayerLayer` lived in a lazily built List row (often off screen). | macOS/iOS player logs: "video-only item is waiting for video output" | Tiny always-mounted `AVPlayerLayer` in `ContentView`. |
| D3 | High | New screen content dropped after a static period (timestamp collision with repeated frames) → display froze on old screen. | Harness: 8/119 frames lost → 0/119 | `SampleHandler` retimes instead of dropping. |
| D4 | High | Server restart on the same port failed ("Address already in use") when toggling *Serve on local network*. | SRV-07 | `LocalHLSServer` starts the new listener only after the old one reports `.cancelled`. |
| D5 | Medium | AVPlayer rejected the 2 s live offset (`-12640`); real latency ≥ 6 s. | Harness | `TARGETDURATION` 1, offset 3 s. |
| D6 | Medium | Extension killed (50 MB limit) left status "live" forever. | Code review; confirmed on device (extension killed during reinstall → app correctly showed Off) | Playlist freshness check (5 s). |
| D7 | Medium | Encoder failure was silent. | Code review | Broadcast ends with an error, status → stopped. |
| D8 | Medium | Segment names reused across sessions + 60 s cache → stale video possible. | Code review | Per-session file names. |
| D9 | Medium | Audio session activated at launch stopped the user's music. | Code review | Activated on *Start screen mirroring*, released on stop. |
| D10 | Low | Instructions said "Start Broadcast"; iOS 27 sheet says **Start Sharing**. | UI-03 screenshot | Text mentions both. |
| D12 | Low | "Serve on local network" with no Wi-Fi/hotspot silently kept `127.0.0.1`. | UI-02 screenshot (phone on cellular) | Orange warning explains it needs Wi-Fi/hotspot; UI-02 now checks both cases. |
| D11 | Low | "Only watch while parked." footer drawn over the preview, unreadable. | UI-01 screenshot | Footer on its own bar. |

Also added: a **Player** readout under Advanced (state + position) for diagnosing displays.

## Not covered (manual)

| ID | Case | Why manual |
|---|---|---|
| MAN-02 | CarPlay head unit with AirPlay video | Needs a car |
| MAN-03 | Landscape orientation | Needs physical rotation before start |
| MAN-04 | Phone call interruption | Needs a call |
| — | Background runs longer than 20 s while AirPlaying | Only 20 s automated |

## Notes for the team
- Free Personal Team builds expire after 7 days; App Groups worked with the free team.
- Tests reinstall the app; a broadcast left running during reinstall triggers iOS's "invalid broadcast session" alert. The UI tests now always stop their broadcast and dismiss that alert.

- UI-06 (AirPlay) is opt-in: `TEST_RUNNER_AIRPLAY_TARGET="MacBook Air" xcodebuild test ...` (skipped otherwise).
