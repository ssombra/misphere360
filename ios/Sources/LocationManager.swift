import Foundation
import CoreLocation
import Combine

/// Maneja el chip GPS satelital del iPhone, sincroniza la geolocalización con la cámara
/// y registra la bitácora de coordenadas en el segundo exacto de cada disparo.
public class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationManager()

    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public var hasLocation = false
    @Published public var currentLatitude: Double = 0.0
    @Published public var currentLongitude: Double = 0.0
    @Published public var currentAltitude: Double = 0.0
    @Published public var accuracy: Double = 0.0
    @Published public var accuracyString: String = "Buscando GPS..."

    public var currentCLLocation: CLLocation? {
        clManager.location
    }

    private let clManager = CLLocationManager()
    private var lastSentLocation: CLLocation?

    // Bitácora de disparos: guarda la coordenada satelital registrada en cada toma
    private struct ShotRecord: Codable {
        let timestamp: TimeInterval
        let latitude: Double
        let longitude: Double
        let altitude: Double
    }
    private var shotHistory: [ShotRecord] = []
    private let historyKey = "MiSphere_GPS_Shot_History"

    public override init() {
        super.init()
        loadHistory()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 3.0 // Actualizar cada 3 metros
        clManager.pausesLocationUpdatesAutomatically = false
    }

    public func requestPermission() {
        clManager.requestWhenInUseAuthorization()
    }

    public func startTracking() {
        requestPermission()
        clManager.startUpdatingLocation()
    }

    public func stopTracking() {
        clManager.stopUpdatingLocation()
    }

    // Registra la coordenada satelital exacta del momento en que se tomó una foto
    // (Llamado tanto desde el botón de la app como al recibir el evento TCP 8193 de la cámara física)
    public func recordCurrentShotLocation(at date: Date = Date()) {
        guard let loc = clManager.location, loc.horizontalAccuracy >= 0 else { return }
        let rec = ShotRecord(
            timestamp: date.timeIntervalSince1970,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: loc.altitude
        )
        DispatchQueue.main.async {
            self.shotHistory.append(rec)
            // Conservar las últimas 500 fotos
            if self.shotHistory.count > 500 {
                self.shotHistory.removeFirst(self.shotHistory.count - 500)
            }
            self.saveHistory()
        }
        // Enviar también a la cámara por TCP
        sendLocationToCamera(loc)
    }

    // Busca la coordenada satelital correspondiente a una foto según la fecha/hora en su nombre de archivo
    public func getBestLocation(for filename: String) -> CLLocation? {
        if let shotDate = parseDateFromFilename(filename) {
            let targetTs = shotDate.timeIntervalSince1970
            // Buscar en el historial el registro más cercano dentro de una ventana de 15 minutos
            var closest: ShotRecord?
            var minDiff: TimeInterval = 15.0 * 60.0

            for rec in shotHistory {
                let diff = abs(rec.timestamp - targetTs)
                if diff < minDiff {
                    minDiff = diff
                    closest = rec
                }
            }

            if let c = closest {
                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                    altitude: c.altitude,
                    horizontalAccuracy: 5.0,
                    verticalAccuracy: 5.0,
                    timestamp: shotDate
                )
            }
        }

        // Si no está en el historial (o fue tomada antes), usar la ubicación actual si está disponible
        return clManager.location
    }

    private func parseDateFromFilename(_ filename: String) -> Date? {
        // Busca patrón YYYYMMDD_HHMMSS en nombres como IMG_20261106_161005AA.JPG
        let pattern = "(\\d{8})_(\\d{6})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) else {
            return nil
        }

        guard let r1 = Range(match.range(at: 1), in: filename),
              let r2 = Range(match.range(at: 2), in: filename) else {
            return nil
        }

        let dateStr = "\(filename[r1])_\(filename[r2])"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: dateStr)
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let list = try? JSONDecoder().decode([ShotRecord].self, from: data) {
            self.shotHistory = list
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(shotHistory) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    public func forceSyncGPSWithCamera() {
        guard let loc = clManager.location, loc.horizontalAccuracy >= 0 else { return }
        recordCurrentShotLocation()
        sendLocationToCamera(loc)
    }

    private func sendLocationToCamera(_ location: CLLocation) {
        CameraManager.shared.setGPS(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude
        )
        lastSentLocation = location
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }

        DispatchQueue.main.async {
            self.hasLocation = true
            self.currentLatitude = location.coordinate.latitude
            self.currentLongitude = location.coordinate.longitude
            self.currentAltitude = location.altitude
            self.accuracy = location.horizontalAccuracy
            self.accuracyString = String(format: "±%.0fm", location.horizontalAccuracy)

            if let last = self.lastSentLocation {
                if location.distance(from: last) >= 3.0 {
                    self.sendLocationToCamera(location)
                }
            } else {
                self.sendLocationToCamera(location)
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Error en CoreLocation: \(error.localizedDescription)")
    }
}
