import Foundation
import Photos
import UIKit
import Combine

/// Descarga fotos y videos desde el servidor HTTP de la cámara (puerto 50422) y los guarda en el Carrete del iPhone
public class MediaDownloader: ObservableObject {
    public static let shared = MediaDownloader()

    @Published public var isDownloading = false
    @Published public var downloadProgress: Float = 0.0
    @Published public var statusMessage: String = ""

    public struct MediaItem: Identifiable, Hashable {
        public let id = UUID()
        public let folder: String
        public let filename: String
        public let isVideo: Bool
        public var url: URL {
            let clean = filename.hasSuffix("AA.JPG") ? String(filename.dropLast(6)) + ".JPG" : filename
            return URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/\(folder)/\(filename)")!
        }
    }

    public func saveMediaToCameraRoll(item: MediaItem, completion: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false, "Permiso denegado para guardar fotos.") }
                return
            }

            DispatchQueue.main.async {
                self.isDownloading = true
                self.downloadProgress = 0.0
                self.statusMessage = "Descargando \(item.filename)..."
            }

            let task = URLSession.shared.downloadTask(with: item.url) { localURL, response, error in
                DispatchQueue.main.async { self.isDownloading = false }

                if let error = error {
                    DispatchQueue.main.async { completion(false, "Error: \(error.localizedDescription)") }
                    return
                }

                guard let localURL = localURL else {
                    DispatchQueue.main.async { completion(false, "Archivo descargado vacío.") }
                    return
                }

                PHPhotoLibrary.shared().performChanges({
                    if item.isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: localURL)
                    }
                }) { success, saveError in
                    DispatchQueue.main.async {
                        if success {
                            completion(true, "Guardado exitosamente en Carrete.")
                        } else {
                            completion(false, saveError?.localizedDescription ?? "Error al guardar en Carrete.")
                        }
                    }
                }
            }
            task.resume()
        }
    }
}
