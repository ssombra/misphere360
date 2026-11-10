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

        setupPlayer()
    }

    private func setupPlayer() {
        let p = VLCMediaPlayer()
        p.delegate = self
        p.drawable = videoSurfaceView

        let media = VLCMedia(url: streamURL)
        // Opciones estándar compatibles con VLCKit (diccionario [AnyHashable: Any])
        media.addOptions([
            "network-caching": 300,
            "rtsp-tcp": true
        ])
        p.media = media
        self.player = p
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let player = self.player, !player.isPlaying {
            print("[VLC] Iniciando reproducción en vivo de \(streamURL)")
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
            self.player = nil
        }
    }

    deinit {
        stopPlayback()
    }
}
#endif
