import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var mirror: MirrorController
    @StateObject private var launcher = BroadcastLauncher()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow("Screen broadcast", on: mirror.broadcastLive,
                              onText: "Live", offText: "Off")
                    statusRow("Car display", on: mirror.externalPlaybackActive,
                              onText: "Connected", offText: "Not connected")
                }

                Section("1. Choose your car display") {
                    HStack {
                        Text("AirPlay to car")
                        Spacer()
                        RoutePicker().frame(width: 44, height: 44)
                    }
                    Text("Connect to CarPlay first. The car must support AirPlay video (iOS 26+), and most only allow it while parked.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("2. Start mirroring") {
                    Button {
                        mirror.prepareForMirroring()
                        launcher.launch()
                    } label: {
                        Label(mirror.broadcastLive ? "Stop or change broadcast" : "Start screen mirroring",
                              systemImage: "rectangle.on.rectangle")
                    }
                    .accessibilityIdentifier("mirror.button")
                    Text("Pick CarMirror in the sheet, tap Start (\"Start Sharing\" or \"Start Broadcast\", depending on iOS), then switch to any app. Rotate the phone before starting if you want landscape.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Preview") {
                    // Kept small on purpose: showing the mirror on the phone itself
                    // would be captured again and create an infinite mirror.
                    PlayerLayerView(player: mirror.player)
                        .frame(height: 120)
                        .listRowInsets(EdgeInsets())
                        .overlay {
                            if mirror.externalPlaybackActive {
                                Text("Playing on car display").foregroundStyle(.white).font(.caption)
                            }
                        }
                }

                Section {
                    Toggle("Serve on local network", isOn: $mirror.useNetworkAddress)
                        .accessibilityIdentifier("advanced.toggle")
                    Text(mirror.streamURL.absoluteString)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("advanced.url")
                    if mirror.useNetworkAddress && NetworkInfo.localIPv4() == nil {
                        Text("No Wi-Fi or hotspot address. Join the same Wi-Fi as the display (or turn on Personal Hotspot) for this to work.")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("advanced.noNetwork")
                    }
                    LabeledContent("Player", value: mirror.playbackInfo)
                        .font(.caption)
                        .accessibilityIdentifier("advanced.playback")
                    if let error = mirror.serverError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("advanced.error")
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Turn this on only if the display won't play the localhost stream. Anyone on the same network can then view your screen.")
                }
            }
            .navigationTitle("CarMirror")
            .background(BroadcastPickerHost(launcher: launcher).frame(width: 0, height: 0))
            .background(alignment: .topLeading) {
                // AVPlayer won't start a video-only stream until a video output is ready.
                // The Preview row is lazily created by the List and is often off screen,
                // so keep one tiny, always-mounted layer as the guaranteed output.
                PlayerLayerView(player: mirror.player)
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .safeAreaInset(edge: .bottom) {
                Text("Only watch while parked.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(.bar)       // keep it readable instead of overlapping the preview
            }
        }
    }

    private func statusRow(_ title: String, on: Bool, onText: String, offText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(on ? onText : offText, systemImage: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
                .accessibilityIdentifier("status.\(title)")
        }
    }
}
