import SwiftUI

@main
struct MiSphereApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                CameraManager.shared.handleAppDidEnterBackground()
            case .active:
                CameraManager.shared.handleAppDidBecomeActive()
            default:
                break
            }
        }
    }
}
