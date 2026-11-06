import Foundation
import Network
import Combine

/// Administrador central de la conexión TCP con la Xiaomi Mi Sphere 360 (192.168.42.1:7878)
public class CameraManager: ObservableObject {
    public static let shared = CameraManager()

    public static let cameraIP = "192.168.42.1"
    public static let controlPort: UInt16 = 7878
    public static let httpPort = 50422

    // Estado publicado a la UI de SwiftUI
    @Published public var isConnected = false
    @Published public var isConnecting = false
    @Published public var sessionToken: Int = 0
    @Published public var batteryPercent: Int = 0
    @Published public var isCharging = false
    @Published public var isRecording = false
    @Published public var currentMode: Int = 1 // 1: Foto, 0: Video
    @Published public var isLiveStreaming = false
    @Published public var lastStatusMessage: String = "Desconectado"
    @Published public var photoRes: Int = 0
    @Published public var iso: Int = 0
    @Published public var shutter: String = "Auto"
    @Published public var ev: Double = 0.0
    @Published public var wb: Int = 0
    @Published public var timer: Int = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ssombra.misphere360.tcp", qos: .userInitiated)
    private var heartbeatTimer: Timer?
    private var receiveBuffer = ""

    public init() {}

    // MARK: - Conexión y Desconexión

    public func connect() {
        guard !isConnected && !isConnecting else { return }
        DispatchQueue.main.async {
            self.isConnecting = true
            self.lastStatusMessage = "Conectando con la cámara..."
        }

        let host = NWEndpoint.Host(CameraManager.cameraIP)
        let port = NWEndpoint.Port(rawValue: CameraManager.controlPort)!
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        connection = NWConnection(host: host, port: port, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.startReceiving()
                    self.authenticateSession()
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isConnecting = false
                    self.lastStatusMessage = "Error de conexión: \(error.localizedDescription)"
                }
                self.cleanupConnection()
            case .cancelled:
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isConnecting = false
                    self.lastStatusMessage = "Desconectado"
                }
                self.cleanupConnection()
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    public func disconnect() {
        if isConnected && sessionToken > 0 {
            sendCommand(msgId: 258, param: nil) // MSG_DISCONNECT
        }
        stopHeartbeat()
        connection?.cancel()
        cleanupConnection()
    }

    private func cleanupConnection() {
        connection = nil
        receiveBuffer = ""
        stopHeartbeat()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.sessionToken = 0
            self.isLiveStreaming = false
        }
    }

    // MARK: - Autenticación y Heartbeat (45s para mantenerla fresca)

    private func authenticateSession() {
        let authPacket: [String: Any] = ["msg_id": 257, "token": 0]
        sendRawJSON(authPacket)
    }

    private func startHeartbeat() {
        DispatchQueue.main.async {
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isConnected else { return }
                self.fetchBatteryStatus()
            }
        }
    }

    private func stopHeartbeat() {
        DispatchQueue.main.async {
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
        }
    }

    // MARK: - Envío y Recepción TCP

    public func sendCommand(msgId: Int, param: Any? = nil) {
        guard let connection = connection, connection.state == .ready else { return }
        var packet: [String: Any] = [
            "msg_id": msgId,
            "token": sessionToken
        ]
        if let param = param {
            packet["param"] = param
        }
        sendRawJSON(packet)
    }

    private func sendRawJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        let wireData = jsonString.data(using: .utf8) ?? data
        connection?.send(content: wireData, completion: .contentProcessed({ error in
            if let error = error {
                print("Error enviando TCP: \(error)")
            }
        }))
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty,
               let str = String(data: data, encoding: .utf8) {
                self.processIncomingChunk(str)
            }
            if isComplete || error != nil {
                self.disconnect()
            } else {
                self.startReceiving()
            }
        }
    }

    private func processIncomingChunk(_ chunk: String) {
        receiveBuffer.append(chunk)
        while let openIdx = receiveBuffer.firstIndex(of: "{") {
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<openIdx)
            var depth = 0
            var closeIdx: String.Index?
            for idx in receiveBuffer.indices {
                if receiveBuffer[idx] == "{" { depth += 1 }
                else if receiveBuffer[idx] == "}" {
                    depth -= 1
                    if depth == 0 {
                        closeIdx = idx
                        break
                    }
                }
            }
            guard let end = closeIdx else { break }
            let jsonSub = String(receiveBuffer[receiveBuffer.startIndex...end])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...end)
            if let d = jsonSub.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                handleParsedJSON(obj)
            }
        }
    }

    private func handleParsedJSON(_ obj: [String: Any]) {
        let msgId = obj["msg_id"] as? Int ?? 0
        let rval = obj["rval"] as? Int ?? -1

        DispatchQueue.main.async {
            switch msgId {
            case 257: // CONNECT
                if rval == 0, let tok = obj["param"] as? Int {
                    self.sessionToken = tok
                    self.isConnected = true
                    self.isConnecting = false
                    self.lastStatusMessage = "Cámara Conectada (Token \(tok))"
                    self.startHeartbeat()
                    self.fetchInitialState()
                } else {
                    self.lastStatusMessage = "Conexión rechazada por la cámara"
                    self.disconnect()
                }

            case 4361: // BATERÍA
                if let raw = obj["param"] as? Int {
                    self.isCharging = raw > 100
                    let pct = raw >= 128 ? raw - 128 : raw
                    self.batteryPercent = max(0, min(100, pct))
                }

            case 4364: // GET_DEVICE
                if let pres = obj["p_res"] as? Int { self.photoRes = pres }
                if let wb = obj["still_wb"] as? Int { self.wb = wb }
                if let iso = obj["still_iso"] as? Int { self.iso = iso }
                if let ev = obj["still_ev"] as? Int { self.ev = Double(ev) / 2.0 }

            case 4365: // GET_CAMERA
                if let mode = obj["mode"] as? Int { self.currentMode = mode }
                if let rec = obj["rec_time"] as? Int { self.isRecording = rec > 0 }
                if let timing = obj["timing"] as? Int { self.timer = timing }

            case 4864, 4868: // DISPARO FOTO
                if rval == 0 {
                    self.lastStatusMessage = "¡Foto capturada!"
                }

            case 5028: // INICIO VIDEO
                if rval == 0 { self.isRecording = true; self.lastStatusMessage = "Grabando video..." }

            case 514: // FIN VIDEO
                if rval == 0 { self.isRecording = false; self.lastStatusMessage = "Video guardado." }

            case 4917: // SET_GPS
                if rval == 0 {
                    // Coordenadas inyectadas con éxito en el firmware de la cámara
                }

            default:
                break
            }
        }
    }

    // MARK: - Acciones de Captura y Ajustes

    public func fetchInitialState() {
        sendCommand(msgId: 4364, param: nil) // Device status
        sendCommand(msgId: 4365, param: nil) // Camera status
        sendCommand(msgId: 4361, param: nil) // Battery
    }

    public func fetchBatteryStatus() {
        sendCommand(msgId: 4361, param: nil)
    }

    public func takePhoto() {
        if timer > 0 {
            sendCommand(msgId: 4868, param: nil) // Foto con timer
        } else {
            sendCommand(msgId: 4864, param: nil) // Foto directa
        }
    }

    public func toggleVideoRecording() {
        if isRecording {
            sendCommand(msgId: 514, param: nil)
        } else {
            sendCommand(msgId: 5028, param: nil)
        }
    }

    public func switchMode(_ mode: Int) {
        sendCommand(msgId: 4611, param: mode)
        DispatchQueue.main.async { self.currentMode = mode }
    }

    public func setISO(_ val: Int) {
        sendCommand(msgId: 5172, param: val)
        DispatchQueue.main.async { self.iso = val }
    }

    public func setEV(_ val: Double) {
        let param = Int(val * 2.0)
        sendCommand(msgId: 5169, param: param)
        DispatchQueue.main.async { self.ev = val }
    }

    public func setWB(_ val: Int) {
        sendCommand(msgId: 5168, param: val)
        DispatchQueue.main.async { self.wb = val }
    }

    public func setTimer(_ val: Int) {
        sendCommand(msgId: 4866, param: val)
        DispatchQueue.main.async { self.timer = val }
    }

    public func setGPS(latitude: Double, longitude: Double, altitude: Double) {
        guard isConnected else { return }
        let gpsString = String(format: "%.6f,%.6f,%.1f", latitude, longitude, altitude)
        sendCommand(msgId: 4917, param: gpsString)
    }

    public func setLiveView(enabled: Bool) {
        if enabled {
            sendCommand(msgId: 259, param: nil) // MSG_START_LIVE
        } else {
            sendCommand(msgId: 260, param: nil) // MSG_STOP_LIVE
        }
        DispatchQueue.main.async { self.isLiveStreaming = enabled }
    }

    public func powerOffCamera() {
        sendCommand(msgId: 6155, param: nil)
        disconnect()
    }
}
