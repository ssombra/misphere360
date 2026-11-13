import Foundation
import Metal
import MetalKit
import CoreVideo
import SwiftUI

/// Renderizador Metal de alto rendimiento para el cosido (stitching) óptico en tiempo real del flujo RTSP de la Xiaomi Mi Sphere 360.
public final class Metal360Renderer: NSObject, ObservableObject, MTKViewDelegate {
    public static let shared = Metal360Renderer()

    public enum DisplayMode: Int, CaseIterable, Identifiable {
        case interactive360 = 0 // Esfera 360° Interactiva
        case panorama360 = 1    // Panorama 360° Plano Cosido
        case dualFisheye = 2    // Dual-Fisheye Crudo Original

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .interactive360: return "360°"
            case .panorama360: return "Panorama"
            case .dualFisheye: return "Fisheye"
            }
        }
    }

    @Published public var mode: DisplayMode = .interactive360
    @Published public var yaw: Float = 0.0
    @Published public var pitch: Float = 0.0
    @Published public var fovDeg: Float = 85.0
    @Published public var isLutLoaded: Bool = false

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var textureCache: CVMetalTextureCache?

    // Texturas de calibración óptica de fábrica (512 x 256)
    private var lut1Texture: MTLTexture?
    private var lut2Texture: MTLTexture?
    private var weightTexture: MTLTexture?

    // Textura actual del cuadro de vídeo
    private var currentVideoTexture: MTLTexture?
    private let textureLock = NSLock()

    private struct Uniforms {
        var mode: Int32
        var yaw: Float
        var pitch: Float
        var tanHalfFov: Float
        var aspect: Float
    }

    private override init() {
        super.init()
        setupMetal()
        loadFactoryLUT()
    }

    // MARK: - Inicialización de Metal

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            print("[Metal360] Dispositivo Metal no disponible.")
            return
        }
        self.device = dev
        self.commandQueue = dev.makeCommandQueue()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        // Compilar Pipeline con los shaders
        guard let defaultLib = dev.makeDefaultLibrary() ?? (try? dev.makeDefaultLibrary(bundle: Bundle.main)) else {
            print("[Metal360] Error: no se pudo cargar la librería Metal predeterminada.")
            return
        }

        let vertexFunc = defaultLib.makeFunction(name: "stitchVertexShader")
        let fragmentFunc = defaultLib.makeFunction(name: "stitchFragmentShader")

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try dev.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            print("[Metal360] Error creando RenderPipelineState: \(error)")
        }

        // Crear Muestreador Lineal (Bilinear Filtering por GPU)
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .clampToEdge
        self.samplerState = dev.makeSamplerState(descriptor: samplerDesc)
    }

    // MARK: - Carga de la Tabla Óptica de Fábrica (factory_lut.bin)

    private func loadFactoryLUT() {
        guard let dev = self.device else { return }

        guard let lutURL = Bundle.main.url(forResource: "factory_lut", withExtension: "bin"),
              let data = try? Data(contentsOf: lutURL) else {
            print("[Metal360] No se encontró factory_lut.bin en el bundle.")
            return
        }

        let expectedBytes = 512 * 256 * 6 * 4 // 3,145,728 bytes
        guard data.count == expectedBytes else {
            print("[Metal360] Tamaño de factory_lut.bin inválido (\(data.count) bytes).")
            return
        }

        let GW = 512
        let GH = 256
        let GN = GW * GH

        data.withUnsafeBytes { rawPtr in
            guard let floatPtr = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }

            let u1Ptr = floatPtr
            let v1Ptr = floatPtr.advanced(by: GN)
            let u2Ptr = floatPtr.advanced(by: GN * 2)
            let v2Ptr = floatPtr.advanced(by: GN * 3)
            let w1Ptr = floatPtr.advanced(by: GN * 4)

            // Buffers normalizados para texturas Metal (u: 0..6912 -> 0..1, v: 0..3456 -> 0..1)
            var lut1Data = [Float](repeating: 0, count: GN * 2) // RG32Float
            var lut2Data = [Float](repeating: 0, count: GN * 2) // RG32Float
            var weightData = [Float](repeating: 0, count: GN)    // R32Float

            for k in 0..<GN {
                let u1 = u1Ptr[k]
                let v1 = v1Ptr[k]
                let u2 = u2Ptr[k]
                let v2 = v2Ptr[k]
                let w1 = w1Ptr[k]

                let u1n: Float = u1 >= 0.0 ? max(0.0, min(1.0, u1 / 6912.0)) : 0.0
                let v1n: Float = v1 >= 0.0 ? max(0.0, min(1.0, v1 / 3456.0)) : 0.0
                let u2n: Float = u2 >= 0.0 ? max(0.0, min(1.0, u2 / 6912.0)) : 0.0
                let v2n: Float = v2 >= 0.0 ? max(0.0, min(1.0, v2 / 3456.0)) : 0.0

                lut1Data[k * 2 + 0] = u1n
                lut1Data[k * 2 + 1] = v1n

                lut2Data[k * 2 + 0] = u2n
                lut2Data[k * 2 + 1] = v2n

                weightData[k] = max(0.0, min(1.0, w1))
            }

            // Crear Texturas Metal
            let lutDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: GW, height: GH, mipmapped: false)
            lutDesc.usage = [.shaderRead]

            let weightDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: GW, height: GH, mipmapped: false)
            weightDesc.usage = [.shaderRead]

            if let t1 = dev.makeTexture(descriptor: lutDesc),
               let t2 = dev.makeTexture(descriptor: lutDesc),
               let tw = dev.makeTexture(descriptor: weightDesc) {

                t1.replace(region: MTLRegionMake2D(0, 0, GW, GH), mipmapLevel: 0, withBytes: lut1Data, bytesPerRow: GW * 2 * MemoryLayout<Float>.size)
                t2.replace(region: MTLRegionMake2D(0, 0, GW, GH), mipmapLevel: 0, withBytes: lut2Data, bytesPerRow: GW * 2 * MemoryLayout<Float>.size)
                tw.replace(region: MTLRegionMake2D(0, 0, GW, GH), mipmapLevel: 0, withBytes: weightData, bytesPerRow: GW * MemoryLayout<Float>.size)

                self.lut1Texture = t1
                self.lut2Texture = t2
                self.weightTexture = tw

                DispatchQueue.main.async {
                    self.isLutLoaded = true
                    print("[Metal360] Tabla óptica cargada exitosamente en GPU Metal.")
                }
            }
        }
    }

    // MARK: - Actualización de Cuadro de Vídeo (CVPixelBuffer -> MTLTexture sin copia)

    public func updatePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = self.textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTextureOut: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )

        if result == kCVReturnSuccess, let cvTex = cvTextureOut, let metalTex = CVMetalTextureGetTexture(cvTex) {
            textureLock.lock()
            self.currentVideoTexture = metalTex
            textureLock.unlock()
        }
    }

    // MARK: - Interacción Táctil (Arrastrar para rotar)

    public func handlePan(deltaX: CGFloat, deltaY: CGFloat) {
        let sensitivity: Float = 0.005
        yaw -= Float(deltaX) * sensitivity
        pitch = max(-1.4, min(1.4, pitch + Float(deltaY) * sensitivity))
    }

    public func resetOrientation() {
        yaw = 0.0
        pitch = 0.0
        fovDeg = 85.0
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let pipeline = self.pipelineState,
              let commandQueue = self.commandQueue,
              let sampler = self.samplerState else {
            return
        }

        textureLock.lock()
        let videoTex = self.currentVideoTexture
        textureLock.unlock()

        guard let video = videoTex,
              let lut1 = self.lut1Texture,
              let lut2 = self.lut2Texture,
              let weight = self.weightTexture else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)

        // Calcular Uniforms
        let aspect = Float(view.bounds.width / max(1.0, view.bounds.height))
        let fovRad = fovDeg * (.pi / 180.0)
        let tanHalfFov = tan(fovRad * 0.5)

        var uniforms = Uniforms(
            mode: Int32(mode.rawValue),
            yaw: yaw,
            pitch: pitch,
            tanHalfFov: tanHalfFov,
            aspect: aspect
        )

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)

        // Asignar Texturas
        encoder.setFragmentTexture(video, index: 0)
        encoder.setFragmentTexture(lut1, index: 1)
        encoder.setFragmentTexture(lut2, index: 2)
        encoder.setFragmentTexture(weight, index: 3)
        encoder.setFragmentSamplerState(sampler, index: 0)

        // Dibujar pantalla completa (2 triángulos = 6 vértices)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
