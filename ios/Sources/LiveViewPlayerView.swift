import SwiftUI
#if canImport(VLCKit)
import VLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

public struct LiveViewPlayerView: View {
    public let streamURL: URL
    public let cachingMs: Int

    public init(url: URL = URL(string: "rtsp://192.168.42.1/live")!, cachingMs: Int = 500) {
        self.streamURL = url
        self.cachingMs = cachingMs
    }

    public var body: some View {
        ZStack {
            Color.black

            #if canImport(VLCKit) || canImport(MobileVLCKit)
            VLCPlayerRepresentable(url: streamURL, cachingMs: cachingMs)
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
    let cachingMs: Int

    func makeUIViewController(context: Context) -> VLCStreamViewController {
        VLCStreamViewController(url: url, cachingMs: cachingMs)
    }

    func updateUIViewController(_ uiViewController: VLCStreamViewController, context: Context) {
        if uiViewController.cachingMs != cachingMs {
            print("[VLC] Actualizando búfer de red en caliente a \(cachingMs) ms")
            uiViewController.updateCachingAndReload(cachingMs)
        }
    }

    static func dismantleUIViewController(_ uiViewController: VLCStreamViewController, coordinator: ()) {
        uiViewController.stopPlayback()
    }
}

final class VLCStreamViewController: UIViewController {
    let streamURL: URL
    var cachingMs: Int
    private var player: VLCMediaPlayer?
    private var videoSurfaceView: UIView!

    init(url: URL, cachingMs: Int = 500) {
        self.streamURL = url
        self.cachingMs = cachingMs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Superficie de renderizado UIKit con esquinas redondeadas
        videoSurfaceView = UIView(frame: view.bounds)
        videoSurfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoSurfaceView.backgroundColor = .black
        videoSurfaceView.layer.cornerRadius = 20
        videoSurfaceView.layer.masksToBounds = true
        view.addSubview(videoSurfaceView)

        setupPlayer()
    }

    private func setupPlayer() {
        if let existing = player {
            existing.stop()
            player = nil
        }

        let p = VLCMediaPlayer()
        p.drawable = videoSurfaceView

        let media = VLCMedia(url: streamURL)
        media.addOptions([
            "rtsp-tcp": true,
            "network-caching": cachingMs,
            "drop-late-frames": true,
            "skip-frames": true,
            "avcodec-hw": "any"
        ])
        p.media = media
        self.player = p
    }

    func updateCachingAndReload(_ newMs: Int) {
        self.cachingMs = newMs
        setupPlayer()
        player?.play()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if player == nil {
            setupPlayer()
        }
        if let p = player, !p.isPlaying {
            print("[VLC] Iniciando reproducción directa de \(streamURL)")
            p.play()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPlayback()
    }

    func stopPlayback() {
        if let p = player {
            print("[VLC] Deteniendo reproducción")
            if p.isPlaying {
                p.stop()
            }
        }
    }

    deinit {
        stopPlayback()
        player = nil
    }
}
#endif
