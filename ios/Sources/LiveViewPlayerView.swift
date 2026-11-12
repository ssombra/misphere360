import SwiftUI
#if canImport(VLCKit)
import VLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

public struct LiveViewPlayerView: View {
    public let streamURL: URL

    public init(url: URL = URL(string: "rtsp://192.168.42.1/live")!) {
        self.streamURL = url
    }

    public var body: some View {
        ZStack {
            Color.black

            #if canImport(VLCKit) || canImport(MobileVLCKit)
            VLCPlayerRepresentable(url: streamURL)
            #else
            VStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white.opacity(0.7))
                Text("Visor en Vivo")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            #endif
        }
    }
}

#if canImport(VLCKit) || canImport(MobileVLCKit)
struct VLCPlayerRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> VLCStreamViewController {
        VLCStreamViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: VLCStreamViewController, context: Context) {
        // No tocar el reproductor en updateUIViewController para evitar reinicios infinitos del buffer
    }

    static func dismantleUIViewController(_ uiViewController: VLCStreamViewController, coordinator: ()) {
        uiViewController.stopPlayback()
    }
}

final class VLCStreamViewController: UIViewController, VLCMediaPlayerDelegate {
    let streamURL: URL
    private var player: VLCMediaPlayer?
    private var videoSurfaceView: UIView!

    // Elementos de Diagnóstico y Control en Pantalla
    private var statusContainer: UIStackView!
    private var spinner: UIActivityIndicatorView!
    private var statusLabel: UILabel!
    private var retryButton: UIButton!

    init(url: URL) {
        self.streamURL = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Superficie de video UIKit nativa con bordes redondeados
        videoSurfaceView = UIView(frame: view.bounds)
        videoSurfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoSurfaceView.backgroundColor = .black
        videoSurfaceView.layer.cornerRadius = 20
        videoSurfaceView.layer.masksToBounds = true
        view.addSubview(videoSurfaceView)

        setupDiagnosticOverlay()
        setupPlayer()
    }

    private func setupDiagnosticOverlay() {
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true

        statusLabel = UILabel()
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.text = "Iniciando reproductor..."

        retryButton = UIButton(type: .system)
        retryButton.setTitle(" Reintentar conexión", for: .normal)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.tintColor = .black
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        retryButton.backgroundColor = .white
        retryButton.layer.cornerRadius = 14
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(onRetryTapped), for: .touchUpInside)

        statusContainer = UIStackView(arrangedSubviews: [spinner, statusLabel, retryButton])
        statusContainer.axis = .vertical
        statusContainer.spacing = 8
        statusContainer.alignment = .center
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusContainer)

        NSLayoutConstraint.activate([
            statusContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupPlayer() {
        if let existing = player {
            existing.stop()
            existing.delegate = nil
            player = nil
        }

        let p = VLCMediaPlayer()
        p.delegate = self
        p.drawable = videoSurfaceView

        let media = VLCMedia(url: streamURL)
        // 1000ms de búfer seguro para descartar cortes prematuros y transporte RTSP sobre TCP probado
        media.addOptions([
            "network-caching": 1000,
            "rtsp-tcp": true
        ])
        p.media = media
        self.player = p
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if player == nil {
            setupPlayer()
        }
        if let player = self.player, !player.isPlaying {
            print("[VLC] viewDidAppear -> Iniciando reproducción de \(streamURL)")
            updateStatusUI(text: "Conectando con cámara...", showSpinner: true, showRetry: false)
            player.play()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
    }

    func stopPlayback() {
        if let player = self.player {
            print("[VLC] Deteniendo reproducción")
            if player.isPlaying {
                player.stop()
            }
        }
    }

    @objc private func onRetryTapped() {
        print("[VLC] Reintento manual solicitado por usuario")
        updateStatusUI(text: "Reintentando conexión...", showSpinner: true, showRetry: false)
        setupPlayer()
        player?.play()
    }

    private func updateStatusUI(text: String, showSpinner: Bool, showRetry: Bool, hideAfter: TimeInterval? = nil) {
        statusLabel.text = text
        if showSpinner {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        retryButton.isHidden = !showRetry
        statusContainer.isHidden = false

        if let delay = hideAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, let p = self.player, p.isPlaying else { return }
                UIView.animate(withDuration: 0.3) {
                    self.statusContainer.alpha = 0.0
                } completion: { _ in
                    self.statusContainer.isHidden = true
                    self.statusContainer.alpha = 1.0
                }
            }
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        guard let p = self.player else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[VLC] Cambio de estado: \(p.state.rawValue)")
            switch p.state {
            case .opening:
                self.updateStatusUI(text: "Abriendo RTSP...", showSpinner: true, showRetry: false)
            case .buffering:
                self.updateStatusUI(text: "Cargando búfer...", showSpinner: true, showRetry: false)
            case .playing:
                self.updateStatusUI(text: "En Vivo", showSpinner: false, showRetry: false, hideAfter: 2.0)
            case .paused:
                self.updateStatusUI(text: "Pausado", showSpinner: false, showRetry: true)
            case .stopped:
                self.updateStatusUI(text: "Detenido", showSpinner: false, showRetry: true)
            case .ended:
                self.updateStatusUI(text: "Transmisión finalizada", showSpinner: false, showRetry: true)
            case .error:
                self.updateStatusUI(text: "Error de conexión RTSP", showSpinner: false, showRetry: true)
            @unknown default:
                break
            }
        }
    }

    deinit {
        stopPlayback()
        player = nil
    }
}
#endif
