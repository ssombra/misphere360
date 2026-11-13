import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager.shared
    @StateObject private var location = LocationManager.shared

    @State private var showSettings = false
    @State private var showGallery = false

    @State private var latestPhotoItem: SDFileItem? = nil
    @State private var latestStitchedImage: UIImage? = nil
    @State private var isLoadingLatestPhoto = false
    @State private var latestPhotoStatus = "Cargando captura 360°..."
    @State private var loadErrorMessage: String? = nil
    @State private var selectedPreviewItem: SDFileItem? = nil

    enum ViewfinderMode: String, CaseIterable {
        case off = "Off"
        case photo = "Foto 360°"
        case live = "En Vivo"
    }
    @State private var viewfinderMode: ViewfinderMode = .off
    @ObservedObject private var rtspPlayer = NativeRTSPPlayer.shared

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
                    .padding(.bottom, 10)

                Spacer(minLength: 4)

                // 2. Área Central (Estado de la Cámara y Parámetros Activos)
                centralViewfinder
                    .padding(.horizontal, 16)

                Spacer(minLength: 4)

                // 3. Selector de Modo Principal (FOTO vs VIDEO)
                modeSelector
                    .padding(.bottom, 10)

                // 4. Panel Completo de Ajustes de la Cámara
                if camera.isConnected {
                    if camera.currentMode == 1 {
                        photoControlsPanel
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } else {
                        videoControlsPanel
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }

                // 5. Barra Inferior con Botón Disparador Principal
                bottomActionBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            location.startTracking()
            camera.checkAndReconnectIfNeeded()
            if camera.isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    loadLatestPhoto()
                }
            }
        }
        .onChange(of: camera.isConnected) { isConnected in
            if isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    loadLatestPhoto()
                }
            } else {
                rtspPlayer.stopStream()
            }
        }
        .onChange(of: viewfinderMode) { mode in
            if mode != .live {
                rtspPlayer.stopStream()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            rtspPlayer.stopStream()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CameraPhotoSavedNotification"))) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                loadLatestPhoto(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            camera.checkAndReconnectIfNeeded()
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            camera.checkAndReconnectIfNeeded()
        }) {
            SettingsView()
        }
        .sheet(isPresented: $showGallery, onDismiss: {
            camera.checkAndReconnectIfNeeded()
            loadLatestPhoto(force: true)
        }) {
            GalleryView()
        }
        .fullScreenCover(item: $selectedPreviewItem) { item in
            PhotoPreviewView(item: item, initialImage: latestStitchedImage)
        }
    }

    // MARK: - Barra Superior de Estado (Limpia y Monocromática)

    private var topStatusBar: some View {
        HStack(spacing: 8) {
            // Estado de Conexión
            HStack(spacing: 6) {
                Circle()
                    .fill(camera.isConnected ? Color.green : (camera.isConnecting ? Color.orange : Color.gray))
                    .frame(width: 7, height: 7)
                Text(camera.isConnected ? "Conectada" : (camera.isConnecting ? "Buscando..." : "Sin Wi-Fi"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())

            // Estado de Batería
            if camera.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: camera.isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: 13))
                        .foregroundColor(camera.isCharging ? .green : .white)
                    Text("\(camera.batteryPercent)%")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
            }

            Spacer()

            // Botón de Ajustes (Círculo translúcido blanco)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Área Central (Live View Bajo Demanda)

    private var centralViewfinder: some View {
        ZStack {
            if !camera.isConnected {
                VStack(spacing: 14) {
                    if camera.isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.3)

                        Text("Enlazando con la cámara...")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Verificando Wi-Fi MJXJ-010135...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundColor(.white.opacity(0.85))

                        Text("Conéctate al Wi-Fi de la Cámara")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Ajustes de tu iPhone > Wi-Fi:\nMJXJ-010135")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)

                        Button {
                            camera.connect()
                        } label: {
                            Text("Reintentar Conexión")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 9)
                                .background(Color.white)
                                .cornerRadius(12)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.06))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            } else {
                // Zona Central: Visor 360° Interactivo, Visor en Vivo RTSP o Apagado (Off)
                ZStack {
                    if viewfinderMode == .off {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundColor(.white.opacity(0.35))
                                Text("Visor desactivado")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.65))
                                Text("Selecciona 'Foto 360°' o 'En Vivo' para activar")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.35))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)

                            // Cabecera flotante
                            HStack {
                                modeSwitchPill
                                Spacer()
                            }
                            .padding(10)
                        }
                    } else if viewfinderMode == .live {
                        ZStack(alignment: .topLeading) {
                            LiveViewPlayerView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 200)
                                .cornerRadius(20)
                                .clipped()

                            // Cabecera flotante
                            HStack {
                                modeSwitchPill

                                Spacer()

                                if rtspPlayer.isPlaying {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                        Text(rtspPlayer.fps > 0 ? "LIVE \(String(format: "%.0f", rtspPlayer.fps)) FPS" : "LIVE")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(.green)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .background(Color.black.opacity(0.50))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().stroke(Color.green.opacity(0.40), lineWidth: 0.5)
                                    )
                                }
                            }
                            .padding(10)
                        }
                    } else if let image = latestStitchedImage {
                        ZStack(alignment: .topLeading) {
                            Web360Viewer(image: image, enableMotion: false)
                                .frame(maxWidth: .infinity)
                                .frame(height: 200)
                                .cornerRadius(20)
                                .clipped()

                            // Cabecera flotante: Selector de modo y botones de acción
                            HStack {
                                modeSwitchPill

                                Spacer()

                                // Expandir a pantalla completa
                                if let item = latestPhotoItem {
                                    Button {
                                        let impact = UIImpactFeedbackGenerator(style: .medium)
                                        impact.impactOccurred()
                                        selectedPreviewItem = item
                                    } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 28, height: 28)
                                            .background(.ultraThinMaterial)
                                            .background(Color.black.opacity(0.40))
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                            )
                                    }
                                }

                                // Recargar última captura
                                Button {
                                    let impact = UIImpactFeedbackGenerator(style: .light)
                                    impact.impactOccurred()
                                    loadLatestPhoto(force: true)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 28, height: 28)
                                        .background(.ultraThinMaterial)
                                        .background(Color.black.opacity(0.40))
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                        )
                                }
                            }
                            .padding(10)

                            // Pie flotante con sugerencia de gesto
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text("Arrastra para explorar en 360°")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.70))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.45))
                                        .cornerRadius(6)
                                    Spacer()
                                }
                                .padding(.bottom, 8)
                            }
                        }
                    } else if isLoadingLatestPhoto {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 10) {
                                Spacer()
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.2)
                                Text(latestPhotoStatus)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)

                            HStack {
                                modeSwitchPill
                                Spacer()
                            }
                            .padding(10)
                        }
                    } else {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundColor(.white.opacity(0.65))

                                Text("Visor 360° de Última Captura")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)

                                if let err = loadErrorMessage {
                                    Text(err)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.orange)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 20)
                                } else {
                                    Text("Dispara una foto o pulsa cargar para explorar aquí en 360°")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.60))
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                }

                                Button {
                                    let impact = UIImpactFeedbackGenerator(style: .medium)
                                    impact.impactOccurred()
                                    loadLatestPhoto(force: true)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Cargar última foto")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                                }
                                .padding(.top, 4)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)

                            HStack {
                                modeSwitchPill
                                Spacer()
                            }
                            .padding(10)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(.ultraThinMaterial)
                .background(Color.white.opacity(0.06))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Selector de Modo del Visor Central

    private var modeSwitchPill: some View {
        HStack(spacing: 4) {
            ForEach(ViewfinderMode.allCases, id: \.self) { mode in
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    viewfinderMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: viewfinderMode == mode ? .bold : .medium))
                        .foregroundColor(viewfinderMode == mode ? .black : .white.opacity(0.70))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(viewfinderMode == mode ? Color.white : Color.clear)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.40))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Selector de Modo (Íconos Foto y Video)

    private var modeSelector: some View {
        HStack(spacing: 8) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                camera.switchMode(1)
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(camera.currentMode == 1 ? .black : .white.opacity(0.65))
                    .frame(width: 38, height: 38)
                    .background(camera.currentMode == 1 ? Color.white : Color.clear)
                    .clipShape(Circle())
            }

            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                camera.switchMode(0)
            } label: {
                Image(systemName: "video.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(camera.currentMode == 0 ? .black : .white.opacity(0.65))
                    .frame(width: 38, height: 38)
                    .background(camera.currentMode == 0 ? Color.white : Color.clear)
                    .clipShape(Circle())
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.10))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Controles de FOTO

    private var photoControlsPanel: some View {
        VStack(spacing: 8) {
            // Fila 1: Resolución y Sub-Modo (Timer, Intervalo, HDR)
            HStack(spacing: 8) {
                // Resolución de Foto
                Menu {
                    Button("Dual Fisheye (6912×3456)") { camera.setPhotoResolution(0) }
                    Button("Cosido 360° (3456×1728)") { camera.setPhotoResolution(1) }
                    Button("Cosido 360° (6912×3456)") { camera.setPhotoResolution(2) }
                    Button("6912×3456 + RAW (.DNG)") { camera.setPhotoResolution(3) }
                } label: {
                    settingPill(title: "RESOLUCIÓN", value: photoResLabel(camera.photoRes))
                }

                // Sub-modo / Temporizador
                Menu {
                    Button("Sin Temporizador") { camera.setTimer(0) }
                    Button("3 segundos") { camera.setTimer(3) }
                    Button("5 segundos") { camera.setTimer(5) }
                    Button("10 segundos") { camera.setTimer(10) }
                } label: {
                    settingPill(title: "TIMER", value: camera.timer == 0 ? "Off" : "\(camera.timer)s")
                }

                // Intervalo / Timelapse Foto
                Menu {
                    Button("Sin Intervalo") { camera.setPhotoInterval(0) }
                    Button("2 segundos") { camera.setPhotoInterval(2) }
                    Button("5 segundos") { camera.setPhotoInterval(5) }
                    Button("10 segundos") { camera.setPhotoInterval(10) }
                    Button("30 segundos") { camera.setPhotoInterval(30) }
                    Button("60 segundos") { camera.setPhotoInterval(60) }
                } label: {
                    settingPill(title: "INTERVALO", value: camera.photoInterval == 0 ? "Off" : "\(camera.photoInterval)s")
                }

                // Horquillado HDR
                Menu {
                    Button("Desactivado") { camera.setPhotoBracketing(0) }
                    Button("±1.0 EV") { camera.setPhotoBracketing(2) }
                    Button("±2.0 EV") { camera.setPhotoBracketing(4) }
                    Button("±3.0 EV") { camera.setPhotoBracketing(6) }
                } label: {
                    settingPill(title: "HDR", value: camera.photoBracketing == 0 ? "Off" : "±\(Double(camera.photoBracketing)/2.0)EV")
                }
            }

            // Fila 2: Exposición Manual (EV, ISO, Shutter, WB)
            HStack(spacing: 8) {
                // EV
                Menu {
                    ForEach([-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0], id: \.self) { val in
                        Button(String(format: "%+.1f EV", val)) { camera.setEV(val) }
                    }
                } label: {
                    settingPill(title: "EV", value: String(format: "%+.1f", camera.ev))
                }

                // ISO
                Menu {
                    Button("Auto") { camera.setISO(0) }
                    ForEach([50, 100, 200, 400, 800, 1600], id: \.self) { val in
                        Button("ISO \(val)") { camera.setISO(val) }
                    }
                } label: {
                    settingPill(title: "ISO", value: camera.iso == 0 ? "Auto" : "\(camera.iso)")
                }

                // Velocidad Shutter
                Menu {
                    Button("Auto") { camera.setShutter(0, label: "Auto") }
                    Button("1/6400") { camera.setShutter(32768 + 6400, label: "1/6400") }
                    Button("1/2000") { camera.setShutter(32768 + 2000, label: "1/2000") }
                    Button("1/1000") { camera.setShutter(32768 + 1000, label: "1/1000") }
                    Button("1/500") { camera.setShutter(32768 + 500, label: "1/500") }
                    Button("1/120") { camera.setShutter(32768 + 120, label: "1/120") }
                    Button("1/60") { camera.setShutter(32768 + 60, label: "1/60") }
                    Button("1/30") { camera.setShutter(32768 + 30, label: "1/30") }
                    Button("1s") { camera.setShutter(1, label: "1s") }
                    Button("2s") { camera.setShutter(2, label: "2s") }
                    Button("4s") { camera.setShutter(4, label: "4s") }
                    Button("8s") { camera.setShutter(8, label: "8s") }
                    Button("16s") { camera.setShutter(16, label: "16s") }
                    Button("32s") { camera.setShutter(32, label: "32s") }
                } label: {
                    settingPill(title: "SHUTTER", value: camera.shutter)
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
            }
        }
    }

    // MARK: - Controles de VIDEO

    private var videoControlsPanel: some View {
        VStack(spacing: 8) {
            // Fila 1: Resolución y Sub-Modos de Video
            HStack(spacing: 8) {
                // Resolución de Video
                Menu {
                    Button("3456×1728 | 30 fps (3.5K)") { camera.setVideoResolution(0) }
                    Button("2304×1152 | 60 fps") { camera.setVideoResolution(2) }
                    Button("2304×1152 | 30 fps (2.3K)") { camera.setVideoResolution(1) }
                    Button("2048×512 | 120 fps (Cámara Lenta)") { camera.setVideoResolution(7) }
                    Button("2048×512 | 120 fps (Bullet Time)") { camera.setVideoResolution(9) }
                    Button("3456×1728 | 30 fps (Alto Bitrate)") { camera.setVideoResolution(10) }
                } label: {
                    settingPill(title: "RESOLUCIÓN", value: videoResLabel(camera.videoRes))
                }

                // Video Corto
                Menu {
                    Button("Desactivado") { camera.setVideoShort(0) }
                    Button("10 segundos") { camera.setVideoShort(10) }
                    Button("20 segundos") { camera.setVideoShort(20) }
                    Button("30 segundos") { camera.setVideoShort(30) }
                } label: {
                    settingPill(title: "CORTO", value: camera.videoShort == 0 ? "Off" : "\(camera.videoShort)s")
                }

                // Timelapse Video
                Menu {
                    Button("Desactivado") { camera.setVideoTimelapse(0) }
                    Button("0.5s") { camera.setVideoTimelapse(255) }
                    Button("1s") { camera.setVideoTimelapse(1) }
                    Button("2s") { camera.setVideoTimelapse(2) }
                    Button("5s") { camera.setVideoTimelapse(5) }
                    Button("10s") { camera.setVideoTimelapse(10) }
                    Button("30s") { camera.setVideoTimelapse(30) }
                } label: {
                    settingPill(title: "TIMELAPSE", value: camera.videoTimelapse == 0 ? "Off" : (camera.videoTimelapse == 255 ? "0.5s" : "\(camera.videoTimelapse)s"))
                }

                // Cámara Lenta 2x
                Menu {
                    Button("Velocidad Normal") { camera.setVideoSlowMo(0) }
                    Button("Cámara Lenta (2x)") { camera.setVideoSlowMo(1) }
                } label: {
                    settingPill(title: "SLOWMO", value: camera.videoSlowMo == 1 ? "2x" : "Off")
                }
            }

            // Fila 2: EV y WB de Video
            HStack(spacing: 8) {
                Menu {
                    ForEach([-3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0], id: \.self) { val in
                        Button(String(format: "%+.1f EV", val)) { camera.setVideoEV(val) }
                    }
                } label: {
                    settingPill(title: "EV VIDEO", value: String(format: "%+.1f", camera.videoEV))
                }

                Menu {
                    Button("Auto") { camera.setVideoWB(0) }
                    Button("Exterior (Sol)") { camera.setVideoWB(1) }
                    Button("Nublado") { camera.setVideoWB(2) }
                    Button("Incandescente") { camera.setVideoWB(3) }
                    Button("Fluorescente") { camera.setVideoWB(4) }
                } label: {
                    settingPill(title: "WB VIDEO", value: wbLabel(camera.videoWB))
                }
            }
        }
    }

    private func settingPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func photoResLabel(_ val: Int) -> String {
        switch val {
        case 1: return "3.5K Cosido"
        case 2: return "6.9K Cosido"
        case 3: return "RAW DNG"
        default: return "Dual Fisheye"
        }
    }

    private func videoResLabel(_ val: Int) -> String {
        switch val {
        case 1: return "2.3K 30fps"
        case 2: return "2.3K 60fps"
        case 7: return "120fps Slow"
        case 9: return "Bullet Time"
        case 10: return "3.5K AltoBit"
        default: return "3.5K 30fps"
        }
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

    // MARK: - Barra Inferior con Botón Disparador (Minimalista Monocromático)

    private var bottomActionBar: some View {
        HStack {
            // Botón Galería (microSD)
            Button {
                showGallery = true
            } label: {
                Image(systemName: "photo.stack")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            }

            Spacer()

            // Botón de Disparo Principal (Estilo Clásico Cámara Apple)
            Button {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()

                if camera.currentMode == 1 {
                    location.forceSyncGPSWithCamera()
                    camera.takePhoto()
                    // Esperar a que la cámara guarde el archivo en la microSD para actualizar el visor 360
                    let delay: Double = camera.timer > 0 ? Double(camera.timer) + 2.5 : 2.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        loadLatestPhoto(force: true)
                    }
                } else {
                    camera.toggleVideoRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3.5)
                        .frame(width: 76, height: 76)

                    if camera.currentMode == 1 {
                        // Foto: Círculo blanco puro sólido
                        Circle()
                            .fill(Color.white)
                            .frame(width: 62, height: 62)
                    } else {
                        // Video: Círculo o cuadrado rojo de grabación estándar
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

            // Botón de Reconexión / Refresco
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                if camera.isConnected {
                    camera.refreshStatus()
                } else {
                    camera.connect()
                }
            } label: {
                Image(systemName: camera.isConnected ? "arrow.clockwise" : "link.badge.plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: - Carga y Cosido de la Última Captura 360° para el Visor Central

    private func previewCacheURL(for item: SDFileItem) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let safe = "\(item.folder)_\(item.filename)".replacingOccurrences(of: "/", with: "_")
        return caches.appendingPathComponent("\(safe)_preview.jpg")
    }

    private func loadLatestPhoto(force: Bool = false) {
        guard camera.isConnected, !isLoadingLatestPhoto else { return }
        isLoadingLatestPhoto = true
        loadErrorMessage = nil
        latestPhotoStatus = "Buscando última captura..."

        camera.fetchLatestPhotoItem { photoItem in
            guard let mostRecent = photoItem else {
                DispatchQueue.main.async {
                    self.isLoadingLatestPhoto = false
                    self.loadErrorMessage = "No se encontraron fotos en la microSD."
                }
                return
            }

            // 1. Si ya está cargada en memoria y no se forzó refresco, terminar de inmediato
            if !force && self.latestPhotoItem?.id == mostRecent.id && self.latestStitchedImage != nil {
                DispatchQueue.main.async {
                    self.isLoadingLatestPhoto = false
                }
                return
            }

            // 2. Si ya está guardada en la caché local del dispositivo, cargarla en milisegundos sin red
            let cacheFile = self.previewCacheURL(for: mostRecent)
            if !force, let cachedData = try? Data(contentsOf: cacheFile), let cachedImg = UIImage(data: cachedData) {
                DispatchQueue.main.async {
                    self.latestPhotoItem = mostRecent
                    self.latestStitchedImage = cachedImg
                    self.isLoadingLatestPhoto = false
                }
                return
            }

            DispatchQueue.main.async {
                self.latestPhotoItem = mostRecent
                self.latestPhotoStatus = "Descargando \(mostRecent.filename)..."
            }

            MediaDownloader.shared.downloadToTemporaryFile(item: mostRecent) { localURL in
                guard let localURL = localURL else {
                    DispatchQueue.main.async {
                        self.isLoadingLatestPhoto = false
                        self.loadErrorMessage = "No se pudo descargar \(mostRecent.filename) de la cámara."
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.latestPhotoStatus = "Generando proyección 360°..."
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let stitched = PhotoStitcher.shared.stitchForInteractivePreview(from: localURL, maxPixelSize: 1536)
                    try? FileManager.default.removeItem(at: localURL)

                    DispatchQueue.main.async {
                        if let stitched = stitched {
                            if let data = stitched.jpegData(compressionQuality: 0.85) {
                                try? data.write(to: cacheFile)
                            }
                            self.latestStitchedImage = stitched
                            self.loadErrorMessage = nil
                        } else {
                            self.loadErrorMessage = "Error al procesar panorama 360°"
                        }
                        self.isLoadingLatestPhoto = false
                    }
                }
            }
        }
    }
}
