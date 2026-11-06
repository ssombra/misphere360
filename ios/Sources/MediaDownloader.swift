import Foundation
import Photos
import UIKit
import Combine

/// Descarga fotos y videos desde la cámara y los guarda en el Carrete de Apple Fotos
public class MediaDownloader: ObservableObject {
    public static let shared = MediaDownloader()

    @Published public var isDownloading = false
    @Published public var downloadProgress: Float = 0.0
    @Published public var statusMessage: String = ""

    public func saveMediaToCameraRoll(item: SDFileItem, completion: @escaping (Bool, String) -> Void) {
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

            // Probar la URL con sufijo AA (formato real en el disco FAT32) y sin sufijo
            let rawName = item.filename
            var candidateNames = [rawName]
            if rawName.uppercased().hasSuffix(".JPG") && !rawName.uppercased().hasSuffix("AA.JPG") {
                let stem = String(rawName.dropLast(4))
                candidateNames.insert("\(stem)AA.JPG", at: 0)
            }

            self.tryDownloadCandidates(folder: item.folder, candidates: candidateNames, isVideo: item.isVideo, completion: completion)
        }
    }

    private func tryDownloadCandidates(folder: String, candidates: [String], isVideo: Bool, completion: @escaping (Bool, String) -> Void) {
        guard let first = candidates.first else {
            DispatchQueue.main.async {
                self.isDownloading = false
                completion(false, "No se pudo descargar el archivo de la cámara.")
            }
            return
        }

        let testURL = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/\(folder)/\(first)")!
        let remaining = Array(candidates.dropFirst())

        let task = URLSession.shared.downloadTask(with: testURL) { localURL, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 200, let localURL = localURL {
                PHPhotoLibrary.shared().performChanges({
                    if isVideo {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: localURL)
                    }
                }) { success, saveError in
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        if success {
                            completion(true, "Guardado exitosamente en Carrete.")
                        } else {
                            completion(false, saveError?.localizedDescription ?? "Error al guardar en Carrete.")
                        }
                    }
                }
            } else {
                // Probar siguiente variante
                self.tryDownloadCandidates(folder: folder, candidates: remaining, isVideo: isVideo, completion: completion)
            }
        }
        task.resume()
    }
}
