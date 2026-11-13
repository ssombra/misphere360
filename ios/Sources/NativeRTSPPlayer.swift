import Foundation
import UIKit
import Network
import AVFoundation
import VideoToolbox
import CoreMedia

/// Reproductor RTSP sobre TCP intercalado (interleaved) con decodificación nativa por hardware (VideoToolbox).
/// Diseñado específicamente para el flujo RTSP H.264 dual-fisheye de la Xiaomi Mi Sphere 360 (Ambarella A12).
public final class NativeRTSPPlayer: ObservableObject {
    public static let shared = NativeRTSPPlayer()

    @Published public var isPlaying: Bool = false
    @Published public var isConnecting: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var fps: Double = 0.0

    private weak var targetDisplayLayer: AVSampleBufferDisplayLayer?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ssombra.misphere360.nativertsp", qos: .userInteractive)

    private var streamURL = "rtsp://192.168.42.1/live"
    private var cseq = 1
    private var sessionId: String? = nil
    private var keepaliveTimer: DispatchSourceTimer?

    // Máquina de estados explícita para evitar peticiones duplicadas o fuera de orden
    private enum RTSPState {
        case disconnected
        case waitingOptions
        case waitingDescribe
        case waitingSetup
        case waitingPlay
        case streaming
    }
    private var state: RTSPState = .disconnected

    // Búferes de red y protocolo
    private var tcpBuffer = Data()

    // Parámetros de vídeo H.264
    private var spsData: Data? = nil
    private var ppsData: Data? = nil
    private var formatDescription: CMVideoFormatDescription? = nil
    private var decompressionSession: VTDecompressionSession?

    // Reensamblado de unidades de fragmentación (FU-A)
    private var fuAssemblyBuffer = Data()
    private var isAssemblingFU = false

    // Ensamblado de Unidad de Acceso (Access Unit / Cuadro completo)
    private var currentFrameNALs: [Data] = []
    private var currentFrameTimestamp: UInt32? = nil
    private var isCurrentFrameKeyframe: Bool = false

    // Métricas y watchdog
    private var frameCount: Int = 0
    private var lastFpsCalculationTime: CFTimeInterval = 0
    private var lastFrameReceivedTime: CFTimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?

    private init() {
        tcpBuffer.reserveCapacity(131072) // 128 KB
        fuAssemblyBuffer.reserveCapacity(65536)
    }

    deinit {
        stopStream()
    }

    // MARK: - Control Público

    /// Conecta la capa de visualización y arranca la reproducción
    public func startStream(to displayLayer: AVSampleBufferDisplayLayer? = nil, url: String = "rtsp://192.168.42.1/live") {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let layer = displayLayer {
                self.targetDisplayLayer = layer
            }

            // Si ya está en proceso de conexión o reproduciendo, no reiniciar
            if self.isPlaying || self.isConnecting {
                return
            }

            self.streamURL = url
            self.resetState()

            DispatchQueue.main.async {
                self.isConnecting = true
                self.errorMessage = nil
                self.targetDisplayLayer?.flush()
            }

            print("[NativeRTSP] Iniciando conexión directa a \(url)...")
            self.connectSocket()
            self.startWatchdog()
        }
    }

    /// Detiene la reproducción, envía TEARDOWN y cierra el socket
    public func stopStream() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.stopWatchdog()
            self.stopKeepalive()

            if let sid = self.sessionId {
                let teardown = "TEARDOWN \(self.streamURL) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(sid)\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
                self.sendRTSP(teardown)
            }

            self.connection?.cancel()
            self.connection = nil

            self.resetState()

            DispatchQueue.main.async {
                self.isPlaying = false
                self.isConnecting = false
                self.fps = 0.0
                self.targetDisplayLayer?.flush()
            }
            print("[NativeRTSP] Flujo detenido y recursos liberados.")
        }
    }

    private func resetState() {
        if let sess = decompressionSession {
            VTDecompressionSessionInvalidate(sess)
            decompressionSession = nil
        }
        state = .disconnected
        cseq = 1
        sessionId = nil
        tcpBuffer.removeAll(keepingCapacity: true)
        fuAssemblyBuffer.removeAll(keepingCapacity: true)
        isAssemblingFU = false
        currentFrameNALs.removeAll(keepingCapacity: true)
        currentFrameTimestamp = nil
        isCurrentFrameKeyframe = false
        frameCount = 0
        lastFpsCalculationTime = CACurrentMediaTime()
        lastFrameReceivedTime = CACurrentMediaTime()
    }

    // MARK: - Conexión de Red (Network.framework)

    private func connectSocket() {
        connection?.cancel()

        guard let host = URL(string: streamURL)?.host ?? "192.168.42.1" as String? else {
            showError("Dirección IP de la cámara inválida.")
            return
        }
        let endpoint = NWEndpoint.Host(host)
        let port = NWEndpoint.Port(rawValue: 554) ?? 554

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        tcpOpts.enableKeepalive = true
        tcpOpts.keepaliveIdle = 10

        let params = NWParameters(tls: nil, tcp: tcpOpts)

        let conn = NWConnection(host: endpoint, port: port, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] netState in
            guard let self = self else { return }
            switch netState {
            case .ready:
                print("[NativeRTSP] Socket TCP conectado a \(host):554. Enviando OPTIONS...")
                self.sendOptions()
                self.receiveNext()
            case .failed(let err):
                print("[NativeRTSP] Error de conexión TCP: \(err)")
                self.showError("No se pudo conectar al puerto 554 de la cámara.")
            case .waiting(let err):
                print("[NativeRTSP] Conexión en espera: \(err)")
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - Protocolo RTSP (Máquina de Estados)

    private func sendRTSP(_ str: String) {
        guard let data = str.data(using: .utf8), let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { err in
            if let e = err {
                print("[NativeRTSP] Error enviando petición: \(e)")
            }
        })
    }

    private func sendOptions() {
        state = .waitingOptions
        let req = "OPTIONS \(streamURL) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
        cseq += 1
        sendRTSP(req)
    }

    private func sendDescribe() {
        state = .waitingDescribe
        let req = "DESCRIBE \(streamURL) RTSP/1.0\r\nCSeq: \(cseq)\r\nAccept: application/sdp\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
        cseq += 1
        sendRTSP(req)
    }

    private func sendSetup(trackPath: String) {
        state = .waitingSetup
        let req = "SETUP \(trackPath) RTSP/1.0\r\nCSeq: \(cseq)\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
        cseq += 1
        sendRTSP(req)
    }

    private func sendPlay() {
        guard let sid = sessionId else {
            showError("No se obtuvo Session ID en el SETUP RTSP.")
            return
        }
        state = .waitingPlay
        let req = "PLAY \(streamURL) RTSP/1.0\r\nCSeq: \(cseq)\r\nSession: \(sid)\r\nRange: npt=0.000-\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
        cseq += 1
        sendRTSP(req)
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self = self, let sid = self.sessionId, self.state == .streaming else { return }
            let keepalive = "OPTIONS \(self.streamURL) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(sid)\r\nUser-Agent: MiSphere360/1.0\r\n\r\n"
            self.cseq += 1
            self.sendRTSP(keepalive)
        }
        timer.resume()
        self.keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Bucle de Recepción TCP

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.tcpBuffer.append(data)
                self.processTCPBuffer()
            }

            if isComplete {
                print("[NativeRTSP] Conexión cerrada por la cámara (isComplete).")
                self.showError("Conexión finalizada por la cámara.")
                return
            }

            if let err = error {
                print("[NativeRTSP] Error de recepción: \(err)")
                self.showError("Error de lectura en el flujo RTSP.")
                return
            }

            self.receiveNext()
        }
    }

    // MARK: - Procesamiento del Búfer Intercalado

    private func processTCPBuffer() {
        while !tcpBuffer.isEmpty {
            // Caso 1: Paquete RTP intercalado ($ = 0x24)
            if tcpBuffer[0] == 0x24 {
                guard tcpBuffer.count >= 4 else { return }

                let channel = tcpBuffer[1]
                let packetLen = (Int(tcpBuffer[2]) << 8) | Int(tcpBuffer[3])
                let totalLen = 4 + packetLen

                guard tcpBuffer.count >= totalLen else {
                    // Paquete incompleto: esperar siguientes bytes TCP
                    return
                }

                let packetData = tcpBuffer.subdata(in: 4..<totalLen)
                tcpBuffer.removeSubrange(0..<totalLen)

                if channel == 0 {
                    // Canal 0 = Video RTP
                    processRTPPacket(packetData)
                }
                // Canal 1 = RTCP (ignorar)
            } else {
                // Caso 2: Mensaje de respuesta RTSP en texto (ej. "RTSP/1.0 200 OK...")
                guard let crlfcrlf = tcpBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                    // Descartar bytes corruptos hasta el próximo '$' o 'RTSP'
                    if !tcpBuffer.starts(with: [0x24]) && !tcpBuffer.starts(with: "RTSP".utf8) {
                        if let nextMarker = tcpBuffer.firstIndex(of: 0x24) {
                            tcpBuffer.removeSubrange(0..<nextMarker)
                        } else {
                            tcpBuffer.removeAll(keepingCapacity: true)
                        }
                    }
                    return
                }

                let headerData = tcpBuffer.subdata(in: 0..<crlfcrlf.lowerBound)
                var skipLen = crlfcrlf.upperBound

                if let headerText = String(data: headerData, encoding: .utf8) {
                    var contentLength = 0
                    for line in headerText.components(separatedBy: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            let parts = line.components(separatedBy: ":")
                            if parts.count >= 2 {
                                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                            }
                        }
                    }

                    if contentLength > 0 {
                        guard tcpBuffer.count >= skipLen + contentLength else {
                            // Esperar que el cuerpo SDP termine de llegar
                            return
                        }
                        let bodyData = tcpBuffer.subdata(in: skipLen..<skipLen + contentLength)
                        skipLen += contentLength
                        tcpBuffer.removeSubrange(0..<skipLen)
                        handleRTSPResponse(headerText: headerText, body: bodyData)
                    } else {
                        tcpBuffer.removeSubrange(0..<skipLen)
                        handleRTSPResponse(headerText: headerText, body: nil)
                    }
                } else {
                    tcpBuffer.removeSubrange(0..<skipLen)
                }
            }
        }
    }

    private func handleRTSPResponse(headerText: String, body: Data?) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }

        // Extraer código de estado HTTP/RTSP
        let parts = first.components(separatedBy: " ")
        let statusCode = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0

        guard statusCode == 200 else {
            print("[NativeRTSP] Error de servidor RTSP (\(state)): \(first)")
            showError("Cámara respondió: \(first)")
            return
        }

        // Extraer Session ID si está presente
        for line in lines {
            if line.lowercased().hasPrefix("session:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let full = parts[1].trimmingCharacters(in: .whitespaces)
                    self.sessionId = full.components(separatedBy: ";").first
                }
            }
        }

        switch state {
        case .waitingOptions:
            print("[NativeRTSP] OPTIONS 200 OK. Solicitando DESCRIBE...")
            sendDescribe()

        case .waitingDescribe:
            print("[NativeRTSP] DESCRIBE 200 OK. Procesando SDP...")
            var sdpString = ""
            if let b = body, let str = String(data: b, encoding: .utf8) {
                sdpString = str
            }
            // Parsear SPS y PPS desde sprop-parameter-sets en el SDP
            parseSDP(sdpString)

            // Extraer control track de la sección m=video
            let trackURL = extractVideoTrackURL(from: sdpString, baseURL: streamURL)
            print("[NativeRTSP] Pista de vídeo: \(trackURL). Solicitando SETUP...")
            sendSetup(trackPath: trackURL)

        case .waitingSetup:
            print("[NativeRTSP] SETUP 200 OK (Session: \(sessionId ?? "none")). Solicitando PLAY...")
            sendPlay()

        case .waitingPlay:
            print("[NativeRTSP] PLAY 200 OK. Flujo RTSP activo!")
            state = .streaming
            startKeepalive()

        case .streaming:
            // Respuesta de keepalive periódico u otra petición durante streaming; nada que hacer
            break

        default:
            break
        }
    }

    private func extractVideoTrackURL(from sdp: String, baseURL: String) -> String {
        let lines = sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var inVideoSection = false
        var trackControl: String? = nil

        for line in lines {
            if line.hasPrefix("m=video") {
                inVideoSection = true
                continue
            }
            if inVideoSection && line.hasPrefix("m=") {
                break
            }
            if inVideoSection && line.hasPrefix("a=control:") {
                let ctrl = String(line.dropFirst("a=control:".count)).trimmingCharacters(in: .whitespaces)
                if !ctrl.isEmpty && ctrl != "*" {
                    trackControl = ctrl
                    break
                }
            }
        }

        guard let ctrl = trackControl else {
            print("[NativeRTSP] a=control no hallado en m=video, usando track1 por defecto.")
            return "\(baseURL)/track1"
        }

        if ctrl.hasPrefix("rtsp://") {
            return ctrl
        }
        if ctrl.hasPrefix("/") {
            if let host = URL(string: baseURL)?.host {
                return "rtsp://\(host)\(ctrl)"
            }
        }
        let cleanBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(cleanBase)/\(ctrl)"
    }

    private func parseSDP(_ sdp: String) {
        // Extraer parámetros SPS y PPS (sprop-parameter-sets)
        if let range = sdp.range(of: "sprop-parameter-sets=") {
            let sub = sdp[range.upperBound...]
            let line = sub.components(separatedBy: .newlines).first?.components(separatedBy: ";").first ?? ""
            let parts = line.components(separatedBy: ",")
            if parts.count >= 2 {
                if let s = Data(base64Encoded: parts[0].trimmingCharacters(in: .whitespaces)),
                   let p = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) {
                    print("[NativeRTSP] SPS (\(s.count) bytes) y PPS (\(p.count) bytes) obtenidos del SDP.")
                    self.spsData = s
                    self.ppsData = p
                    createFormatDescription()
                }
            }
        }
    }

    // MARK: - Depacketización RTP H.264 (RFC 6184)

    private func processRTPPacket(_ rtp: Data) {
        guard rtp.count >= 12 else { return }

        let b0 = rtp[0]
        let cc = Int(b0 & 0x0F)
        var offset = 12 + (cc * 4)

        // Saltar extensión RTP si existe (bit X)
        if (b0 & 0x10) != 0, rtp.count >= offset + 4 {
            let extLen = (Int(rtp[offset + 2]) << 8) | Int(rtp[offset + 3])
            offset += 4 + (extLen * 4)
        }

        guard rtp.count > offset else { return }

        // Extraer Marker bit (último paquete del cuadro de vídeo) y timestamp
        let markerBit = (rtp[1] & 0x80) != 0
        let timestamp = (UInt32(rtp[4]) << 24) | (UInt32(rtp[5]) << 16) | (UInt32(rtp[6]) << 8) | UInt32(rtp[7])

        let payload = rtp.subdata(in: offset..<rtp.count)
        guard !payload.isEmpty else { return }

        let nalHeader = payload[0]
        let nalType = Int(nalHeader & 0x1F)

        switch nalType {
        case 1...23:
            // NAL unit individual
            appendNALToFrame(payload, timestamp: timestamp, marker: markerBit)

        case 24:
            // STAP-A: Agregación simple de NALs (SPS + PPS)
            var pOffset = 1
            while pOffset + 2 <= payload.count {
                let nSize = (Int(payload[pOffset]) << 8) | Int(payload[pOffset + 1])
                pOffset += 2
                if pOffset + nSize <= payload.count {
                    let subNAL = payload.subdata(in: pOffset..<pOffset + nSize)
                    appendNALToFrame(subNAL, timestamp: timestamp, marker: markerBit)
                    pOffset += nSize
                } else {
                    break
                }
            }

        case 28:
            // FU-A: Fragmentación de un NAL grande entre varios paquetes RTP
            guard payload.count >= 2 else { return }
            let fuHeader = payload[1]
            let startBit = (fuHeader & 0x80) != 0
            let endBit = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x1F
            let fragment = payload.subdata(in: 2..<payload.count)

            if startBit {
                let reconstructedHeader = (nalHeader & 0xE0) | originalType
                fuAssemblyBuffer.removeAll(keepingCapacity: true)
                fuAssemblyBuffer.append(reconstructedHeader)
                fuAssemblyBuffer.append(fragment)
                isAssemblingFU = true
            } else if isAssemblingFU {
                fuAssemblyBuffer.append(fragment)
                if endBit {
                    appendNALToFrame(fuAssemblyBuffer, timestamp: timestamp, marker: markerBit)
                    fuAssemblyBuffer.removeAll(keepingCapacity: true)
                    isAssemblingFU = false
                }
            }

        default:
            break
        }
    }

    // MARK: - Ensamblado de Cuadros (Access Units)

    private func appendNALToFrame(_ nal: Data, timestamp: UInt32, marker: Bool) {
        guard !nal.isEmpty else { return }
        let nalType = Int(nal[0] & 0x1F)

        // Parámetros de configuración H.264
        if nalType == 7 { // SPS
            self.spsData = nal
            createFormatDescription()
            return
        } else if nalType == 8 { // PPS
            self.ppsData = nal
            createFormatDescription()
            return
        } else if nalType == 6 || nalType == 9 { // SEI o Delimitador de Acceso
            return
        }

        // Si el timestamp cambió y ya teníamos slices acumuladas, despachar el cuadro anterior
        if let currentTs = currentFrameTimestamp, currentTs != timestamp {
            dispatchCurrentFrame()
        }

        // Acumular NAL para el cuadro actual
        currentFrameTimestamp = timestamp
        currentFrameNALs.append(nal)
        if nalType == 5 {
            isCurrentFrameKeyframe = true
        }

        // Si el paquete RTP tiene el Marker bit en 1, el cuadro está completo
        if marker {
            dispatchCurrentFrame()
        }
    }

    private func dispatchCurrentFrame() {
        guard !currentFrameNALs.isEmpty, let ts = currentFrameTimestamp else { return }
        let nals = currentFrameNALs
        let isKey = isCurrentFrameKeyframe

        // Limpiar para el siguiente cuadro
        currentFrameNALs.removeAll(keepingCapacity: true)
        currentFrameTimestamp = nil
        isCurrentFrameKeyframe = false

        decodeAndDisplayAccessUnit(nals, timestamp: ts, isKeyframe: isKey)
    }

    // MARK: - VideoToolbox & AVSampleBufferDisplayLayer

    private func createFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                guard let spsPtr = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]

                var desc: CMFormatDescription?
                let status = pointers.withUnsafeBufferPointer { ptrsBuffer in
                    sizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrsBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }

                if status == noErr, let formatDesc = desc {
                    self.formatDescription = formatDesc
                    print("[NativeRTSP] FormatDescription H.264 creado exitosamente.")
                    self.createDecompressionSession()
                } else {
                    print("[NativeRTSP] Error creando FormatDescription: \(status)")
                }
            }
        }
    }

    private func createDecompressionSession() {
        guard let desc = self.formatDescription else { return }

        if let oldSession = decompressionSession {
            VTDecompressionSessionInvalidate(oldSession)
            decompressionSession = nil
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                Metal360Renderer.shared.updatePixelBuffer(pixelBuffer)
            },
            decompressionOutputRefCon: nil
        )

        let destinationPixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            videoDecoderSpecification: nil,
            destinationImageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        if status == noErr, let sess = newSession {
            self.decompressionSession = sess
            print("[NativeRTSP] VTDecompressionSession creada exitosamente para Metal.")
        } else {
            print("[NativeRTSP] Error creando VTDecompressionSession: \(status)")
        }
    }

    private func decodeAndDisplayAccessUnit(_ nals: [Data], timestamp: UInt32, isKeyframe: Bool) {
        guard let formatDesc = self.formatDescription else { return }

        // Empaquetar todas las NALs del cuadro en formato AVCC (prefijadas con 4 bytes de longitud big-endian)
        var totalLength = 0
        for nal in nals {
            totalLength += 4 + nal.count
        }

        var blockData = Data(capacity: totalLength)
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { blockData.append(contentsOf: $0) }
            blockData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else { return }

        _ = blockData.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: buffer,
                    offsetIntoDestination: 0,
                    dataLength: totalLength
                )
            }
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = totalLength

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Adjuntar bandera para renderizado inmediato en GPU sin retrasos de reloj
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())

            if isKeyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
            } else {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        // Decodificación por hardware VideoToolbox para renderizado Metal 360 cosido en tiempo real
        if let sess = self.decompressionSession {
            var flagsOut = VTDecodeInfoFlags(rawValue: 0)
            let dStatus = VTDecompressionSessionDecodeFrame(
                sess,
                sampleBuffer: sb,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flagsOut
            )
            if dStatus == kVTInvalidSessionErr {
                createDecompressionSession()
            }
        }

        // Registrar métrica de cuadros y hora del último cuadro
        let now = CACurrentMediaTime()
        self.lastFrameReceivedTime = now
        self.frameCount += 1

        if now - self.lastFpsCalculationTime >= 1.0 {
            let calculatedFps = Double(self.frameCount) / (now - self.lastFpsCalculationTime)
            self.frameCount = 0
            self.lastFpsCalculationTime = now
            DispatchQueue.main.async {
                self.fps = (calculatedFps * 10).rounded() / 10
            }
        }

        // Renderizado directo en AVSampleBufferDisplayLayer
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let layer = self.targetDisplayLayer else { return }

            if !self.isPlaying {
                self.isPlaying = true
                self.isConnecting = false
            }

            if layer.status == .failed {
                print("[NativeRTSP] DisplayLayer en estado failed. Reiniciando con flush()...")
                layer.flush()
            }

            layer.enqueue(sb)
        }
    }

    // MARK: - Watchdog y Manejo de Errores

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            if self.state == .streaming && self.isPlaying && (now - self.lastFrameReceivedTime > 5.0) {
                print("[NativeRTSP] Watchdog: Flujo detenido durante más de 5s. Reconectando...")
                self.resetState()
                self.connectSocket()
            }
        }
        timer.resume()
        self.watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func showError(_ msg: String) {
        DispatchQueue.main.async {
            self.errorMessage = msg
            self.isConnecting = false
            self.isPlaying = false
        }
    }
}
