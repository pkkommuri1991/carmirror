import SwiftUI
import AVKit
import ReplayKit

/// System AirPlay picker (choose the car display).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.activeTintColor = .systemGreen
        view.tintColor = .label
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Holds a hidden RPSystemBroadcastPickerView so we can trigger it from our own button.
/// Starting a system broadcast always shows Apple's sheet; apps can't skip it.
final class BroadcastLauncher: ObservableObject {
    let picker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".Broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }()

    func launch() {
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .touchUpInside)
        }
    }
}

struct BroadcastPickerHost: UIViewRepresentable {
    let launcher: BroadcastLauncher
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.isHidden = true
        container.addSubview(launcher.picker)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// A real AVPlayerLayer gives AVFoundation a video destination to hand off to AirPlay.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ uiView: LayerView, context: Context) {}
}
