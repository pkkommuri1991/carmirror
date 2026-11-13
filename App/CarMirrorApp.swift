import SwiftUI

@main
struct CarMirrorApp: App {
    @StateObject private var mirror = MirrorController()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(mirror)
        }
    }
}
