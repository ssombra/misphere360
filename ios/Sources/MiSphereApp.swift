import SwiftUI
import AVFoundation

@main
struct MiSphereApp: App {
    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            print("[Audio] AVAudioSession configurado en modo playback exitosamente")
        } catch {
            print("[Audio] Error al configurar AVAudioSession: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
