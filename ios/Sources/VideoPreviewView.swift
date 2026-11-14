import SwiftUI
import AVFoundation
import CoreVideo
import MetalKit
import UIKit

/// Controlador de reproducción 360° para previsualizar videos MP4 directamente desde la cámara vía Metal.
final class VideoPreviewController: ObservableObject {
    let renderer = Metal360Renderer()

    @Published var isLoading: Bool = true
    @Published var isBuffering: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var errorMessage: String? = nil
    @Published var fileSizeBytes: Int64 = 0

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false

    func load(item: SDFileItem) {
        stopAndCleanup()
        isLoading = true
        errorMessage = nil
        currentTime = 0.0
        duration = 0.0

        // 1. Si ya está en la biblioteca Local, reproducir desde disco sin usar Wi-Fi
        if let localAsset = LocalLibraryManager.shared.asset(for: item) {
            self.fileSizeBytes = localAsset.fileSizeBytes
            self.startPlayer(with: LocalLibraryManager.shared.originalURL(for: localAsset))
            return
        }

        // 2. Streaming desde la cámara priorizando el proxy AB.MP4 si existe
        MediaDownloader.shared.resolveMediaURL(item: item, preferPreviewProxy: true) { [weak self] url, contentLength in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let url = url else {
                    self.isLoading = false
                    self.errorMessage = "No se encontró el archivo de video en la cámara. Comprueba la conexión Wi-Fi."
                    return
                }
                if let size = contentLength {
                    self.fileSizeBytes = size
                }
                self.startPlayer(with: url)
            }
        }
    }

    private func startPlayer(with url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        playerItem.add(output)
        self.videoOutput = output

        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.isMuted = isMuted
        self.player = avPlayer

        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    let dur = item.duration.seconds
                    if dur.isFinite && dur > 0 {
                        self.duration = dur
                    }
                    self.avPlay()
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "No se pudo reproducir el video."
                default:
                    break
                }
            }
        }

        bufferObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.isBuffering = !item.isPlaybackLikelyToKeepUp && (self?.isPlaying ?? false)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isPlaying = false
            self.player?.seek(to: .zero)
            self.currentTime = 0.0
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            let sec = time.seconds
            if sec.isFinite {
                self.currentTime = sec
            }
            if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                self.duration = dur
            }
        }

        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    @objc private func onDisplayLink(_ link: CADisplayLink) {
        guard let output = videoOutput, let player = player else { return }
        let hostTime = link.timestamp + link.duration
        let itemTime = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            renderer.updatePixelBuffer(pb)
        } else if player.timeControlStatus == .paused,
                  let currentItem = player.currentItem {
            let t = currentItem.currentTime()
            if output.hasNewPixelBuffer(forItemTime: t),
               let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                renderer.updatePixelBuffer(pb)
            }
        }
    }

    private func avPlay() {
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && currentTime >= duration - 0.1 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func beginSeeking() {
        isSeeking = true
    }

    func seek(to seconds: Double, finish: Bool) {
        currentTime = seconds
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            if finish {
                DispatchQueue.main.async {
                    self?.isSeeking = false
                }
            }
        }
    }

    func stopAndCleanup() {
        displayLink?.invalidate()
        displayLink = nil

        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil

        statusObserver?.invalidate()
        statusObserver = nil
        bufferObserver?.invalidate()
        bufferObserver = nil

        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
        endObserver = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoOutput = nil
        isPlaying = false
    }

    deinit {
        stopAndCleanup()
    }
}

/// Vista completa de previsualización 360° interactiva para videos en la microSD.
struct VideoPreviewView: View {
    let item: SDFileItem
    var onDownloadRequested: ((StitchMode) -> Void)?
    var onDeleteRequested: (() -> Void)?

    @Environment(\.dismiss) var dismiss
    @StateObject private var controller = VideoPreviewController()
    @ObservedObject private var localLibrary = LocalLibraryManager.shared
    @ObservedObject private var downloader = MediaDownloader.shared
    @State private var showUIControls = true
    @State private var projectionMode: PhotoProjectionMode = .normal
    @State private var showDeleteConfirm = false
    @State private var showInfoSheet = false
    @State private var localSaveMessage: String? = nil
    @State private var showLocalSaveAlert = false

    private let brandOrange = Color(red: 1.0, green: 0.42, blue: 0.0)

    private var formattedFileSize: String {
        if controller.fileSizeBytes > 0 {
            let bcf = ByteCountFormatter()
            bcf.allowedUnits = [.useGB, .useMB, .useKB]
            bcf.countStyle = .file
            return bcf.string(fromByteCount: controller.fileSizeBytes)
        }
        return "Video MP4"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Visor Metal 360° interactivo
            Metal360ViewRepresentable(renderer: controller.renderer)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showUIControls.toggle()
                    }
                }

            // Indicador de carga inicial o buffering
            if controller.isLoading || controller.isBuffering {
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.4)
                    Text(controller.isLoading ? "Conectando video 360°..." : "Almacenando en búfer...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(22)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .allowsHitTesting(false)
            } else if let err = controller.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.body)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Reintentar") {
                        controller.load(item: item)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }

            // Controles superpuestos (unificados con PhotoPreviewView)
            if showUIControls {
                VStack {
                    // Barra superior
                    HStack {
                        Button {
                            controller.stopAndCleanup()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
                        }

                        Spacer()

                        VStack(spacing: 2) {
                            Text(item.filename)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                            Text(controller.duration > 0 ? "\(formatTime(controller.duration)) · \(formattedFileSize)" : formattedFileSize)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.75))
                        }

                        Spacer()

                        Color.clear.frame(width: 42, height: 42)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    Spacer()

                    // Barra inferior: reproducción + 4 botones flotantes
                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            Button {
                                controller.togglePlayPause()
                            } label: {
                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                            }

                            Text(formatTime(controller.currentTime))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white.opacity(0.9))

                            Slider(
                                value: Binding(
                                    get: { controller.currentTime },
                                    set: { newVal in controller.seek(to: newVal, finish: false) }
                                ),
                                in: 0...max(controller.duration, 1.0),
                                onEditingChanged: { editing in
                                    if editing {
                                        controller.beginSeeking()
                                    } else {
                                        controller.seek(to: controller.currentTime, finish: true)
                                    }
                                }
                            )
                            .tint(brandOrange)

                            Text(formatTime(controller.duration))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white.opacity(0.75))

                            Button {
                                controller.toggleMute()
                            } label: {
                                Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .background(Color.black.opacity(0.45))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)

                        HStack(spacing: 22) {
                            // 1. Borrar con confirmación
                            Button {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(width: 50, height: 50)
                                    .background(.ultraThinMaterial)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            }

                            // 2. Información del video ("i")
                            Button {
                                showInfoSheet = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(.ultraThinMaterial)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            }

                            // 3. Descarga / Guardar
                            Menu {
                                if !localLibrary.isDownloaded(item) {
                                    Button {
                                        downloader.downloadToLocalLibrary(item: item) { _, msg in
                                            localSaveMessage = msg
                                            showLocalSaveAlert = true
                                        }
                                    } label: {
                                        Label("Guardar en Local (App)", systemImage: "iphone.and.arrow.forward")
                                    }
                                } else {
                                    Label("Ya guardado en Local", systemImage: "checkmark.circle.fill")
                                }

                                Divider()

                                Section("Exportar a Apple Fotos") {
                                    ForEach(StitchMode.allCases) { mode in
                                        Button {
                                            onDownloadRequested?(mode)
                                        } label: {
                                            Label(mode.title, systemImage: mode.systemImage)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(.ultraThinMaterial)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            }

                            // 4. Modo de proyección 360°
                            Menu {
                                Section("Modo de visualización") {
                                    ForEach(PhotoProjectionMode.allCases) { mode in
                                        Button {
                                            let impact = UIImpactFeedbackGenerator(style: .light)
                                            impact.impactOccurred()
                                            projectionMode = mode
                                            controller.renderer.projectionMode = mode
                                        } label: {
                                            if projectionMode == mode {
                                                Label(mode.rawValue, systemImage: "checkmark")
                                            } else {
                                                Label(mode.rawValue, systemImage: mode.systemImage)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: projectionMode.systemImage)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(projectionMode == .normal ? .white : brandOrange)
                                    .frame(width: 50, height: 50)
                                    .background(.ultraThinMaterial)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().stroke(
                                            projectionMode == .normal ? Color.white.opacity(0.18) : brandOrange.opacity(0.6),
                                            lineWidth: projectionMode == .normal ? 0.5 : 1.0
                                        )
                                    )
                                    .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }

            if downloader.isDownloading {
                Color.black.opacity(0.65).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                    Text(downloader.statusMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
        }
        .statusBar(hidden: !showUIControls)
        .onAppear {
            controller.load(item: item)
        }
        .onDisappear {
            controller.stopAndCleanup()
        }
        .alert("Biblioteca Local", isPresented: $showLocalSaveAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(localSaveMessage ?? "")
        }
        .alert("¿Eliminar archivo de la microSD?", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                controller.stopAndCleanup()
                onDeleteRequested?()
                dismiss()
            }
        } message: {
            Text("Esta acción borrará permanentemente \(item.filename) de la tarjeta de memoria.")
        }
        .sheet(isPresented: $showInfoSheet) {
            PhotoInfoSheetView(item: item, fileSizeFormatted: formattedFileSize)
        }
    }
}
