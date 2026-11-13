import SwiftUI
import MetalKit
import AVFoundation

/// Vista SwiftUI que contiene el visor Metal 360° con cosido óptico en tiempo real por GPU.
public struct LiveViewPlayerView: View {
    @ObservedObject private var player = NativeRTSPPlayer.shared
    @ObservedObject private var renderer = Metal360Renderer.shared

    public init() {}

    public var body: some View {
        ZStack {
            Color.black

            // Vista Metal interactiva con cosido óptico
            Metal360ViewRepresentable()

            // Indicador de conexión / cargando
            if player.isConnecting && !player.isPlaying {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)

                    Text("Iniciando cosido óptico GPU (Metal)...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.70))
                .allowsHitTesting(false)
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

            // Selector flotante de formato de visualización (360° / Panorama / Fisheye)
            if player.isPlaying {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if !renderer.isExpanded {
                            // Selector de proyección (solo en modo compacto)
                            HStack(spacing: 2) {
                                ForEach(Metal360Renderer.DisplayMode.allCases) { m in
                                    Button {
                                        let impact = UIImpactFeedbackGenerator(style: .light)
                                        impact.impactOccurred()
                                        renderer.mode = m
                                    } label: {
                                        Text(m.title)
                                            .font(.system(size: 9.5, weight: renderer.mode == m ? .bold : .medium))
                                            .foregroundColor(renderer.mode == m ? .black : .white.opacity(0.75))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(renderer.mode == m ? Color.white : Color.clear)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(2)
                            .background(.ultraThinMaterial)
                            .background(Color.black.opacity(0.50))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                            )
                        }

                        Spacer()

                        // Botón de Expansión / Reducción del visor
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .medium)
                            impact.impactOccurred()
                            withAnimation(.easeInOut(duration: 0.25)) {
                                renderer.isExpanded.toggle()
                                if renderer.isExpanded {
                                    renderer.mode = .interactive360
                                }
                            }
                        } label: {
                            Image(systemName: renderer.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.50))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
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

// MARK: - Puente UIViewRepresentable con MTKView (Metal)

struct Metal360ViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = Metal360Renderer.shared
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.contentScaleFactor = min(UIScreen.main.scale, 2.0)
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.backgroundColor = .black

        Metal360Renderer.shared.mtkView = mtkView

        // Gesto de arrastre para explorar en 360°
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        mtkView.addGestureRecognizer(pan)

        // Gesto de pellizco para zoom in / out
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        mtkView.addGestureRecognizer(pinch)

        // Doble toque para centrar vista y restablecer zoom
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        mtkView.addGestureRecognizer(doubleTap)

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var lastLocation: CGPoint = .zero

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let loc = gesture.translation(in: gesture.view)
            if gesture.state == .began {
                lastLocation = loc
            } else if gesture.state == .changed {
                let dx = loc.x - lastLocation.x
                let dy = loc.y - lastLocation.y
                lastLocation = loc
                Metal360Renderer.shared.handlePan(deltaX: dx, deltaY: dy)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                Metal360Renderer.shared.handlePinch(scale: gesture.scale)
                gesture.scale = 1.0
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            Metal360Renderer.shared.resetOrientation()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}
