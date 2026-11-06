import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager.shared
    @StateObject private var location = LocationManager.shared

    @State private var showSettings = false
    @State private var showGallery = false

    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0) // #FF6700
    private let darkBg = Color(red: 0.05, green: 0.06, blue: 0.09)
    private let cardBg = Color(red: 0.10, green: 0.12, blue: 0.18)

    var body: some View {
        ZStack {
            darkBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. Barra Superior de Estado (Wi-Fi, Batería, GPS, Ajustes)
                topStatusBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Spacer()

                // 2. Área Central (Visor / Estado de la Cámara)
                centralViewfinder
                    .padding(.horizontal, 16)

                Spacer()

                // 3. Selector de Modo (Foto / Video)
                modeSelector
                    .padding(.bottom, 14)

                // 4. Barra de Ajustes Rápidos (EV, ISO, WB, Timer)
                if camera.isConnected && camera.currentMode == 1 {
                    quickSettingsBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }

                // 5. Barra Inferior con Botón Disparador Principal
                bottomActionBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            location.startTracking()
            camera.connect()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
    }

    // MARK: - Barra Superior de Estado

    private var topStatusBar: some View {
        HStack(spacing: 10) {
            // Estado de Conexión
            HStack(spacing: 6) {
                Circle()
                    .fill(camera.isConnected ? Color.green : (camera.isConnecting ? Color.orange : Color.red))
                    .frame(width: 8, height: 8)
                Text(camera.isConnected ? "Conectada" : (camera.isConnecting ? "Buscando..." : "Sin Wi-Fi"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(cardBg)
            .cornerRadius(20)

            // Estado de Batería
            if camera.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: camera.isCharging ? "battery.100.bolt" : "battery.75")
                        .foregroundColor(camera.isCharging ? .green : .white)
                    Text("\(camera.batteryPercent)%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(cardBg)
                .cornerRadius(20)
            }

            // Indicador de GPS en Tiempo Real (Camino A)
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .foregroundColor(location.hasLocation ? brandOrange : .gray)
                Text(location.hasLocation ? location.accuracyString : "GPS...")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(location.hasLocation ? brandOrange : .gray)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(cardBg)
            .cornerRadius(20)
            .onTapGesture {
                location.forceSyncGPSWithCamera()
            }

            Spacer()

            // Botón de Ajustes
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(cardBg)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Área Central

    private var centralViewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(cardBg)
                .frame(maxHeight: 380)

            if !camera.isConnected {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 54))
                        .foregroundColor(brandOrange)

                    Text("Conéctate al Wi-Fi de la Cámara")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Ve a Ajustes de tu iPhone > Wi-Fi y selecciona:\nMJXJ-010135")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 24)

                    Button {
                        camera.connect()
                    } label: {
                        Text(camera.isConnecting ? "Conectando..." : "Reintentar Conexión")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(brandOrange)
                            .cornerRadius(14)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.15, green: 0.18, blue: 0.26))
                            .frame(width: 130, height: 130)

                        Image(systemName: camera.currentMode == 1 ? "camera.metering.matrix" : "video.fill")
                            .font(.system(size: 50))
                            .foregroundColor(brandOrange)
                    }

                    Text(camera.currentMode == 1 ? "Modo Foto 360°" : (camera.isRecording ? "Grabando Video 3.5K" : "Modo Video 360°"))
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(camera.lastStatusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if location.hasLocation {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("GPS Satelital Activo (Inyección directa a EXIF)")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Selector de Modo

    private var modeSelector: some View {
        HStack(spacing: 24) {
            Button {
                camera.switchMode(1)
            } label: {
                Text("FOTO")
                    .font(.footnote)
                    .fontWeight(camera.currentMode == 1 ? .bold : .medium)
                    .foregroundColor(camera.currentMode == 1 ? brandOrange : .gray)
            }

            Button {
                camera.switchMode(0)
            } label: {
                Text("VIDEO")
                    .font(.footnote)
                    .fontWeight(camera.currentMode == 0 ? .bold : .medium)
                    .foregroundColor(camera.currentMode == 0 ? brandOrange : .gray)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(cardBg)
        .cornerRadius(18)
    }

    // MARK: - Barra de Ajustes Rápidos

    private var quickSettingsBar: some View {
        HStack(spacing: 8) {
            // EV
            Menu {
                ForEach([-2.0, -1.0, 0.0, 1.0, 2.0], id: \.self) { val in
                    Button(String(format: "%+.1f EV", val)) { camera.setEV(val) }
                }
            } label: {
                settingPill(title: "EV", value: String(format: "%+.1f", camera.ev))
            }

            // ISO
            Menu {
                ForEach([0, 50, 100, 200, 400, 800, 1600], id: \.self) { val in
                    Button(val == 0 ? "Auto" : "ISO \(val)") { camera.setISO(val) }
                }
            } label: {
                settingPill(title: "ISO", value: camera.iso == 0 ? "Auto" : "\(camera.iso)")
            }

            // Balance de Blancos
            Menu {
                Button("Auto") { camera.setWB(0) }
                Button("Exterior (Sol)") { camera.setWB(1) }
                Button("Nublado") { camera.setWB(2) }
                Button("Incandescente") { camera.setWB(3) }
                Button("Fluorescente") { camera.setWB(4) }
            } label: {
                settingPill(title: "WB", value: wbLabel(camera.wb))
            }

            // Temporizador
            Menu {
                Button("Sin Timer") { camera.setTimer(0) }
                Button("3 segs") { camera.setTimer(3) }
                Button("5 segs") { camera.setTimer(5) }
                Button("10 segs") { camera.setTimer(10) }
            } label: {
                settingPill(title: "Timer", value: camera.timer == 0 ? "0s" : "\(camera.timer)s")
            }
        }
    }

    private func settingPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(cardBg)
        .cornerRadius(10)
    }

    private func wbLabel(_ val: Int) -> String {
        switch val {
        case 1: return "Sol"
        case 2: return "Nube"
        case 3: return "Incand"
        case 4: return "Fluor"
        default: return "Auto"
        }
    }

    // MARK: - Barra Inferior con Botón Disparador

    private var bottomActionBar: some View {
        HStack {
            // Botón Galería (microSD)
            Button {
                showGallery = true
            } label: {
                Image(systemName: "photo.stack")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(cardBg)
                    .clipShape(Circle())
            }

            Spacer()

            // Botón de Disparo Principal
            Button {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()

                if camera.currentMode == 1 {
                    // Sincronizar GPS inmediatamente y disparar foto
                    location.forceSyncGPSWithCamera()
                    camera.takePhoto()
                } else {
                    camera.toggleVideoRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 76, height: 76)

                    if camera.currentMode == 1 {
                        Circle()
                            .fill(brandOrange)
                            .frame(width: 62, height: 62)
                    } else {
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 62, height: 62)
                        }
                    }
                }
            }

            Spacer()

            // Botón de Desconexión
            Button {
                if camera.isConnected {
                    camera.disconnect()
                } else {
                    camera.connect()
                }
            } label: {
                Image(systemName: camera.isConnected ? "link.circle.fill" : "arrow.clockwise")
                    .font(.system(size: 22))
                    .foregroundColor(camera.isConnected ? .green : .white)
                    .frame(width: 52, height: 52)
                    .background(cardBg)
                    .clipShape(Circle())
            }
        }
    }
}
