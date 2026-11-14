import Foundation
import AVFoundation
import CoreVideo
import CoreLocation
import Metal
import UIKit

/// Formatos de relación de aspecto para exportar video plano reencuadrado ("Reframe").
public enum ReframeAspectPreset: String, CaseIterable, Identifiable {
    case vertical9x16 = "Vertical (9:16)"
    case square1x1 = "Cuadrado (1:1)"
    case horizontal16x9 = "Horizontal (16:9)"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .vertical9x16: return "rectangle.portrait"
        case .square1x1: return "square"
        case .horizontal16x9: return "rectangle"
        }
    }

    public var dimensions: (width: Int, height: Int, bitrate: Int) {
        switch self {
        case .vertical9x16: return (1080, 1920, 16_000_000)
        case .square1x1: return (1920, 1920, 20_000_000)
        case .horizontal16x9: return (1920, 1080, 16_000_000)
        }
    }
}

/// Exportador de video 360° y video plano (Reframe) por GPU (Metal + VideoToolbox) con inyección de metadatos espaciales (sv3d + GSpherical).
public final class VideoStitcher {
    public static let shared = VideoStitcher()

    private struct StitchUniforms {
        var mode: Int32
        var yaw: Float
        var pitch: Float
        var tanHalfFov: Float
        var aspect: Float
        var projMode: Int32
        var fovDeg: Float
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var reframePipelineState: MTLRenderPipelineState?
    private var rgbaThumbPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var textureCache: CVMetalTextureCache?

    private var lut1Texture: MTLTexture?
    private var lut2Texture: MTLTexture?
    private var weightTexture: MTLTexture?
    private let setupLock = NSLock()
    private var isMetalReady = false

    private init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = self.device?.makeCommandQueue()
    }

    private func ensureMetalReady() -> Bool {
        setupLock.lock()
        defer { setupLock.unlock() }
        if isMetalReady { return true }

        guard let dev = device else { return false }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        guard let lib = dev.makeDefaultLibrary() ?? (try? dev.makeDefaultLibrary(bundle: Bundle.main)),
              let vFunc = lib.makeFunction(name: "stitchVertexShader"),
              let fFunc = lib.makeFunction(name: "stitchOffscreenEquirectFragment"),
              let fReframeFunc = lib.makeFunction(name: "stitchFragmentShader"),
              let fThumbFunc = lib.makeFunction(name: "stitchOffscreenEquirectRGBAFragment") else {
            print("[VideoStitcher] No se pudieron cargar los shaders Metal.")
            return false
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vFunc
        desc.fragmentFunction = fFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let reframeDesc = MTLRenderPipelineDescriptor()
        reframeDesc.vertexFunction = vFunc
        reframeDesc.fragmentFunction = fReframeFunc
        reframeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let thumbDesc = MTLRenderPipelineDescriptor()
        thumbDesc.vertexFunction = vFunc
        thumbDesc.fragmentFunction = fThumbFunc
        thumbDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try dev.makeRenderPipelineState(descriptor: desc)
            self.reframePipelineState = try dev.makeRenderPipelineState(descriptor: reframeDesc)
            self.rgbaThumbPipelineState = try dev.makeRenderPipelineState(descriptor: thumbDesc)
        } catch {
            print("[VideoStitcher] Error creando RenderPipelineState: \(error)")
            return false
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .clampToEdge
        self.samplerState = dev.makeSamplerState(descriptor: samplerDesc)

        guard loadFactoryLUT(device: dev) else {
            return false
        }

        isMetalReady = true
        return true
    }

    private func loadFactoryLUT(device: MTLDevice) -> Bool {
        guard let lutURL = Bundle.main.url(forResource: "factory_lut", withExtension: "bin"),
              let data = try? Data(contentsOf: lutURL) else {
            print("[VideoStitcher] No se encontró factory_lut.bin.")
            return false
        }

        let GW = 512
        let GH = 256
        let GN = GW * GH
        guard data.count == GN * 6 * 4 else { return false }

        var lut1Data = [Float](repeating: 0, count: GN * 2)
        var lut2Data = [Float](repeating: 0, count: GN * 2)
        var weightData = [Float](repeating: 0, count: GN)

        data.withUnsafeBytes { rawPtr in
            guard let fp = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let u1 = fp
            let v1 = fp.advanced(by: GN)
            let u2 = fp.advanced(by: GN * 2)
            let v2 = fp.advanced(by: GN * 3)
            let w1 = fp.advanced(by: GN * 4)

            for k in 0..<GN {
                lut1Data[k * 2] = u1[k] / 6912.0
                lut1Data[k * 2 + 1] = v1[k] / 3456.0
                lut2Data[k * 2] = u2[k] / 6912.0
                lut2Data[k * 2 + 1] = v2[k] / 3456.0
                weightData[k] = w1[k]
            }
        }

        let rgDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: GW, height: GH, mipmapped: false)
        rgDesc.usage = .shaderRead
        let rDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: GW, height: GH, mipmapped: false)
        rDesc.usage = .shaderRead

        guard let t1 = device.makeTexture(descriptor: rgDesc),
              let t2 = device.makeTexture(descriptor: rgDesc),
              let tw = device.makeTexture(descriptor: rDesc) else {
            return false
        }

        let region = MTLRegionMake2D(0, 0, GW, GH)
        lut1Data.withUnsafeBytes { t1.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: GW * 8) }
        lut2Data.withUnsafeBytes { t2.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: GW * 8) }
        weightData.withUnsafeBytes { tw.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: GW * 4) }

        self.lut1Texture = t1
        self.lut2Texture = t2
        self.weightTexture = tw
        return true
    }

    /// Cose por GPU una imagen dual-fisheye de cualquier resolución a una miniatura equirrectangular 2:1.
    public func stitchDualFisheyeThumbnail(_ image: UIImage, width: Int = 512, height: Int = 256) -> UIImage? {
        guard ensureMetalReady(),
              let dev = device,
              let commandQueue = commandQueue,
              let pipeline = rgbaThumbPipelineState,
              let sampler = samplerState,
              let lut1 = lut1Texture,
              let lut2 = lut2Texture,
              let weight = weightTexture,
              let cgImage = image.cgImage else {
            return nil
        }

        let inW = cgImage.width
        let inH = cgImage.height
        guard inW > 0, inH > 0 else { return nil }

        let inBytesPerRow = inW * 4
        var inBytes = [UInt8](repeating: 0, count: inBytesPerRow * inH)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let inBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &inBytes,
            width: inW,
            height: inH,
            bitsPerComponent: 8,
            bytesPerRow: inBytesPerRow,
            space: colorSpace,
            bitmapInfo: inBitmapInfo
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: inW, height: inH))

        let inDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: inW, height: inH, mipmapped: false)
        inDesc.usage = .shaderRead
        guard let inTex = dev.makeTexture(descriptor: inDesc) else { return nil }
        inTex.replace(region: MTLRegionMake2D(0, 0, inW, inH), mipmapLevel: 0, withBytes: inBytes, bytesPerRow: inBytesPerRow)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outDesc.usage = [.renderTarget, .shaderRead]
        outDesc.storageMode = .shared
        guard let outTex = dev.makeTexture(descriptor: outDesc) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = outTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            return nil
        }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(inTex, index: 0)
        enc.setFragmentTexture(lut1, index: 1)
        enc.setFragmentTexture(lut2, index: 2)
        enc.setFragmentTexture(weight, index: 3)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        guard cmdBuf.status == .completed else { return nil }

        let outBytesPerRow = width * 4
        var outBytes = [UInt8](repeating: 0, count: outBytesPerRow * height)
        outTex.getBytes(&outBytes, bytesPerRow: outBytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let outBitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(outBytes) as CFData),
              let outCG = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: outBytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: outBitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return UIImage(cgImage: outCG)
    }

    /// Determina la resolución equirrectangular 2:1 y bitrate H.264 óptimo según la resolución del video fuente.
    private func outputSpec(for naturalSize: CGSize) -> (width: Int, height: Int, bitrate: Int) {
        let srcWidth = max(naturalSize.width, naturalSize.height)
        if srcWidth >= 3000 {
            return (3840, 1920, 35_000_000)
        } else if srcWidth >= 1800 {
            return (2560, 1280, 18_000_000)
        } else {
            return (1920, 960, 12_000_000)
        }
    }

    /// Cose un MP4 dual-fisheye a equirrectangular 2:1 (H.264) e inyecta metadatos espaciales 360° (sv3d + GSpherical) y GPS.
    public func stitchVideo(
        inputURL: URL,
        outputURL: URL,
        location: CLLocation? = nil,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        runMetalVideoExport(
            inputURL: inputURL,
            outputURL: outputURL,
            fixedSpec: nil,
            uniforms: nil,
            inject360Metadata: true,
            location: location,
            progress: progress,
            completion: completion
        )
    }

    /// Exporta un MP4 plano ("Reframe") en el modo de proyección y encuadre elegidos (Normal, Fisheye, Little Planet, Rabbit Hole, Crystal Ball).
    public func stitchReframedVideo(
        inputURL: URL,
        outputURL: URL,
        projectionMode: PhotoProjectionMode,
        yaw: Float,
        pitch: Float,
        fovDeg: Float,
        aspectPreset: ReframeAspectPreset,
        location: CLLocation? = nil,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let dims = aspectPreset.dimensions
        let aspect = Float(dims.width) / Float(dims.height)
        let fovRad = fovDeg * (.pi / 180.0)
        let tanHalfFov = tan(fovRad * 0.5)

        let projIndex: Int32
        let shaderMode: Int32
        switch projectionMode {
        case .normal: projIndex = 0; shaderMode = 0
        case .fisheye: projIndex = 1; shaderMode = 0
        case .littlePlanet: projIndex = 2; shaderMode = 0
        case .rabbitHole: projIndex = 3; shaderMode = 0
        case .crystalBall: projIndex = 4; shaderMode = 0
        case .pano360: projIndex = 0; shaderMode = 1
        }

        let uniforms = StitchUniforms(
            mode: shaderMode,
            yaw: yaw,
            pitch: pitch,
            tanHalfFov: tanHalfFov,
            aspect: aspect,
            projMode: projIndex,
            fovDeg: fovDeg
        )

        runMetalVideoExport(
            inputURL: inputURL,
            outputURL: outputURL,
            fixedSpec: dims,
            uniforms: uniforms,
            inject360Metadata: false,
            location: location,
            progress: progress,
            completion: completion
        )
    }

    private func runMetalVideoExport(
        inputURL: URL,
        outputURL: URL,
        fixedSpec: (width: Int, height: Int, bitrate: Int)?,
        uniforms: StitchUniforms?,
        inject360Metadata: Bool,
        location: CLLocation?,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureMetalReady(),
                  let commandQueue = self.commandQueue,
                  let pipeline = (uniforms != nil ? self.reframePipelineState : self.pipelineState),
                  let sampler = self.samplerState,
                  let texCache = self.textureCache,
                  let lut1 = self.lut1Texture,
                  let lut2 = self.lut2Texture,
                  let weight = self.weightTexture else {
                completion(.failure(NSError(domain: "VideoStitcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Metal no disponible para coser el video."])))
                return
            }

            let asset = AVURLAsset(url: inputURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                completion(.failure(NSError(domain: "VideoStitcher", code: -2, userInfo: [NSLocalizedDescriptionKey: "No se encontró pista de video en el MP4."])))
                return
            }

            let audioTrack = asset.tracks(withMediaType: .audio).first
            let durationSec = max(0.01, asset.duration.seconds.isFinite ? asset.duration.seconds : 1.0)
            let spec = fixedSpec ?? self.outputSpec(for: videoTrack.naturalSize)

            let rawOutputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiSphere_raw_\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: rawOutputURL)
            try? FileManager.default.removeItem(at: outputURL)

            let reader: AVAssetReader
            let writer: AVAssetWriter
            do {
                reader = try AVAssetReader(asset: asset)
                writer = try AVAssetWriter(outputURL: rawOutputURL, fileType: .mp4)
                writer.shouldOptimizeForNetworkUse = true
                if let loc = location {
                    let item = AVMutableMetadataItem()
                    item.keySpace = .common
                    item.key = AVMetadataKey.commonKeyLocation as NSString
                    item.value = String(format: "%+.6f%+.6f%+.1f/", loc.coordinate.latitude, loc.coordinate.longitude, loc.altitude) as NSString
                    writer.metadata = [item]
                }
            } catch {
                completion(.failure(error))
                return
            }

            let readerVideoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerVideoSettings)
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                completion(.failure(NSError(domain: "VideoStitcher", code: -3, userInfo: [NSLocalizedDescriptionKey: "No se pudo configurar el lector de video."])))
                return
            }
            reader.add(videoOutput)

            var audioOutput: AVAssetReaderTrackOutput? = nil
            var audioInput: AVAssetWriterInput? = nil
            if let aTrack = audioTrack {
                let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                aOut.alwaysCopiesSampleData = false
                if reader.canAdd(aOut) {
                    reader.add(aOut)
                    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                    aIn.expectsMediaDataInRealTime = false
                    if writer.canAdd(aIn) {
                        writer.add(aIn)
                        audioOutput = aOut
                        audioInput = aIn
                    }
                }
            }

            let compressionProps: [String: Any] = [
                AVVideoAverageBitRateKey: spec.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: spec.width,
                AVVideoHeightKey: spec.height,
                AVVideoCompressionPropertiesKey: compressionProps
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false

            let poolAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: poolAttrs
            )

            guard writer.canAdd(videoInput) else {
                completion(.failure(NSError(domain: "VideoStitcher", code: -4, userInfo: [NSLocalizedDescriptionKey: "No se pudo configurar el codificador H.264."])))
                return
            }
            writer.add(videoInput)

            guard reader.startReading(), writer.startWriting() else {
                let err = reader.error ?? writer.error ?? NSError(domain: "VideoStitcher", code: -5, userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar la lectura/escritura del video."])
                completion(.failure(err))
                return
            }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()
            let videoQueue = DispatchQueue(label: "com.misphere.videostitcher.video")
            let audioQueue = DispatchQueue(label: "com.misphere.videostitcher.audio")

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    autoreleasepool {
                        guard let sample = videoOutput.copyNextSampleBuffer() else {
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }

                        guard let srcPixelBuffer = CMSampleBufferGetImageBuffer(sample),
                              let pool = adaptor.pixelBufferPool else {
                            return
                        }

                        var dstPixelBuffer: CVPixelBuffer?
                        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPixelBuffer)
                        guard poolStatus == kCVReturnSuccess, let dstBuffer = dstPixelBuffer else {
                            return
                        }

                        let ok = self.renderFrame(
                            srcPixelBuffer: srcPixelBuffer,
                            dstPixelBuffer: dstBuffer,
                            width: spec.width,
                            height: spec.height,
                            uniforms: uniforms,
                            texCache: texCache,
                            commandQueue: commandQueue,
                            pipeline: pipeline,
                            sampler: sampler,
                            lut1: lut1,
                            lut2: lut2,
                            weight: weight
                        )

                        if ok {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            adaptor.append(dstBuffer, withPresentationTime: pts)
                            let p = min(0.95, max(0.0, pts.seconds / durationSec))
                            DispatchQueue.main.async {
                                progress?(p)
                            }
                        }
                    }
                    // Si copyNextSampleBuffer devolvió nil, ya se llamó markAsFinished y leave() arriba
                    if reader.status != .reading {
                        break
                    }
                }
            }

            if let aOut = audioOutput, let aIn = audioInput {
                group.enter()
                aIn.requestMediaDataWhenReady(on: audioQueue) {
                    while aIn.isReadyForMoreMediaData {
                        if let sample = aOut.copyNextSampleBuffer() {
                            aIn.append(sample)
                        } else {
                            aIn.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.wait()

            if reader.status == .failed {
                try? FileManager.default.removeItem(at: rawOutputURL)
                completion(.failure(reader.error ?? NSError(domain: "VideoStitcher", code: -6, userInfo: [NSLocalizedDescriptionKey: "Error leyendo el video original."])))
                return
            }

            writer.finishWriting {
                if writer.status == .failed {
                    try? FileManager.default.removeItem(at: rawOutputURL)
                    completion(.failure(writer.error ?? NSError(domain: "VideoStitcher", code: -7, userInfo: [NSLocalizedDescriptionKey: "Error codificando el video 360°."])))
                    return
                }

                if !inject360Metadata {
                    try? FileManager.default.moveItem(at: rawOutputURL, to: outputURL)
                    DispatchQueue.main.async {
                        progress?(1.0)
                    }
                    completion(.success(outputURL))
                    return
                }

                // Inyectar metadatos espaciales 360° (st3d + sv3d + GSpherical)
                do {
                    try MP4SpatialMetadataInjector.inject360Metadata(from: rawOutputURL, to: outputURL)
                    try? FileManager.default.removeItem(at: rawOutputURL)
                    DispatchQueue.main.async {
                        progress?(1.0)
                    }
                    completion(.success(outputURL))
                } catch {
                    // Fallback: si fallara la inyección, al menos devolver el MP4 cosido
                    try? FileManager.default.moveItem(at: rawOutputURL, to: outputURL)
                    DispatchQueue.main.async {
                        progress?(1.0)
                    }
                    completion(.success(outputURL))
                }
            }
        }
    }

    private func renderFrame(
        srcPixelBuffer: CVPixelBuffer,
        dstPixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        uniforms: StitchUniforms?,
        texCache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState,
        sampler: MTLSamplerState,
        lut1: MTLTexture,
        lut2: MTLTexture,
        weight: MTLTexture
    ) -> Bool {
        let srcW = CVPixelBufferGetWidthOfPlane(srcPixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(srcPixelBuffer, 0)

        var yTexRef: CVMetalTexture?
        var uvTexRef: CVMetalTexture?
        var dstTexRef: CVMetalTexture?

        let s1 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, srcPixelBuffer, nil, .r8Unorm, srcW, srcH, 0, &yTexRef)
        let s2 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, srcPixelBuffer, nil, .rg8Unorm, srcW / 2, srcH / 2, 1, &uvTexRef)
        let s3 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, dstPixelBuffer, nil, .bgra8Unorm, width, height, 0, &dstTexRef)

        guard s1 == kCVReturnSuccess, s2 == kCVReturnSuccess, s3 == kCVReturnSuccess,
              let yRef = yTexRef, let uvRef = uvTexRef, let dRef = dstTexRef,
              let yTex = CVMetalTextureGetTexture(yRef),
              let uvTex = CVMetalTextureGetTexture(uvRef),
              let dstTex = CVMetalTextureGetTexture(dRef) else {
            return false
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dstTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            return false
        }

        enc.setRenderPipelineState(pipeline)
        if var u = uniforms {
            enc.setVertexBytes(&u, length: MemoryLayout<StitchUniforms>.size, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<StitchUniforms>.size, index: 0)
        }
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(uvTex, index: 1)
        enc.setFragmentTexture(lut1, index: 2)
        enc.setFragmentTexture(lut2, index: 3)
        enc.setFragmentTexture(weight, index: 4)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        return cmdBuf.status == .completed
    }
}

// MARK: - Inyector de Metadatos Espaciales MP4 (Spatial Media v2 sv3d/st3d + v1 GSpherical XMP)

private enum MP4SpatialMetadataInjector {
    private struct BoxInfo {
        let type: String
        let offset: Int
        let size: Int
        let headerSize: Int
        var payloadRange: Range<Int> { (offset + headerSize)..<(offset + size) }
    }

    static func inject360Metadata(from inputURL: URL, to outputURL: URL) throws {
        var data = try Data(contentsOf: inputURL)

        let topBoxes = parseBoxes(in: data, range: 0..<data.count)
        guard let moov = topBoxes.first(where: { $0.type == "moov" }) else {
            throw NSError(domain: "MP4SpatialMetadata", code: -1, userInfo: [NSLocalizedDescriptionKey: "No se encontró el átomo moov."])
        }

        let moovChildren = parseBoxes(in: data, range: moov.payloadRange)
        let videoTrak = moovChildren.first { trak in
            guard trak.type == "trak" else { return false }
            let trakChildren = parseBoxes(in: data, range: trak.payloadRange)
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else { return false }
            let mdiaChildren = parseBoxes(in: data, range: mdia.payloadRange)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else { return false }
            let handlerStart = hdlr.offset + hdlr.headerSize + 8
            guard handlerStart + 4 <= data.count else { return false }
            let handlerType = String(bytes: data[handlerStart..<(handlerStart + 4)], encoding: .ascii)
            return handlerType == "vide"
        }

        guard let trak = videoTrak,
              let mdia = parseBoxes(in: data, range: trak.payloadRange).first(where: { $0.type == "mdia" }),
              let minf = parseBoxes(in: data, range: mdia.payloadRange).first(where: { $0.type == "minf" }),
              let stbl = parseBoxes(in: data, range: minf.payloadRange).first(where: { $0.type == "stbl" }),
              let stsd = parseBoxes(in: data, range: stbl.payloadRange).first(where: { $0.type == "stsd" }) else {
            throw NSError(domain: "MP4SpatialMetadata", code: -2, userInfo: [NSLocalizedDescriptionKey: "No se encontró stsd de video."])
        }

        // stsd fullbox header (4 bytes version/flags + 4 bytes entry_count)
        let sampleEntryOffset = stsd.offset + stsd.headerSize + 8
        guard sampleEntryOffset + 8 <= data.count else {
            throw NSError(domain: "MP4SpatialMetadata", code: -3, userInfo: [NSLocalizedDescriptionKey: "stsd inválido."])
        }
        let sampleEntrySize = Int(readUInt32BE(data, at: sampleEntryOffset))
        let sampleEntryEnd = sampleEntryOffset + sampleEntrySize

        // 1. Construir st3d + sv3d (Spatial Media v2)
        let v2Boxes = makeSt3dBox() + makeSv3dBox()
        let v2InsertAt = sampleEntryEnd
        data.insert(contentsOf: v2Boxes, at: v2InsertAt)

        // Actualizar tamaño del sample entry (avc1/hvc1), stsd, stbl, minf, mdia, trak, moov
        let v2Delta = v2Boxes.count
        addToUInt32BE(&data, at: sampleEntryOffset, delta: v2Delta)
        addToUInt32BE(&data, at: stsd.offset, delta: v2Delta)
        addToUInt32BE(&data, at: stbl.offset, delta: v2Delta)
        addToUInt32BE(&data, at: minf.offset, delta: v2Delta)
        addToUInt32BE(&data, at: mdia.offset, delta: v2Delta)
        addToUInt32BE(&data, at: trak.offset, delta: v2Delta)
        addToUInt32BE(&data, at: moov.offset, delta: v2Delta)

        // 2. Insertar uuid GSpherical XMP (Spatial Media v1) al final del video trak
        let v1Box = makeGSphericalUUIDBox()
        let trakEndAfterV2 = trak.offset + trak.size + v2Delta
        data.insert(contentsOf: v1Box, at: trakEndAfterV2)

        let v1Delta = v1Box.count
        addToUInt32BE(&data, at: trak.offset, delta: v1Delta)
        addToUInt32BE(&data, at: moov.offset, delta: v1Delta)

        // 3. Ajustar offsets stco / co64 en todas las pistas si mdat está después de moov
        let totalDelta = v2Delta + v1Delta
        let updatedMoovSize = Int(readUInt32BE(data, at: moov.offset))
        let updatedMoovRange = moov.offset..<(moov.offset + updatedMoovSize)
        shiftChunkOffsets(in: &data, range: updatedMoovRange, threshold: v2InsertAt, delta: totalDelta)

        try data.write(to: outputURL, options: .atomic)
    }

    private static func makeSt3dBox() -> Data {
        var d = Data()
        appendUInt32BE(&d, 13)
        d.append(contentsOf: "st3d".utf8)
        appendUInt32BE(&d, 0) // version + flags
        d.append(0) // mono
        return d
    }

    private static func makeSv3dBox() -> Data {
        // svhd: size(4) + "svhd"(4) + version/flags(4) + "MiSphere\0"(9) = 21 bytes
        var svhd = Data()
        let source = Data("MiSphere\0".utf8)
        appendUInt32BE(&svhd, UInt32(12 + source.count))
        svhd.append(contentsOf: "svhd".utf8)
        appendUInt32BE(&svhd, 0)
        svhd.append(source)

        // prhd: size(4) + "prhd"(4) + version/flags(4) + yaw(4) + pitch(4) + roll(4) = 24 bytes
        var prhd = Data()
        appendUInt32BE(&prhd, 24)
        prhd.append(contentsOf: "prhd".utf8)
        appendUInt32BE(&prhd, 0)
        appendUInt32BE(&prhd, 0)
        appendUInt32BE(&prhd, 0)
        appendUInt32BE(&prhd, 0)

        // equi: size(4) + "equi"(4) + version/flags(4) + top(4) + bottom(4) + left(4) + right(4) = 28 bytes
        var equi = Data()
        appendUInt32BE(&equi, 28)
        equi.append(contentsOf: "equi".utf8)
        appendUInt32BE(&equi, 0)
        appendUInt32BE(&equi, 0)
        appendUInt32BE(&equi, 0)
        appendUInt32BE(&equi, 0)
        appendUInt32BE(&equi, 0)

        var proj = Data()
        appendUInt32BE(&proj, UInt32(8 + prhd.count + equi.count))
        proj.append(contentsOf: "proj".utf8)
        proj.append(prhd)
        proj.append(equi)

        var sv3d = Data()
        appendUInt32BE(&sv3d, UInt32(8 + svhd.count + proj.count))
        sv3d.append(contentsOf: "sv3d".utf8)
        sv3d.append(svhd)
        sv3d.append(proj)
        return sv3d
    }

    private static func makeGSphericalUUIDBox() -> Data {
        let uuid: [UInt8] = [
            0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93,
            0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd
        ]
        let xml = """
        <?xml version="1.0"?>
        <rdf:SphericalVideo xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:GSpherical="http://ns.google.com/videos/1.0/spherical/">
          <GSpherical:Spherical>true</GSpherical:Spherical>
          <GSpherical:Stitched>true</GSpherical:Stitched>
          <GSpherical:StitchingSoftware>MiSphere360 iOS</GSpherical:StitchingSoftware>
          <GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>
        </rdf:SphericalVideo>
        """
        let xmlData = Data(xml.utf8)
        var box = Data()
        appendUInt32BE(&box, UInt32(8 + uuid.count + xmlData.count))
        box.append(contentsOf: "uuid".utf8)
        box.append(contentsOf: uuid)
        box.append(xmlData)
        return box
    }

    private static func parseBoxes(in data: Data, range: Range<Int>) -> [BoxInfo] {
        var result: [BoxInfo] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size32 = Int(readUInt32BE(data, at: cursor))
            let type = String(bytes: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii) ?? ""
            var boxSize = size32
            var headerSize = 8
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                boxSize = Int(readUInt64BE(data, at: cursor + 8))
                headerSize = 16
            } else if size32 == 0 {
                boxSize = range.upperBound - cursor
            }
            if boxSize < headerSize || cursor + boxSize > range.upperBound {
                break
            }
            result.append(BoxInfo(type: type, offset: cursor, size: boxSize, headerSize: headerSize))
            cursor += boxSize
        }
        return result
    }

    private static func shiftChunkOffsets(in data: inout Data, range: Range<Int>, threshold: Int, delta: Int) {
        let boxes = parseBoxes(in: data, range: range)
        let containers = Set(["moov", "trak", "mdia", "minf", "stbl"])
        for box in boxes {
            if containers.contains(box.type) {
                shiftChunkOffsets(in: &data, range: box.payloadRange, threshold: threshold, delta: delta)
            } else if box.type == "stco" {
                let countOff = box.offset + box.headerSize + 4
                guard countOff + 4 <= box.offset + box.size else { continue }
                let count = Int(readUInt32BE(data, at: countOff))
                for i in 0..<count {
                    let entryOff = countOff + 4 + i * 4
                    guard entryOff + 4 <= box.offset + box.size else { break }
                    let val = Int(readUInt32BE(data, at: entryOff))
                    if val >= threshold {
                        writeUInt32BE(&data, at: entryOff, value: UInt32(val + delta))
                    }
                }
            } else if box.type == "co64" {
                let countOff = box.offset + box.headerSize + 4
                guard countOff + 4 <= box.offset + box.size else { continue }
                let count = Int(readUInt32BE(data, at: countOff))
                for i in 0..<count {
                    let entryOff = countOff + 4 + i * 8
                    guard entryOff + 8 <= box.offset + box.size else { break }
                    let val = Int(readUInt64BE(data, at: entryOff))
                    if val >= threshold {
                        writeUInt64BE(&data, at: entryOff, value: UInt64(val + delta))
                    }
                }
            }
        }
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
        UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 |
        UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(data, at: offset))
        let lo = UInt64(readUInt32BE(data, at: offset + 4))
        return (hi << 32) | lo
    }

    private static func writeUInt32BE(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeUInt64BE(_ data: inout Data, at offset: Int, value: UInt64) {
        writeUInt32BE(&data, at: offset, value: UInt32((value >> 32) & 0xFFFFFFFF))
        writeUInt32BE(&data, at: offset + 4, value: UInt32(value & 0xFFFFFFFF))
    }

    private static func addToUInt32BE(_ data: inout Data, at offset: Int, delta: Int) {
        let current = Int(readUInt32BE(data, at: offset))
        writeUInt32BE(&data, at: offset, value: UInt32(current + delta))
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}
