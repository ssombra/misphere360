import Foundation
import Network
import Combine
import UIKit

/// Modelo de archivo en la tarjeta microSD de la cámara
public struct SDFileItem: Identifiable, Hashable {
    public var id: String { "\(folder)/\(filename)" }
    public let folder: String
    public let filename: String
    public let isVideo: Bool
    public let date: String
    public var httpURL: URL {
        let clean = filename.hasSuffix("AA.JPG") ? String(filename.dropLast(6)) + ".JPG" : filename
        return URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/\(folder)/\(clean)")!
    }
}

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
    @Published public var lastStatusMessage: String = "Desconectado"
    @Published public var isLiveViewActive = false
    @Published public var liveViewStatus = ""

    // FOTO
    @Published public var photoRes: Int = 0          // 0: DualFisheye 6912, 1: 3456, 2: 6912, 3: RAW
    @Published public var photoSubMode: Int = 0      // 0: Normal, 1: Timer, 2: Interval, 4: Bracketing
    @Published public var iso: Int = 0              // 0: Auto, 50, 100, 200, 400, 800, 1600
    @Published public var shutter: String = "Auto"
    @Published public var shutterRaw: Int = 0
    @Published public var ev: Double = 0.0          // -3.0 a +3.0
    @Published public var wb: Int = 0               // 0: Auto, 1: Sol, 2: Nube, 3: Incand, 4: Fluor
    @Published public var timer: Int = 0            // 0, 3, 4, 5, 6, 7, 8, 9, 10 s
    @Published public var photoInterval: Int = 0    // 0, 2, 5, 10, 30, 60, 120, 300 s
    @Published public var photoBracketing: Int = 0  // param = int(2 * ev)

    // VIDEO
    @Published public var videoRes: Int = 0         // 0: 3.5K, 1: 2.3K@30, 2: 2.3K@60, 7: 120fps, 9: Bullet, 10: HighBitrate
    @Published public var videoSubMode: Int = 0     // 0: Normal, 1: Short, 2: Timelapse, 4: SlowMo
    @Published public var videoShort: Int = 0       // 0, 10, 20, 30 s
    @Published public var videoTimelapse: Int = 0   // 0, 255(0.5s), 1, 2, 5, 10, 30, 60 s
    @Published public var videoSlowMo: Int = 0      // 0: Normal, 1: 2x
    @Published public var videoEV: Double = 0.0
    @Published public var videoWB: Int = 0
    @Published public var videoLoop: Int = 0        // 0: Desactivado, 1: 1 min, 2: 2 min, 5: 5 min

    // HARDWARE / AJUSTES DEL SISTEMA
    @Published public var buzzerLevel: Int = 4      // 0: Silencio, 1: Bajo, 2: Medio, 4: Alto
    @Published public var autoOffMinutes: Int = 10  // 0: Off, 5 min, 10 min
    @Published public var ledEnabled: Bool = true

    // ESTADO DE CAPTURA AVANZADA
    @Published public var isIntervalRunning: Bool = false
    @Published public var countdownRemaining: Int = 0
    private var countdownTimer: Timer?

    // ALMACENAMIENTO SD
    @Published public var sdTotalMB: Int = 0
    @Published public var sdFreeMB: Int = 0
    @Published public var remainJPG: Int = 0
    @Published public var remainVideo: Int = 0
    @Published public var dcimFolders: [String] = []

    // CONEXIÓN WI-FI DE LA CÁMARA
    @Published public var wifiSSID: String = ""
    @Published public var wifiPassword: String = ""

    // MODO DE PREVISUALIZACIÓN 360°
    @Published public var previewMode: String = "Mirror ball"

    // INFORMACIÓN DEL DISPOSITIVO
    @Published public var deviceName: String = ""
    @Published public var serialNumber: String = ""
    @Published public var firmwareVersion: String = ""

    public var formattedStorageSpace: String {
        guard isConnected, sdTotalMB > 0 else { return isConnected ? "Calculando..." : "No disponible" }
        let freeGB = Double(sdFreeMB) / 1024.0
        let totalGB = Double(sdTotalMB) / 1024.0
        return String(format: "%.2f GB libres de %.2f GB", freeGB, totalGB)
    }

    public var formattedRemainVideo: String {
        guard isConnected, remainVideo > 0 else { return isConnected ? "Calculando..." : "No disponible" }
        let totalSeconds = remainVideo > 500 ? remainVideo : remainVideo * 60
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes) min"
        }
    }

    // Callbacks pendientes para comandos TCP asíncronos (ej. list_dir)
    // Callbacks pendientes para comandos TCP asíncronos (cola FIFO por msgId)
    private var pendingCallbacks: [Int: [([String: Any]) -> Void]] = [:]
    private var lastSendTime: TimeInterval = 0.0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ssombra.misphere360.tcp", qos: .userInitiated)
    private var watchdogTimer: DispatchSourceTimer?
    private var handshakeTimeoutItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isUserDisconnected = false
    private var receiveBuffer = ""

    public init() {
        loadPersistedSettings()
        startWatchdog()
    }

    deinit {
        stopWatchdog()
    }

    // MARK: - Reconexión Automática y Watchdog en Segundo Plano

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 2.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.isUserDisconnected {
                if !self.isConnected && !self.isConnecting {
                    self.connect()
                } else if self.isConnected {
                    let now = Date().timeIntervalSince1970
                    // Heartbeat cada 15 segundos para evitar que la cámara cierre la sesión TCP
                    if now - self.lastSendTime > 15.0 {
                        self.fetchBatteryStatus()
                    }
                }
            }
        }
        timer.resume()
        self.watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    public func checkAndReconnectIfNeeded() {
        isUserDisconnected = false
        if !isConnected && !isConnecting {
            connect()
        }
    }

    public func scheduleAutoReconnect(delay: Double = 1.0) {
        guard !isUserDisconnected else { return }
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isConnected, !self.isConnecting, !self.isUserDisconnected else { return }
            self.connect()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Conexión y Desconexión

    public func connect() {
        guard !isConnected && !isConnecting else { return }
        isUserDisconnected = false

        DispatchQueue.main.async {
            self.isConnecting = true
            self.lastStatusMessage = "Conectando con la cámara..."
        }

        let host = NWEndpoint.Host(CameraManager.cameraIP)
        let port = NWEndpoint.Port(rawValue: CameraManager.controlPort)!
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
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
                print("TCP conexión falló: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isConnecting = false
                    self.lastStatusMessage = "Reconectando..."
                }
                self.cleanupConnection()
                self.scheduleAutoReconnect(delay: 1.5)
            case .cancelled:
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isConnecting = false
                }
                self.cleanupConnection()
                if !self.isUserDisconnected {
                    self.scheduleAutoReconnect(delay: 1.0)
                }
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    public func disconnect() {
        isUserDisconnected = true
        handshakeTimeoutItem?.cancel()
        reconnectWorkItem?.cancel()
        if isConnected && sessionToken > 0 {
            sendCommand(msgId: 258, param: nil) // MSG_DISCONNECT
        }
        connection?.cancel()
        cleanupConnection()
    }

    private func cleanupConnection() {
        handshakeTimeoutItem?.cancel()
        queue.async {
            self.connection = nil
            self.receiveBuffer = ""
            self.pendingCallbacks.removeAll()
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.sessionToken = 0
            self.isIntervalRunning = false
        }
    }

    // MARK: - Autenticación

    private func authenticateSession() {
        queue.async {
            let authPacket: [String: Any] = ["msg_id": 257, "token": 0]
            self.sendRawJSON(authPacket)
            self.lastSendTime = Date().timeIntervalSince1970

            // Timeout de apretón de manos (5 segundos)
            self.handshakeTimeoutItem?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isConnected else { return }
                print("Apretón 257 agotó tiempo, reintentando...")
                self.cleanupConnection()
                self.scheduleAutoReconnect(delay: 0.5)
            }
            self.handshakeTimeoutItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeout)
        }
    }

    // MARK: - Envío y Recepción TCP (Garantizando param como String y pausa mínima)

    public func sendCommand(msgId: Int, param: Any? = nil, onResponse: (([String: Any]) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self, let connection = self.connection, connection.state == .ready else { return }

            // Respetar pausa mínima de 0.3s como exige el firmware Ambarella para no ignorar paquetes
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastSendTime
            if elapsed < 0.30 {
                Thread.sleep(forTimeInterval: 0.30 - elapsed)
            }

            var packet: [String: Any] = [
                "msg_id": msgId,
                "token": self.sessionToken
            ]
            // REGLA CRÍTICA AMBARELLA: Todo parámetro debe enviarse como String
            if let param = param {
                packet["param"] = String(describing: param)
            }

            if let onResponse = onResponse {
                self.pendingCallbacks[msgId, default: []].append(onResponse)
            }

            self.sendRawJSON(packet)
            self.lastSendTime = Date().timeIntervalSince1970
        }
    }

    public func sendCustomPacket(_ dict: [String: Any], msgId: Int, onResponse: (([String: Any]) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self, let connection = self.connection, connection.state == .ready else {
                onResponse?(["rval": -1, "error": "No conectado"])
                return
            }

            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastSendTime
            if elapsed < 0.30 {
                Thread.sleep(forTimeInterval: 0.30 - elapsed)
            }

            var packet = dict
            if packet["token"] == nil {
                packet["token"] = self.sessionToken
            }
            if packet["msg_id"] == nil {
                packet["msg_id"] = msgId
            }

            if let onResponse = onResponse {
                self.pendingCallbacks[msgId, default: []].append(onResponse)
            }

            self.sendRawJSON(packet)
            self.lastSendTime = Date().timeIntervalSince1970
        }
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
                print("Socket TCP cerrado por cámara (isComplete=\(isComplete), err=\(String(describing: error)))")
                self.cleanupConnection()
                if !self.isUserDisconnected {
                    self.scheduleAutoReconnect(delay: 1.0)
                }
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

        // Si había un callback esperando este msgId, ejecutar el primero en cola (FIFO)
        var callbackToRun: (([String: Any]) -> Void)? = nil
        if let list = pendingCallbacks[msgId], !list.isEmpty {
            callbackToRun = pendingCallbacks[msgId]?.removeFirst()
        }
        if let cb = callbackToRun {
            DispatchQueue.main.async { cb(obj) }
        }

        DispatchQueue.main.async {
            switch msgId {
            case 257: // CONNECT
                self.handshakeTimeoutItem?.cancel()
                if rval == 0, let tok = obj["param"] as? Int {
                    self.sessionToken = tok
                    self.isConnected = true
                    self.isConnecting = false
                    self.lastStatusMessage = "Cámara Conectada"
                    self.syncCameraDate()
                    self.syncSettingsToCamera()
                    self.fetchInitialState()
                } else {
                    self.lastStatusMessage = "Reconectando con la cámara..."
                    self.cleanupConnection()
                    self.scheduleAutoReconnect(delay: 1.0)
                }

            case 4361: // BATERÍA
                let rawVal: Int? = (obj["param"] as? Int) ?? (Int(obj["param"] as? String ?? ""))
                if let raw = rawVal {
                    self.updateBattery(from: raw)
                }

            case 4358: // ALMACENAMIENTO SD
                if let free = obj["sd_free"] as? Int { self.sdFreeMB = free / 1024 }
                if let total = obj["sd_total"] as? Int { self.sdTotalMB = total / 1024 }
                if let rjpg = obj["remain_jpg"] as? Int { self.remainJPG = rjpg }
                if let rvid = obj["remain_video"] as? Int { self.remainVideo = rvid }

            case 1539: // GET_WIFI
                if let paramStr = obj["param"] as? String {
                    for line in paramStr.components(separatedBy: "\n") {
                        let parts = line.components(separatedBy: "=")
                        if parts.count >= 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            let val = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            if key == "AP_SSID" { self.wifiSSID = val }
                            else if key == "AP_PASSWD" { self.wifiPassword = val }
                        }
                    }
                }

            case 4097: // GET_SERIAL_NO
                if let sn = obj["param"] as? String, self.serialNumber.isEmpty {
                    self.serialNumber = sn
                }

            case 4364: // GET_DEVICE
                if let b = obj["battery"] as? Int { self.updateBattery(from: b) }
                if let sn = obj["sn"] as? String { self.serialNumber = sn }
                if let product = obj["product"] as? String { self.deviceName = product }
                if let ver = obj["ver"] as? String {
                    let mainVer = ver.components(separatedBy: ";").first ?? ver
                    self.firmwareVersion = mainVer
                }
                if let cjpg = obj["cam_jpg"] as? Int, self.remainJPG == 0 { self.remainJPG = cjpg }
                if let cmp4 = obj["cam_mp4"] as? Int, self.remainVideo == 0 { self.remainVideo = cmp4 * 60 }

                // Si aún no hay ajustes guardados en la app, poblar con lo que tiene la cámara:
                if !UserDefaults.standard.bool(forKey: "cam_hasSavedSettings") {
                    if let pres = obj["p_res"] as? Int { self.photoRes = pres }
                    if let vres = obj["v_res"] as? Int { self.videoRes = vres }
                    if let loopVal = obj["loop"] as? Int { self.videoLoop = loopVal }
                    if let wb = obj["still_wb"] as? Int { self.wb = wb }
                    if let iso = obj["still_iso"] as? Int { self.iso = iso }
                    if let ev = obj["still_ev"] as? Int { self.ev = Double(ev) / 2.0 }
                    if let sht = obj["still_shutter"] as? Int {
                        self.shutterRaw = sht
                        self.shutter = self.decodeShutter(sht)
                    }
                    if let vwb = obj["video_wb"] as? Int { self.videoWB = vwb }
                    if let vev = obj["video_ev"] as? Int { self.videoEV = Double(vev) / 2.0 }
                    if let bzr = obj["buzzer"] as? Int { self.buzzerLevel = bzr }
                    if let poff = obj["poweroff_time"] as? Int { self.autoOffMinutes = poff }
                    if let ledVal = obj["led"] as? Int { self.ledEnabled = (ledVal != 0) }
                }

            case 4365: // GET_CAMERA
                if let rec = obj["rec_time"] as? Int { self.isRecording = rec > 0 }
                let sm = obj["sub_mode"] as? Int ?? -1
                let tim = obj["timing"] as? Int ?? -1
                let capInt = obj["cap_interval"] as? Int ?? -1
                let brk = obj["surroundexp"] as? Int ?? -1
                let capNum = obj["cap_interval_num"] as? Int ?? -1
                let burstNum = obj["burst_num"] as? Int ?? -1

                self.lastStatusMessage = "4365: sub=\(sm) | HDR=\(brk) | Int=\(capInt)s | Timer=\(tim)s (num:\(capNum),bst:\(burstNum))"
                print("📸 GET_CAMERA_4365: \(obj)")

                // Si aún no hay ajustes guardados en la app, poblar con lo que tiene la cámara:
                if !UserDefaults.standard.bool(forKey: "cam_hasSavedSettings") {
                    if let mode = obj["mode"] as? Int { self.currentMode = mode }
                    if let timing = obj["timing"] as? Int { self.timer = timing }
                    if let interval = obj["cap_interval"] as? Int { self.photoInterval = interval }
                    if let brkVal = obj["surroundexp"] as? Int { self.photoBracketing = brkVal }
                    if let sec = obj["second"] as? Int { self.videoShort = sec }
                    if let lapse = obj["lapse"] as? Int { self.videoTimelapse = lapse }
                    if let spd = obj["speedx"] as? Int { self.videoSlowMo = spd == 2 ? 1 : 0 }
                    self.updatePhotoSubMode()
                }

            case 4866, 4918, 4929: // RESPUESTA A TIMER, HDR O INTERVALO
                print("📡 Respuesta msgId=\(msgId): rval=\(rval)")
                if rval == 0 {
                    self.lastStatusMessage = "✅ msgId \(msgId) OK (rval:0) -> consultando 4365..."
                    self.sendCommand(msgId: 4365, param: nil)
                } else {
                    self.lastStatusMessage = "❌ msgId \(msgId) RECHAZADO (rval:\(rval))"
                }

            case 4611, 4612, 4614, 4615, 4618, 4621, 4872, 4916, 5136, 5137, 5168, 5169, 5171, 5172, 6145, 6151, 6156:
                if rval == 0 {
                    print("✅ Parámetro registrado con éxito en la memoria de la cámara (msgId=\(msgId))")
                } else {
                    print("⚠️ Aviso: Cámara respondió rval=\(rval) al msgId=\(msgId)")
                }

            case 4864, 4868: // DISPARO FOTO
                if rval == 0 {
                    self.lastStatusMessage = "Disparo \(msgId) OK (rval:\(rval)). Esperando captura..."
                    LocationManager.shared.recordCurrentShotLocation()
                    // No bombardear con refreshStatus() durante la captura para no cancelar ráfagas/intervalos
                }

            case 5028: // INICIO VIDEO
                if rval == 0 { self.isRecording = true; self.lastStatusMessage = "Grabando video..." }

            case 514: // FIN VIDEO
                if rval == 0 { self.isRecording = false; self.lastStatusMessage = "Video guardado." }

            case 6165: // GYRO_CALIB
                if rval == 0 { self.lastStatusMessage = "Giroscopio calibrado." }

            case 8192, 8193: // EVENTO ASÍNCRONO DE FOTO (8193) O VIDEO (8192) GUARDADO
                if msgId == 8193 {
                    // Foto disparada físicamente en la cámara: congelar GPS de ese segundo exacto
                    LocationManager.shared.recordCurrentShotLocation()
                    self.lastStatusMessage = "📸 Foto guardada en SD (8193)"
                    NotificationCenter.default.post(name: NSNotification.Name("CameraPhotoSavedNotification"), object: nil)
                }
                self.fetchBatteryStatus()
                self.fetchStorageStatus()

            default:
                break
            }
        }
    }

    // MARK: - Sincronización y Actualización

    public func syncCameraDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss-e"
        let dateStr = formatter.string(from: Date())
        sendCommand(msgId: 6147, param: dateStr) // MSG_SET_DATE
    }

    public func fetchInitialState() {
        sendCommand(msgId: 4364, param: nil) // Device status
        sendCommand(msgId: 4365, param: nil) // Camera status
        sendCommand(msgId: 4361, param: nil) // Battery
        sendCommand(msgId: 4358, param: nil) // Storage
        sendCommand(msgId: 1539, param: nil) // Wi-Fi info
    }

    public func fetchBatteryStatus() {
        sendCommand(msgId: 4361, param: nil)
    }

    private func updateBattery(from raw: Int) {
        let isCharging = (raw & 0x80) != 0 || raw > 100
        let level = raw & 0x0F
        let pct: Int
        if level <= 4 {
            switch level {
            case 4: pct = 100
            case 3: pct = 75
            case 2: pct = 50
            case 1: pct = 25
            default: pct = 5
            }
        } else {
            pct = max(0, min(100, raw >= 128 ? raw - 128 : raw))
        }
        self.isCharging = isCharging
        self.batteryPercent = pct
    }

    public func fetchStorageStatus() {
        sendCommand(msgId: 4358, param: nil)
    }

    public func refreshStatus() {
        sendCommand(msgId: 4364, param: nil)
        sendCommand(msgId: 4365, param: nil)
        sendCommand(msgId: 4358, param: nil)
        sendCommand(msgId: 1539, param: nil)
    }

    // MARK: - Persistencia Local (UserDefaults) y Sincronización con Cámara

    public func loadPersistedSettings() {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: "cam_hasSavedSettings") else { return }

        if let v = ud.object(forKey: "cam_currentMode") as? Int { self.currentMode = v }
        if let v = ud.object(forKey: "cam_photoRes") as? Int { self.photoRes = v }
        if let v = ud.object(forKey: "cam_iso") as? Int { self.iso = v }
        if let v = ud.object(forKey: "cam_shutterRaw") as? Int { self.shutterRaw = v }
        if let v = ud.string(forKey: "cam_shutter") { self.shutter = v }
        if let v = ud.object(forKey: "cam_ev") as? Double { self.ev = v }
        if let v = ud.object(forKey: "cam_wb") as? Int { self.wb = v }
        if let v = ud.object(forKey: "cam_timer") as? Int { self.timer = v }
        if let v = ud.object(forKey: "cam_photoInterval") as? Int { self.photoInterval = v }
        if let v = ud.object(forKey: "cam_photoBracketing") as? Int { self.photoBracketing = v }
        if let v = ud.object(forKey: "cam_videoRes") as? Int { self.videoRes = v }
        if let v = ud.object(forKey: "cam_videoShort") as? Int { self.videoShort = v }
        if let v = ud.object(forKey: "cam_videoTimelapse") as? Int { self.videoTimelapse = v }
        if let v = ud.object(forKey: "cam_videoSlowMo") as? Int { self.videoSlowMo = v }
        if let v = ud.object(forKey: "cam_videoEV") as? Double { self.videoEV = v }
        if let v = ud.object(forKey: "cam_videoWB") as? Int { self.videoWB = v }
        if let v = ud.object(forKey: "cam_videoLoop") as? Int { self.videoLoop = v }
        if let v = ud.object(forKey: "cam_buzzer") as? Int { self.buzzerLevel = v }
        if let v = ud.object(forKey: "cam_autoOffMinutes") as? Int { self.autoOffMinutes = v }
        if let v = ud.object(forKey: "cam_led") as? Bool { self.ledEnabled = v }

        // Garantizar exclusividad mutua de sub-modos de foto si hubiesen quedado guardados juntos
        if self.photoInterval > 0 {
            self.timer = 0
            self.photoBracketing = 0
        } else if self.photoBracketing > 0 {
            self.timer = 0
            self.photoInterval = 0
        }
        self.updatePhotoSubMode()
    }

    public func syncSettingsToCamera() {
        guard isConnected, sessionToken > 0 else { return }
        print("🔄 Sincronizando ajustes guardados con la memoria de la cámara...")
        sendCommand(msgId: 4611, param: "\(currentMode)")
        sendCommand(msgId: 4872, param: "\(photoRes)")
        sendCommand(msgId: 5172, param: "\(iso)")
        sendCommand(msgId: 5171, param: "\(shutterRaw)")
        sendCommand(msgId: 5169, param: "\(Int(ev * 2.0))")
        sendCommand(msgId: 5168, param: "\(wb)")

        // Desactivar explícitamente los sub-modos inactivos con param: 0 y activar el seleccionado:
        if photoInterval > 0 {
            sendCommand(msgId: 4866, param: "0")
            sendCommand(msgId: 4918, param: "0")
            sendCommand(msgId: 4929, param: "\(photoInterval)")
        } else if photoBracketing > 0 {
            sendCommand(msgId: 4866, param: "0")
            sendCommand(msgId: 4929, param: "0")
            sendCommand(msgId: 4918, param: "\(photoBracketing)")
        } else if timer > 0 {
            sendCommand(msgId: 4929, param: "0")
            sendCommand(msgId: 4918, param: "0")
            sendCommand(msgId: 4866, param: "\(timer)")
        } else {
            sendCommand(msgId: 4866, param: "0")
            sendCommand(msgId: 4929, param: "0")
            sendCommand(msgId: 4918, param: "0")
        }

        sendCommand(msgId: 4612, param: "\(videoRes)")
        sendCommand(msgId: 5136, param: "\(videoWB)")
        sendCommand(msgId: 5137, param: "\(Int(videoEV * 2.0))")

        // Desactivar explícitamente los sub-modos de video inactivos y activar el seleccionado:
        if videoShort > 0 {
            sendCommand(msgId: 4621, param: "0")
            sendCommand(msgId: 4916, param: "0")
            sendCommand(msgId: 4618, param: "\(videoShort)")
        } else if videoTimelapse > 0 {
            sendCommand(msgId: 4618, param: "0")
            sendCommand(msgId: 4916, param: "0")
            sendCommand(msgId: 4621, param: "\(videoTimelapse)")
        } else if videoSlowMo > 0 {
            sendCommand(msgId: 4618, param: "0")
            sendCommand(msgId: 4621, param: "0")
            sendCommand(msgId: 4916, param: "\(videoSlowMo)")
        } else {
            sendCommand(msgId: 4618, param: "0")
            sendCommand(msgId: 4621, param: "0")
            sendCommand(msgId: 4916, param: "0")
        }

        if videoLoop > 0 {
            sendCommand(msgId: 4615, param: "\(videoLoop)")
            sendCommand(msgId: 4614, param: "\(videoLoop)")
        }
        sendCommand(msgId: 6145, param: "\(buzzerLevel)")
        sendCommand(msgId: 6151, param: "\(autoOffMinutes)")
        sendCommand(msgId: 6156, param: "\(ledEnabled ? 1 : 0)")
    }

    private func updatePhotoSubMode() {
        if photoInterval > 0 {
            photoSubMode = 2
        } else if photoBracketing > 0 {
            photoSubMode = 4
        } else if timer > 0 {
            photoSubMode = 1
        } else {
            photoSubMode = 0
        }
    }

    // MARK: - Acciones y Ajustes de FOTO

    public func switchMode(_ mode: Int) {
        if isIntervalRunning {
            stopInterval()
        }
        UserDefaults.standard.set(mode, forKey: "cam_currentMode")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 4611, param: "\(mode)")
        DispatchQueue.main.async {
            self.currentMode = mode
            self.lastStatusMessage = mode == 1 ? "Modo Foto 360°" : "Modo Video 360°"
        }
    }

    public func takePhoto() {
        if isIntervalRunning {
            stopInterval()
            return
        }

        if photoInterval > 0 {
            // Intervalómetro: Se inicia con 4864 (PHOTO_PRESS) y la cámara dispara periódicamente hasta enviar 4864 de nuevo
            isIntervalRunning = true
            lastStatusMessage = "Intervalómetro activo cada \(photoInterval)s"
            sendCommand(msgId: 4864, param: nil)
        } else if photoBracketing > 0 {
            // Horquillado AEB / HDR: Con surroundexp activo, 4864 (PHOTO_PRESS) dispara la ráfaga de 3 fotos a diferentes EV
            lastStatusMessage = "Disparando ráfaga HDR (3 fotos)..."
            sendCommand(msgId: 4864, param: nil)
        } else if timer > 0 {
            // Temporizador nativo por hardware: Únicamente el Timer usa 4868 (PHOTO_LONGPRESS) para arrancar beeper y cuenta atrás
            lastStatusMessage = "Temporizador (\(timer)s) iniciado en la cámara..."
            sendCommand(msgId: 4868, param: nil)
        } else {
            // Foto estándar inmediata
            sendCommand(msgId: 4864, param: nil)
        }
    }

    public func cancelCountdown() {
        // Mantenido para compatibilidad
    }

    public func stopInterval() {
        isIntervalRunning = false
        // Enviar 4864 detiene el ciclo del intervalómetro en el procesador Ambarella
        sendCommand(msgId: 4864, param: nil)
        lastStatusMessage = "Intervalómetro detenido."
    }

    // NOTA TÉCNICA: La Xiaomi Mi Sphere 360 emite el flujo RTSP en rtsp://192.168.42.1/live de manera
    // continua en segundo plano sin requerir comandos de activación. Enviar msgId 259 o 260 fuerza al chip
    // Ambarella A12 a reiniciar el codificador de vídeo, lo cual congela o aborta cualquier sesión RTSP activa.
    // Usar exclusivamente conexión directa por socket RTSP (puerto 554) con NativeRTSPPlayer.
    public func startLiveView(completion: ((Bool) -> Void)? = nil) {
        sendCommand(msgId: 259, param: "none_force") { [weak self] resp in
            let rval = resp["rval"] as? Int ?? -1
            let ok = (rval == 0)
            DispatchQueue.main.async {
                self?.isLiveViewActive = ok
                self?.liveViewStatus = ok ? "Transmisión RTSP activa (rtsp://192.168.42.1/live)" : "Error al iniciar RTSP (\(rval))"
                completion?(ok)
            }
        }
    }

    public func stopLiveView(completion: ((Bool) -> Void)? = nil) {
        sendCommand(msgId: 260, param: nil) { [weak self] resp in
            let rval = resp["rval"] as? Int ?? -1
            let ok = (rval == 0)
            DispatchQueue.main.async {
                self?.isLiveViewActive = false
                self?.liveViewStatus = ""
                completion?(ok)
            }
        }
    }

    public func setPhotoResolution(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_photoRes")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 4872, param: "\(val)")
        DispatchQueue.main.async { self.photoRes = val }
    }

    public func setISO(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_iso")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5172, param: "\(val)")
        DispatchQueue.main.async { self.iso = val }
    }

    public func setShutter(_ rawVal: Int, label: String) {
        UserDefaults.standard.set(rawVal, forKey: "cam_shutterRaw")
        UserDefaults.standard.set(label, forKey: "cam_shutter")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5171, param: "\(rawVal)")
        DispatchQueue.main.async {
            self.shutterRaw = rawVal
            self.shutter = label
        }
    }

    public func setEV(_ val: Double) {
        let param = Int(val * 2.0)
        UserDefaults.standard.set(val, forKey: "cam_ev")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5169, param: "\(param)")
        DispatchQueue.main.async { self.ev = val }
    }

    public func setWB(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_wb")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5168, param: "\(val)")
        DispatchQueue.main.async { self.wb = val }
    }

    public func setTimer(_ val: Int) {
        if isIntervalRunning {
            stopInterval()
        }
        UserDefaults.standard.set(val, forKey: "cam_timer")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        lastStatusMessage = "Enviando Timer (\(val)s) con msgId 4866..."
        if val > 0 {
            // Desactivar explícitamente en la cámara los otros sub-modos (Intervalo y HDR)
            self.photoInterval = 0
            self.photoBracketing = 0
            UserDefaults.standard.set(0, forKey: "cam_photoInterval")
            UserDefaults.standard.set(0, forKey: "cam_photoBracketing")
            sendCommand(msgId: 4929, param: "0")
            sendCommand(msgId: 4918, param: "0")
            sendCommand(msgId: 4866, param: "\(val)")
        } else {
            sendCommand(msgId: 4866, param: "0")
        }
        DispatchQueue.main.async {
            self.timer = val
            self.updatePhotoSubMode()
        }
    }

    public func setPhotoInterval(_ val: Int) {
        if isIntervalRunning {
            stopInterval()
        }
        UserDefaults.standard.set(val, forKey: "cam_photoInterval")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        lastStatusMessage = "Enviando Intervalo (\(val)s) con msgId 4929..."
        if val > 0 {
            // Desactivar explícitamente en la cámara los otros sub-modos (Timer y HDR)
            self.timer = 0
            self.photoBracketing = 0
            UserDefaults.standard.set(0, forKey: "cam_timer")
            UserDefaults.standard.set(0, forKey: "cam_photoBracketing")
            sendCommand(msgId: 4866, param: "0")
            sendCommand(msgId: 4918, param: "0")
            sendCommand(msgId: 4929, param: "\(val)")
        } else {
            sendCommand(msgId: 4929, param: "0")
        }
        DispatchQueue.main.async {
            self.photoInterval = val
            self.updatePhotoSubMode()
        }
    }

    public func setPhotoBracketing(_ val: Int) {
        if isIntervalRunning {
            stopInterval()
        }
        UserDefaults.standard.set(val, forKey: "cam_photoBracketing")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        lastStatusMessage = "Enviando HDR (\(val)) con msgId 4918..."
        if val > 0 {
            // Desactivar explícitamente en la cámara los otros sub-modos (Timer e Intervalo)
            self.timer = 0
            self.photoInterval = 0
            UserDefaults.standard.set(0, forKey: "cam_timer")
            UserDefaults.standard.set(0, forKey: "cam_photoInterval")
            sendCommand(msgId: 4866, param: "0")
            sendCommand(msgId: 4929, param: "0")
            sendCommand(msgId: 4918, param: "\(val)")
        } else {
            sendCommand(msgId: 4918, param: "0")
        }
        DispatchQueue.main.async {
            self.photoBracketing = val
            self.updatePhotoSubMode()
        }
    }

    // MARK: - Acciones y Ajustes de VIDEO

    public func toggleVideoRecording() {
        if isRecording {
            sendCommand(msgId: 514, param: nil)
        } else {
            if videoShort > 0 || videoTimelapse > 0 || videoSlowMo > 0 {
                // Sub-modos de video usan 4623 (VIDEO_LONGPRESS)
                sendCommand(msgId: 4623, param: nil)
            } else {
                sendCommand(msgId: 5028, param: nil)
            }
        }
    }

    public func setVideoResolution(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoRes")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 4612, param: "\(val)")
        DispatchQueue.main.async { self.videoRes = val }
    }

    public func setVideoShort(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoShort")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        if val > 0 {
            self.videoTimelapse = 0
            self.videoSlowMo = 0
            UserDefaults.standard.set(0, forKey: "cam_videoTimelapse")
            UserDefaults.standard.set(0, forKey: "cam_videoSlowMo")
            sendCommand(msgId: 4621, param: "0")
            sendCommand(msgId: 4916, param: "0")
            sendCommand(msgId: 4618, param: "\(val)")
        } else {
            sendCommand(msgId: 4618, param: "0")
        }
        DispatchQueue.main.async {
            self.videoShort = val
            self.videoSubMode = val > 0 ? 1 : 0
        }
    }

    public func setVideoTimelapse(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoTimelapse")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        if val > 0 {
            self.videoShort = 0
            self.videoSlowMo = 0
            UserDefaults.standard.set(0, forKey: "cam_videoShort")
            UserDefaults.standard.set(0, forKey: "cam_videoSlowMo")
            sendCommand(msgId: 4618, param: "0")
            sendCommand(msgId: 4916, param: "0")
            sendCommand(msgId: 4621, param: "\(val)")
        } else {
            sendCommand(msgId: 4621, param: "0")
        }
        DispatchQueue.main.async {
            self.videoTimelapse = val
            self.videoSubMode = val > 0 ? 2 : 0
        }
    }

    public func setVideoSlowMo(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoSlowMo")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        if val > 0 {
            self.videoShort = 0
            self.videoTimelapse = 0
            UserDefaults.standard.set(0, forKey: "cam_videoShort")
            UserDefaults.standard.set(0, forKey: "cam_videoTimelapse")
            sendCommand(msgId: 4618, param: "0")
            sendCommand(msgId: 4621, param: "0")
            sendCommand(msgId: 4916, param: "\(val)")
        } else {
            sendCommand(msgId: 4916, param: "0")
        }
        DispatchQueue.main.async {
            self.videoSlowMo = val
            self.videoSubMode = val > 0 ? 4 : 0
        }
    }

    public func setVideoEV(_ val: Double) {
        let param = Int(val * 2.0)
        UserDefaults.standard.set(val, forKey: "cam_videoEV")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5137, param: "\(param)")
        DispatchQueue.main.async { self.videoEV = val }
    }

    public func setVideoWB(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoWB")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 5136, param: "\(val)")
        DispatchQueue.main.async { self.videoWB = val }
    }

    public func setVideoLoop(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_videoLoop")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        // Enviar tanto 4615 como 4614 según la variante de firmware
        sendCommand(msgId: 4615, param: "\(val)")
        sendCommand(msgId: 4614, param: "\(val)")
        DispatchQueue.main.async { self.videoLoop = val }
    }

    public func setAutoTurnOff(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_autoOffMinutes")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 6151, param: "\(val)")
        DispatchQueue.main.async { self.autoOffMinutes = val }
    }

    public func setBuzzer(_ val: Int) {
        UserDefaults.standard.set(val, forKey: "cam_buzzer")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 6145, param: "\(val)")
        DispatchQueue.main.async { self.buzzerLevel = val }
    }

    public func setLED(_ val: Bool) {
        let p = val ? 1 : 0
        UserDefaults.standard.set(val, forKey: "cam_led")
        UserDefaults.standard.set(true, forKey: "cam_hasSavedSettings")
        sendCommand(msgId: 6156, param: "\(p)")
        DispatchQueue.main.async { self.ledEnabled = val }
    }

    public func fetchWiFiSettings() {
        sendCommand(msgId: 1539, param: nil)
    }

    public func setWiFiSettings(ssid: String, password: String, completion: ((Bool) -> Void)? = nil) {
        let packet: [String: Any] = [
            "msg_id": 5634,
            "token": self.sessionToken,
            "ssid": ssid,
            "passwd": password
        ]
        sendCustomPacket(packet, msgId: 5634) { resp in
            let rval = resp["rval"] as? Int ?? -1
            DispatchQueue.main.async {
                if rval == 0 {
                    self.wifiSSID = ssid
                    self.wifiPassword = password
                    completion?(true)
                } else {
                    completion?(false)
                }
            }
        }
    }

    public func calibrateGyroscope(completion: ((Bool, String) -> Void)? = nil) {
        sendCommand(msgId: 6165, param: nil) { resp in
            let rval = resp["rval"] as? Int ?? -1
            DispatchQueue.main.async {
                if rval == 0 {
                    completion?(true, "Giroscopio calibrado correctamente.")
                } else {
                    completion?(false, "Error al calibrar giroscopio (código: \(rval)). Asegúrate de que la cámara permanezca totalmente quieta sobre una superficie plana.")
                }
            }
        }
    }

    // MARK: - GPS y Hardware

    public func setGPS(latitude: Double, longitude: Double, altitude: Double) {
        guard isConnected else { return }
        let gpsString = String(format: "%.6f,%.6f,%.1f", latitude, longitude, altitude)
        sendCommand(msgId: 4917, param: gpsString)
    }

    public func powerOffCamera() {
        sendCommand(msgId: 6155, param: nil)
        disconnect()
    }

    // MARK: - Exploración microSD vía TCP (CHANGE_DIR 1283 y LIST_DIR 1282)

    public func listDCIMFolders(completion: @escaping ([String]) -> Void) {
        guard isConnected else { completion([]); return }
        // 1. Cambiar a /tmp/SD0/DCIM/
        sendCommand(msgId: 1283, param: "/tmp/SD0/DCIM/") { _ in
            // 2. Listar directorios
            self.sendCommand(msgId: 1282, param: nil) { resp in
                var folders: [String] = []
                if let listing = resp["listing"] as? [[String: Any]] {
                    for entry in listing {
                        for (key, _) in entry {
                            if key.hasSuffix("/") {
                                let name = String(key.dropLast())
                                if !folders.contains(name) {
                                    folders.append(name)
                                }
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.dcimFolders = folders.sorted()
                    completion(folders.sorted())
                }
            }
        }
    }

    public func listFilesInFolder(_ folder: String, completion: @escaping ([SDFileItem]) -> Void) {
        guard isConnected else { completion([]); return }
        let target = "/tmp/SD0/DCIM/\(folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/"
        sendCommand(msgId: 1283, param: target) { _ in
            self.sendCommand(msgId: 1282, param: nil) { resp in
                var files: [SDFileItem] = []
                if let listing = resp["listing"] as? [[String: Any]] {
                    for entry in listing {
                        for (fname, dateStr) in entry {
                            if !fname.hasSuffix("/") {
                                let isVid = fname.uppercased().hasSuffix(".MP4")
                                let item = SDFileItem(
                                    folder: folder,
                                    filename: fname,
                                    isVideo: isVid,
                                    date: "\(dateStr)"
                                )
                                files.append(item)
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    // Ordenar por nombre descendente (fotos más recientes primero)
                    completion(files.sorted(by: { $0.filename > $1.filename }))
                }
            }
        }
    }

    public func fetchLatestPhotoItem(completion: @escaping (SDFileItem?) -> Void) {
        listDCIMFolders { folders in
            let sortedFolders = folders.sorted(by: >)
            guard !sortedFolders.isEmpty else {
                completion(nil)
                return
            }

            func checkFolder(index: Int) {
                guard index < min(sortedFolders.count, 5) else {
                    completion(nil)
                    return
                }
                let folder = sortedFolders[index]
                self.listFilesInFolder(folder) { files in
                    let photos = files.filter { !$0.isVideo }
                    if let firstPhoto = photos.first {
                        completion(firstPhoto)
                    } else {
                        checkFolder(index: index + 1)
                    }
                }
            }

            checkFolder(index: 0)
        }
    }

    public func fetchSDFileList(completion: @escaping ([SDFileItem]) -> Void) {
        listDCIMFolders { folders in
            let sortedFolders = folders.sorted(by: >)
            guard let latestFolder = sortedFolders.first else {
                completion([])
                return
            }
            self.listFilesInFolder(latestFolder) { files in
                completion(files)
            }
        }
    }

    public func deleteSDFile(folder: String, filename: String, completion: @escaping (Bool) -> Void) {
        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var variants = [filename]
        let upper = filename.uppercased()
        if upper.hasSuffix(".JPG") && !upper.hasSuffix("AA.JPG") {
            let stem = String(filename.dropLast(4))
            variants.insert("\(stem)AA.JPG", at: 0)
        } else if upper.hasSuffix(".MP4") && !upper.hasSuffix("AA.MP4") {
            let stem = String(filename.dropLast(4))
            variants.insert("\(stem)AA.MP4", at: 0)
        }

        func tryDelete(cands: [String]) {
            guard let first = cands.first else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let fullPath = "/tmp/SD0/DCIM/\(cleanFolder)/\(first)"
            self.sendCommand(msgId: 1281, param: fullPath) { resp in
                let rval = resp["rval"] as? Int ?? -1
                if rval == 0 {
                    self.fetchStorageStatus()
                    DispatchQueue.main.async { completion(true) }
                } else {
                    tryDelete(cands: Array(cands.dropFirst()))
                }
            }
        }

        tryDelete(cands: variants)
    }

    private func decodeShutter(_ rawVal: Int) -> String {
        if rawVal == 0 { return "Auto" }
        if rawVal >= (1 << 15) { return "1/\(rawVal - (1 << 15))" }
        return "\(rawVal)s"
    }
}
