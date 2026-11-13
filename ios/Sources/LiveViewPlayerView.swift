import SwiftUI
import AVFoundation

/// Vista SwiftUI que contiene el reproductor RTSP nativo acelerado por hardware (VideoToolbox)
public struct LiveViewPlayerView: View {
    @ObservedObject private var player = NativeRTSPPlayer.shared

    public init() {}

    public var body: some View {
        ZStack {
            Color.black

            NativeVideoViewRepresentable()

            // Indicador de conexión / cargando
            if player.isConnecting && !player.isPlaying {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)

                    Text("Iniciando visor nativo (VideoToolbox)...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.70))
            }

            // Mensaje de error con botón de reintento
            if let error = player.errorMessage, !player.isPlaying {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)

                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    Button {
                        player.startStream()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text("Reintentar")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.80))
            }
        }
        .onAppear {
            player.startStream()
        }
        .onDisappear {
            player.stopStream()
        }
    }
}

// MARK: - Puente UIViewRepresentable con AVSampleBufferDisplayLayer

struct NativeVideoViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        NativeRTSPPlayer.shared.startStream(to: view.sampleBufferDisplayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferVideoView, context: Context) {
        // No es necesario actualizar nada continuamente; AVSampleBufferDisplayLayer se redibuja vía GPU
    }

    static func dismantleUIView(_ uiView: SampleBufferVideoView, coordinator: ()) {
        NativeRTSPPlayer.shared.stopStream()
    }
}

final class SampleBufferVideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .black
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        sampleBufferDisplayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }
}
