import Foundation
import Network
import Combine

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

    // ALMACENAMIENTO SD
    @Published public var sdTotalMB: Int = 0
    @Published public var sdFreeMB: Int = 0
    @Published public var remainJPG: Int = 0
    @Published public var remainVideo: Int = 0
    @Published public var dcimFolders: [String] = []

    // Callbacks pendientes para comandos TCP asíncronos (ej. list_dir)
    private var pendingCallbacks: [Int: ([String: Any]) -> Void] = [:]
    private var lastSendTime: TimeInterval = 0.0

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
        queue.async {
            self.connection = nil
            self.receiveBuffer = ""
            self.pendingCallbacks.removeAll()
        }
        stopHeartbeat()
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            self.sessionToken = 0
        }
    }

    // MARK: - Autenticación y Heartbeat (45s para mantenerla fresca)

    private func authenticateSession() {
        queue.async {
            let authPacket: [String: Any] = ["msg_id": 257, "token": 0]
            self.sendRawJSON(authPacket)
            self.lastSendTime = Date().timeIntervalSince1970
        }
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
                self.pendingCallbacks[msgId] = onResponse
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

        // Si había un callback esperando este msgId, ejecutarlo
        if let cb = pendingCallbacks.removeValue(forKey: msgId) {
            DispatchQueue.main.async { cb(obj) }
        }

        DispatchQueue.main.async {
            switch msgId {
            case 257: // CONNECT
                if rval == 0, let tok = obj["param"] as? Int {
                    self.sessionToken = tok
                    self.isConnected = true
                    self.isConnecting = false
                    self.lastStatusMessage = "Cámara Conectada (Token \(tok))"
                    self.startHeartbeat()
                    self.syncCameraDate()
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

            case 4358: // ALMACENAMIENTO SD
                if let free = obj["sd_free"] as? Int { self.sdFreeMB = free / 1024 }
                if let total = obj["sd_total"] as? Int { self.sdTotalMB = total / 1024 }
                if let rjpg = obj["remain_jpg"] as? Int { self.remainJPG = rjpg }
                if let rvid = obj["remain_video"] as? Int { self.remainVideo = rvid }

            case 4364: // GET_DEVICE
                if let pres = obj["p_res"] as? Int { self.photoRes = pres }
                if let vres = obj["v_res"] as? Int { self.videoRes = vres }
                if let wb = obj["still_wb"] as? Int { self.wb = wb }
                if let iso = obj["still_iso"] as? Int { self.iso = iso }
                if let ev = obj["still_ev"] as? Int { self.ev = Double(ev) / 2.0 }
                if let sht = obj["still_shutter"] as? Int {
                    self.shutterRaw = sht
                    self.shutter = self.decodeShutter(sht)
                }
                if let vwb = obj["video_wb"] as? Int { self.videoWB = vwb }
                if let vev = obj["video_ev"] as? Int { self.videoEV = Double(vev) / 2.0 }

            case 4365: // GET_CAMERA
                if let mode = obj["mode"] as? Int { self.currentMode = mode }
                if let rec = obj["rec_time"] as? Int { self.isRecording = rec > 0 }
                if let timing = obj["timing"] as? Int { self.timer = timing }
                if let interval = obj["cap_interval"] as? Int { self.photoInterval = interval }
                if let brk = obj["surroundexp"] as? Int { self.photoBracketing = brk }
                if let sec = obj["second"] as? Int { self.videoShort = sec }
                if let lapse = obj["lapse"] as? Int { self.videoTimelapse = lapse }
                if let spd = obj["speedx"] as? Int { self.videoSlowMo = spd == 2 ? 1 : 0 }

            case 4611: // SWITCH_MODE
                if rval == 0 {
                    if let p = obj["param"] as? Int { self.currentMode = p }
                    else if let pStr = obj["param"] as? String, let pInt = Int(pStr) { self.currentMode = pInt }
                    self.lastStatusMessage = self.currentMode == 1 ? "Modo Foto 360°" : "Modo Video 360°"
                }

            case 4864, 4868: // DISPARO FOTO
                if rval == 0 {
                    self.lastStatusMessage = "¡Foto capturada!"
                    self.refreshStatus()
                }

            case 5028: // INICIO VIDEO
                if rval == 0 { self.isRecording = true; self.lastStatusMessage = "Grabando video..." }

            case 514: // FIN VIDEO
                if rval == 0 { self.isRecording = false; self.lastStatusMessage = "Video guardado." }

            case 8192, 8193: // EVENTO ASÍNCRONO DE FOTO (8193) O VIDEO (8192) GUARDADO
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
    }

    public func fetchBatteryStatus() {
        sendCommand(msgId: 4361, param: nil)
    }

    public func fetchStorageStatus() {
        sendCommand(msgId: 4358, param: nil)
    }

    public func refreshStatus() {
        sendCommand(msgId: 4364, param: nil)
        sendCommand(msgId: 4365, param: nil)
        sendCommand(msgId: 4358, param: nil)
    }

    // MARK: - Acciones y Ajustes de FOTO

    public func switchMode(_ mode: Int) {
        sendCommand(msgId: 4611, param: "\(mode)")
        DispatchQueue.main.async {
            self.currentMode = mode
            self.lastStatusMessage = mode == 1 ? "Modo Foto 360°" : "Modo Video 360°"
        }
    }

    public func takePhoto() {
        if timer > 0 {
            sendCommand(msgId: 4868, param: nil)
        } else {
            sendCommand(msgId: 4864, param: nil)
        }
    }

    public func setPhotoResolution(_ val: Int) {
        sendCommand(msgId: 4872, param: "\(val)")
        DispatchQueue.main.async { self.photoRes = val }
    }

    public func setISO(_ val: Int) {
        sendCommand(msgId: 5172, param: "\(val)")
        DispatchQueue.main.async { self.iso = val }
    }

    public func setShutter(_ rawVal: Int, label: String) {
        sendCommand(msgId: 5171, param: "\(rawVal)")
        DispatchQueue.main.async {
            self.shutterRaw = rawVal
            self.shutter = label
        }
    }

    public func setEV(_ val: Double) {
        let param = Int(val * 2.0)
        sendCommand(msgId: 5169, param: "\(param)")
        DispatchQueue.main.async { self.ev = val }
    }

    public func setWB(_ val: Int) {
        sendCommand(msgId: 5168, param: "\(val)")
        DispatchQueue.main.async { self.wb = val }
    }

    public func setTimer(_ val: Int) {
        sendCommand(msgId: 4866, param: "\(val)")
        DispatchQueue.main.async {
            self.timer = val
            self.photoSubMode = val > 0 ? 1 : 0
        }
    }

    public func setPhotoInterval(_ val: Int) {
        sendCommand(msgId: 4929, param: "\(val)")
        DispatchQueue.main.async {
            self.photoInterval = val
            self.photoSubMode = val > 0 ? 2 : 0
        }
    }

    public func setPhotoBracketing(_ val: Int) {
        sendCommand(msgId: 4918, param: "\(val)")
        DispatchQueue.main.async {
            self.photoBracketing = val
            self.photoSubMode = val > 0 ? 4 : 0
        }
    }

    // MARK: - Acciones y Ajustes de VIDEO

    public func toggleVideoRecording() {
        if isRecording {
            sendCommand(msgId: 514, param: nil)
        } else {
            sendCommand(msgId: 5028, param: nil)
        }
    }

    public func setVideoResolution(_ val: Int) {
        sendCommand(msgId: 4612, param: "\(val)")
        DispatchQueue.main.async { self.videoRes = val }
    }

    public func setVideoShort(_ val: Int) {
        sendCommand(msgId: 4618, param: "\(val)")
        DispatchQueue.main.async {
            self.videoShort = val
            self.videoSubMode = val > 0 ? 1 : 0
        }
    }

    public func setVideoTimelapse(_ val: Int) {
        sendCommand(msgId: 4621, param: "\(val)")
        DispatchQueue.main.async {
            self.videoTimelapse = val
            self.videoSubMode = val > 0 ? 2 : 0
        }
    }

    public func setVideoSlowMo(_ val: Int) {
        sendCommand(msgId: 4916, param: "\(val)")
        DispatchQueue.main.async {
            self.videoSlowMo = val
            self.videoSubMode = val > 0 ? 4 : 0
        }
    }

    public func setVideoEV(_ val: Double) {
        let param = Int(val * 2.0)
        sendCommand(msgId: 5137, param: "\(param)")
        DispatchQueue.main.async { self.videoEV = val }
    }

    public func setVideoWB(_ val: Int) {
        sendCommand(msgId: 5136, param: "\(val)")
        DispatchQueue.main.async { self.videoWB = val }
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
