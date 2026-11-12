import SwiftUI
import AVFoundation

@main
struct MiSphereApp: App {
    init() {
        // Inicializar AVAudioSession para habilitar decodificación y reloj de libVLC
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[Audio] Falló configuración de AVAudioSession: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
