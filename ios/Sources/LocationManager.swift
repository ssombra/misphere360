import Foundation
import CoreLocation
import Combine

/// Maneja el chip GPS satelital del iPhone y sincroniza la geolocalización con la cámara (Camino A)
public class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationManager()

    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public var hasLocation = false
    @Published public var currentLatitude: Double = 0.0
    @Published public var currentLongitude: Double = 0.0
    @Published public var currentAltitude: Double = 0.0
    @Published public var accuracy: Double = 0.0
    @Published public var accuracyString: String = "Buscando GPS..."

    private let clManager = CLLocationManager()
    private var lastSentLocation: CLLocation?

    public override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 5.0 // Solo actualizar si nos movemos al menos 5 metros
        clManager.pausesLocationUpdatesAutomatically = true
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

    // Forzar actualización inmediata antes de disparar la foto
    public func forceSyncGPSWithCamera() {
        guard let loc = clManager.location, loc.horizontalAccuracy >= 0 else { return }
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

            // Si es la primera ubicación o nos movimos más de 5 metros, inyectar a la cámara
            if let last = self.lastSentLocation {
                if location.distance(from: last) >= 5.0 {
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
