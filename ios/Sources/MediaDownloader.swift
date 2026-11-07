import Foundation
import Photos
import UIKit
import Combine

/// Descarga fotos y videos desde la cámara Xiaomi Mi Sphere 360 y los guarda en el Carrete de Apple Fotos
public class MediaDownloader: ObservableObject {
    public static let shared = MediaDownloader()

    @Published public var isDownloading = false
    @Published public var downloadProgress: Float = 0.0
    @Published public var statusMessage: String = ""

    /// Prefijo de ruta que ya funcionó previamente (ej. "", "/DCIM", etc.) para acelerar descargas siguientes
    private var rememberedWorkingPrefix: String? = nil

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6.0
        config.timeoutIntervalForResource = 180.0
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    public func saveMediaToCameraRoll(
        item: SDFileItem,
        mode: StitchMode = .stitched360,
        completion: @escaping (Bool, String) -> Void
    ) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false, "Permiso denegado para guardar en Apple Fotos. Concede permiso en Ajustes > Mi Sphere 360.")
                }
                return
            }

            DispatchQueue.main.async {
                self.isDownloading = true
                self.downloadProgress = 0.0
                self.statusMessage = "Buscando \(item.filename)..."
            }

            self.buildAndTryCandidates(item: item, mode: mode, completion: completion)
        }
    }

    /// Descarga directamente el archivo original de la cámara a un archivo temporal local
    public func downloadToTemporaryFile(item: SDFileItem, completion: @escaping (URL?) -> Void) {
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nameVariants = filenameVariants(for: item.filename)

        // Priorizar prefijos conocidos directos
        var prefixes = ["/DCIM", "", "/SD0/DCIM", "/tmp/SD0/DCIM"]
        if let remembered = rememberedWorkingPrefix {
            prefixes.removeAll(where: { $0 == remembered })
            prefixes.insert(remembered, at: 0)
        }

        var candidateURLs: [URL] = []
        for prefix in prefixes {
            for vname in nameVariants {
                let urlStr = "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(prefix)/\(cleanFolder)/\(vname)"
                if let u = URL(string: urlStr), !candidateURLs.contains(u) {
                    candidateURLs.append(u)
                }
            }
        }

        // Iniciar descarga inmediata con las URLs directas más probables sin demoras de sondeo
        self.downloadNextCandidate(candidates: candidateURLs, item: item) { [weak self] resultURL in
            if let result = resultURL {
                completion(result)
            } else {
                // Fallback: Si los candidatos directos fallaron (404), intentar descubrimiento HTML en Cherokee
                self?.discoverCherokeeExactLink(folder: cleanFolder, filename: item.filename) { discURL in
                    guard let discURL = discURL else {
                        completion(nil)
                        return
                    }
                    self?.downloadNextCandidate(candidates: [discURL], item: item, completion: completion)
                }
            }
        }
    }

    private func downloadNextCandidate(candidates: [URL], item: SDFileItem, completion: @escaping (URL?) -> Void) {
        guard let currentURL = candidates.first else {
            completion(nil)
            return
        }

        let remaining = Array(candidates.dropFirst())
        var req = URLRequest(url: currentURL)
        req.timeoutInterval = 8.0

        let task = session.downloadTask(with: req) { [weak self] localURL, response, _ in
            guard let self = self else { completion(nil); return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 200, let localURL = localURL {
                let pathStr = currentURL.path
                if pathStr.contains("/DCIM/") {
                    self.rememberedWorkingPrefix = "/DCIM"
                } else if pathStr.contains("/SD0/DCIM/") {
                    self.rememberedWorkingPrefix = "/SD0/DCIM"
                } else if pathStr.contains("/tmp/SD0/DCIM/") {
                    self.rememberedWorkingPrefix = "/tmp/SD0/DCIM"
                } else {
                    self.rememberedWorkingPrefix = ""
                }

                let ext = item.isVideo ? "MP4" : "JPG"
                let safeName = "MiSphere_temp_\(UUID().uuidString).\(ext)"
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: localURL, to: dest)
                    completion(dest)
                } catch {
                    completion(nil)
                }
            } else {
                self.downloadNextCandidate(candidates: remaining, item: item, completion: completion)
            }
        }
        task.resume()
    }

    private func filenameVariants(for filename: String) -> [String] {
        let clean = filename.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var variants: [String] = []
        let upper = clean.uppercased()

        if upper.hasSuffix(".JPG") {
            let stem: String
            if upper.hasSuffix("AA.JPG") {
                stem = String(clean.dropLast(6))
                variants.append(clean)
                variants.append("\(stem).JPG")
                variants.append("\(stem)aa.jpg")
                variants.append("\(stem).jpg")
            } else {
                stem = String(clean.dropLast(4))
                // En el sistema FAT32 real de la tarjeta SD, Ambarella guarda con sufijo AA
                variants.append("\(stem)AA.JPG")
                variants.append("\(stem)aa.jpg")
                variants.append(clean)
                variants.append("\(stem).jpg")
            }
        } else if upper.hasSuffix(".MP4") {
            let stem: String
            if upper.hasSuffix("AA.MP4") {
                stem = String(clean.dropLast(6))
                variants.append(clean)
                variants.append("\(stem).MP4")
                variants.append("\(stem)aa.mp4")
            } else {
                stem = String(clean.dropLast(4))
                variants.append("\(stem)AA.MP4")
                variants.append(clean)
                variants.append("\(stem)aa.mp4")
            }
        } else {
            variants.append(clean)
        }

        // Eliminar duplicados preservando orden
        var unique: [String] = []
        for v in variants where !unique.contains(v) {
            unique.append(v)
        }
        return unique
    }

    private func buildAndTryCandidates(
        item: SDFileItem,
        mode: StitchMode,
        completion: @escaping (Bool, String) -> Void
    ) {
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nameVariants = filenameVariants(for: item.filename)

        // Variantes de prefijos de directorios según cómo el servidor Cherokee de la cámara mapee la raíz
        var prefixes = ["", "/DCIM", "/SD0/DCIM", "/tmp/SD0/DCIM"]
        if let remembered = rememberedWorkingPrefix {
            prefixes.removeAll(where: { $0 == remembered })
            prefixes.insert(remembered, at: 0)
        }

        var candidateURLs: [URL] = []
        for prefix in prefixes {
            for vname in nameVariants {
                let urlStr = "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(prefix)/\(cleanFolder)/\(vname)"
                if let u = URL(string: urlStr), !candidateURLs.contains(u) {
                    candidateURLs.append(u)
                }
            }
        }

        // Primero intentar descubrir mediante inspección rápida del índice HTML de Cherokee
        discoverCherokeeExactLink(folder: cleanFolder, filename: item.filename) { [weak self] discoveredURL in
            guard let self = self else { return }
            var finalCandidates = candidateURLs
            if let disc = discoveredURL {
                finalCandidates.insert(disc, at: 0)
            }
            self.executeCandidateDownload(
                candidates: finalCandidates,
                item: item,
                mode: mode,
                triedErrors: [],
                completion: completion
            )
        }
    }

    private func discoverCherokeeExactLink(folder: String, filename: String, completion: @escaping (URL?) -> Void) {
        let probeURLs = [
            "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/\(folder)/",
            "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/\(folder)/",
            "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/"
        ]

        let variants = filenameVariants(for: filename).map { $0.uppercased() }

        func checkProbe(index: Int) {
            guard index < probeURLs.count else {
                completion(nil)
                return
            }
            guard let u = URL(string: probeURLs[index]) else {
                checkProbe(index: index + 1)
                return
            }

            var req = URLRequest(url: u)
            req.timeoutInterval = 2.5
            self.session.dataTask(with: req) { data, resp, _ in
                if let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let data = data, let html = String(data: data, encoding: .utf8) {
                    // Buscar enlaces href que contengan alguna de las variantes
                    for v in variants {
                        if html.uppercased().contains(v) {
                            // Extraer el href específico
                            let pattern = "href=[\"']([^\"']*" + NSRegularExpression.escapedPattern(for: v) + "[^\"']*)[\"']"
                            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                               let range = Range(match.range(at: 1), in: html) {
                                let href = String(html[range])
                                if let resolved = URL(string: href, relativeTo: u)?.absoluteURL {
                                    completion(resolved)
                                    return
                                }
                            }
                        }
                    }
                }
                checkProbe(index: index + 1)
            }.resume()
        }

        checkProbe(index: 0)
    }

    private func executeCandidateDownload(
        candidates: [URL],
        item: SDFileItem,
        mode: StitchMode,
        triedErrors: [String],
        completion: @escaping (Bool, String) -> Void
    ) {
        guard let currentURL = candidates.first else {
            DispatchQueue.main.async {
                self.isDownloading = false
                let details = triedErrors.suffix(2).joined(separator: "; ")
                completion(false, "No se pudo descargar de la cámara. Comprueba que el Wi-Fi esté conectado. (\(details.isEmpty ? "Error 404" : details))")
            }
            return
        }

        let remaining = Array(candidates.dropFirst())
        DispatchQueue.main.async {
            self.statusMessage = "Descargando desde cámara..."
        }

        var req = URLRequest(url: currentURL)
        req.timeoutInterval = 30.0

        let task = session.downloadTask(with: req) { [weak self] localURL, response, error in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 200, let localURL = localURL {
                // Éxito: Recordar el prefijo de la URL para acelerar descargas siguientes
                let pathStr = currentURL.path
                if pathStr.contains("/DCIM/") {
                    self.rememberedWorkingPrefix = "/DCIM"
                } else if pathStr.contains("/SD0/DCIM/") {
                    self.rememberedWorkingPrefix = "/SD0/DCIM"
                } else if pathStr.contains("/tmp/SD0/DCIM/") {
                    self.rememberedWorkingPrefix = "/tmp/SD0/DCIM"
                } else {
                    self.rememberedWorkingPrefix = ""
                }

                // CRÍTICO: Copiar inmediatamente el archivo descargado a un destino temporal propio
                let ext = item.isVideo ? "MP4" : "JPG"
                let safeName = "MiSphere_\(UUID().uuidString).\(ext)"
                let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)

                try? FileManager.default.removeItem(at: destinationURL)

                do {
                    try FileManager.default.copyItem(at: localURL, to: destinationURL)
                } catch {
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        completion(false, "Error al preparar archivo temporal: \(error.localizedDescription)")
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.statusMessage = (mode == .stitched360 || mode == .both) && !item.isVideo
                        ? "Procesando metadatos 360°..."
                        : "Guardando en Apple Fotos..."
                }

                // Recuperar la coordenada satelital registrada en el momento exacto en que se tomó esta foto
                let shotLocation = LocationManager.shared.getBestLocation(for: item.filename)

                // Procesar según el modo elegido por el usuario (Solo 360°, Solo Original, o Ambas)
                let filesToSave = PhotoStitcher.shared.processDownloadedFile(
                    at: destinationURL,
                    isVideo: item.isVideo,
                    mode: mode,
                    location: shotLocation
                )

                PHPhotoLibrary.shared().performChanges({
                    for fileURL in filesToSave {
                        if item.isVideo {
                            let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                            if let loc = shotLocation {
                                req?.location = loc
                            }
                        } else {
                            let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                            if let loc = shotLocation {
                                req?.location = loc
                            }
                        }
                    }
                }) { success, saveError in
                    // Limpiar copias temporales
                    try? FileManager.default.removeItem(at: destinationURL)
                    for fileURL in filesToSave where fileURL != destinationURL {
                        try? FileManager.default.removeItem(at: fileURL)
                    }

                    DispatchQueue.main.async {
                        self.isDownloading = false
                        if success {
                            let msg: String
                            if item.isVideo {
                                msg = "¡Video guardado en tu Carrete de Apple Fotos!"
                            } else {
                                switch mode {
                                case .stitched360:
                                    msg = "¡Foto 360° (con metadatos interactivos GPano) guardada en Fotos!"
                                case .both:
                                    msg = "¡Se guardaron ambas fotos (Original + versión 360°) en Fotos!"
                                case .original:
                                    msg = "¡Foto original guardada en Fotos!"
                                }
                            }
                            completion(true, msg)
                        } else {
                            completion(false, saveError?.localizedDescription ?? "Error al escribir en Carrete de Fotos.")
                        }
                    }
                }
            } else {
                var errDesc = "HTTP \(statusCode)"
                if let err = error {
                    errDesc = err.localizedDescription
                }
                var updatedErrors = triedErrors
                updatedErrors.append("\(currentURL.lastPathComponent): \(errDesc)")

                self.executeCandidateDownload(
                    candidates: remaining,
                    item: item,
                    mode: mode,
                    triedErrors: updatedErrors,
                    completion: completion
                )
            }
        }
        task.resume()
    }
}
