import Foundation
import Photos
import UIKit
import Combine
import CoreLocation

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

            // Si ya existe en Local, exportar directamente desde el iPhone sin usar Wi-Fi
            if let localAsset = LocalLibraryManager.shared.asset(for: item) {
                let localOrig = LocalLibraryManager.shared.originalURL(for: localAsset)
                let ext = item.isVideo ? "MP4" : "JPG"
                let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent("MiSphere_\(UUID().uuidString).\(ext)")
                try? FileManager.default.removeItem(at: tempCopy)
                if (try? FileManager.default.copyItem(at: localOrig, to: tempCopy)) != nil {
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.exportFileToPhotos(destinationURL: tempCopy, item: item, mode: mode, completion: completion)
                    }
                    return
                }
            }

            self.buildAndTryCandidates(item: item, mode: mode, completion: completion)
        }
    }

    /// Descarga un archivo desde la cámara y lo guarda únicamente en la biblioteca local privada de la app.
    public func downloadToLocalLibrary(item: SDFileItem, completion: @escaping (Bool, String) -> Void) {
        if LocalLibraryManager.shared.isDownloaded(item) {
            DispatchQueue.main.async {
                completion(true, "\(item.filename) ya está guardado en Local.")
            }
            return
        }

        DispatchQueue.main.async {
            self.isDownloading = true
            self.downloadProgress = 0.0
            self.statusMessage = "Guardando \(item.filename) en Local..."
        }

        downloadToTemporaryFile(item: item) { [weak self] tempURL in
            guard let self = self else { return }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(false, "No se pudo descargar \(item.filename) de la cámara.")
                }
                return
            }

            var stitched: UIImage? = nil
            if !item.isVideo {
                DispatchQueue.main.async {
                    self.statusMessage = "Cosiendo vista 360° para Local..."
                }
                stitched = PhotoStitcher.shared.stitchForInteractivePreview(from: tempURL, maxPixelSize: 3840)
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Generando miniatura para Local..."
                }
                stitched = ThumbnailCache.shared.generateVideoThumbnail(from: tempURL)
            }

            LocalLibraryManager.shared.saveMedia(item: item, originalTempURL: tempURL, stitchedImage: stitched) { saved in
                try? FileManager.default.removeItem(at: tempURL)
                DispatchQueue.main.async {
                    self.isDownloading = false
                    if saved != nil {
                        completion(true, "\(item.filename) guardado en Biblioteca Local.")
                    } else {
                        completion(false, "No se pudo guardar \(item.filename) en Local.")
                    }
                }
            }
        }
    }

    private func buildCandidateURLs(for item: SDFileItem, preferPreviewProxy: Bool = false) -> [URL] {
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nameVariants = filenameVariants(for: item.filename, preferPreviewProxy: preferPreviewProxy)

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
        return candidateURLs
    }

    /// Resuelve la URL HTTP directa en la cámara (mediante HEAD) para streaming de video sin descargar todo el archivo
    public func resolveMediaURL(item: SDFileItem, preferPreviewProxy: Bool = false, completion: @escaping (URL?, Int64?) -> Void) {
        let candidates = buildCandidateURLs(for: item, preferPreviewProxy: preferPreviewProxy)
        probeNextURL(candidates: candidates) { [weak self] foundURL, contentLength in
            if let foundURL = foundURL {
                completion(foundURL, contentLength)
            } else {
                let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                self?.discoverCherokeeExactLink(folder: cleanFolder, filename: item.filename) { discURL in
                    completion(discURL, nil)
                }
            }
        }
    }

    private func probeNextURL(candidates: [URL], completion: @escaping (URL?, Int64?) -> Void) {
        guard let currentURL = candidates.first else {
            completion(nil, nil)
            return
        }
        let remaining = Array(candidates.dropFirst())
        var req = URLRequest(url: currentURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 4.0

        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil {
                let pathStr = currentURL.path
                if pathStr.contains("/DCIM/") {
                    self?.rememberedWorkingPrefix = "/DCIM"
                } else if pathStr.contains("/SD0/DCIM/") {
                    self?.rememberedWorkingPrefix = "/SD0/DCIM"
                } else if pathStr.contains("/tmp/SD0/DCIM/") {
                    self?.rememberedWorkingPrefix = "/tmp/SD0/DCIM"
                } else {
                    self?.rememberedWorkingPrefix = ""
                }
                let size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                completion(currentURL, size)
            } else {
                self?.probeNextURL(candidates: remaining, completion: completion)
            }
        }.resume()
    }

    /// Descarga directamente el archivo original de la cámara a un archivo temporal local
    public func downloadToTemporaryFile(item: SDFileItem, completion: @escaping (URL?) -> Void) {
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidateURLs = buildCandidateURLs(for: item)

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

    private func filenameVariants(for filename: String, preferPreviewProxy: Bool = false) -> [String] {
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
            if upper.hasSuffix("AA.MP4") || upper.hasSuffix("AB.MP4") {
                stem = String(clean.dropLast(6))
            } else {
                stem = String(clean.dropLast(4))
            }
            if preferPreviewProxy {
                variants.append("\(stem)AB.MP4")
                variants.append("\(stem)ab.mp4")
            }
            variants.append("\(stem)AA.MP4")
            variants.append(clean)
            variants.append("\(stem).MP4")
            variants.append("\(stem)aa.mp4")
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

                self.exportFileToPhotos(destinationURL: destinationURL, item: item, mode: mode, completion: completion)
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

    private func exportFileToPhotos(
        destinationURL: URL,
        item: SDFileItem,
        mode: StitchMode,
        completion: @escaping (Bool, String) -> Void
    ) {
        let shotLocation = LocationManager.shared.getBestLocation(for: item.filename)

        if item.isVideo {
            if mode == .original {
                DispatchQueue.main.async {
                    self.statusMessage = "Guardando video original en Apple Fotos..."
                }
                saveFilesToPhotosLibrary(
                    filesToSave: [destinationURL],
                    cleanupURLs: [destinationURL],
                    item: item,
                    mode: mode,
                    location: shotLocation,
                    completion: completion
                )
                return
            }

            DispatchQueue.main.async {
                self.downloadProgress = 0.0
                self.statusMessage = "Cosiendo video 360°..."
            }

            let stitchedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiSphere_360_\(UUID().uuidString).mp4")

            VideoStitcher.shared.stitchVideo(
                inputURL: destinationURL,
                outputURL: stitchedURL,
                location: shotLocation,
                progress: { [weak self] p in
                    self?.downloadProgress = Float(p)
                    self?.statusMessage = "Cosiendo video 360°... \(Int(p * 100))%"
                },
                completion: { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(let finalStitchedURL):
                        DispatchQueue.main.async {
                            self.statusMessage = "Guardando video 360° en Apple Fotos..."
                        }
                        let filesToSave = (mode == .both) ? [destinationURL, finalStitchedURL] : [finalStitchedURL]
                        self.saveFilesToPhotosLibrary(
                            filesToSave: filesToSave,
                            cleanupURLs: [destinationURL, finalStitchedURL],
                            item: item,
                            mode: mode,
                            location: shotLocation,
                            completion: completion
                        )
                    case .failure(let err):
                        try? FileManager.default.removeItem(at: destinationURL)
                        try? FileManager.default.removeItem(at: stitchedURL)
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            completion(false, "Error al coser el video 360°: \(err.localizedDescription)")
                        }
                    }
                }
            )
            return
        }

        DispatchQueue.main.async {
            self.statusMessage = (mode == .stitched360 || mode == .both)
                ? "Procesando metadatos 360°..."
                : "Guardando en Apple Fotos..."
        }

        let filesToSave = PhotoStitcher.shared.processDownloadedFile(
            at: destinationURL,
            isVideo: false,
            mode: mode,
            location: shotLocation
        )
        var cleanup = filesToSave
        if !cleanup.contains(destinationURL) {
            cleanup.append(destinationURL)
        }
        saveFilesToPhotosLibrary(
            filesToSave: filesToSave,
            cleanupURLs: cleanup,
            item: item,
            mode: mode,
            location: shotLocation,
            completion: completion
        )
    }

    private func saveFilesToPhotosLibrary(
        filesToSave: [URL],
        cleanupURLs: [URL],
        item: SDFileItem,
        mode: StitchMode,
        location: CLLocation?,
        completion: @escaping (Bool, String) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges({
            for fileURL in filesToSave {
                if item.isVideo {
                    let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                    if let loc = location {
                        req?.location = loc
                    }
                } else {
                    let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    if let loc = location {
                        req?.location = loc
                    }
                }
            }
        }) { success, saveError in
            for url in cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }

            if success {
                LocalLibraryManager.shared.markExported(id: item.id)
            }

            DispatchQueue.main.async {
                self.isDownloading = false
                if success {
                    let msg: String
                    if item.isVideo {
                        switch mode {
                        case .stitched360:
                            msg = "¡Video 360° (con metadatos espaciales) guardado en Apple Fotos!"
                        case .both:
                            msg = "¡Se guardaron ambos videos (Original + 360°) en Apple Fotos!"
                        case .original:
                            msg = "¡Video original guardado en Apple Fotos!"
                        }
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
    }

    /// Guarda una captura (UIImage) de la vista previa actual en Apple Fotos con su ubicación GPS.
    public func saveSnapshotImage(
        _ image: UIImage,
        for item: SDFileItem,
        label: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false, "Permiso denegado para guardar en Apple Fotos. Concede permiso en Ajustes > Mi Sphere 360.")
                }
                return
            }

            let shotLocation = LocationManager.shared.getBestLocation(for: item.filename)
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest.creationRequestForAsset(from: image)
                if let loc = shotLocation {
                    req.location = loc
                }
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(true, "¡Captura (\(label)) guardada en Apple Fotos!")
                    } else {
                        completion(false, error?.localizedDescription ?? "No se pudo guardar la captura en Fotos.")
                    }
                }
            }
        }
    }

    /// Exporta un video plano ("Reframe") en el modo de proyección y relación de aspecto elegidos hacia Apple Fotos.
    public func reframeAndExportVideo(
        item: SDFileItem,
        projectionMode: PhotoProjectionMode,
        yaw: Float,
        pitch: Float,
        fovDeg: Float,
        aspectPreset: ReframeAspectPreset,
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
                self.statusMessage = "Preparando \(item.filename)..."
            }

            let runReframe: (URL, Bool) -> Void = { sourceURL, shouldCleanupSource in
                let shotLocation = LocationManager.shared.getBestLocation(for: item.filename)
                let outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MiSphere_Reframe_\(UUID().uuidString).mp4")

                DispatchQueue.main.async {
                    self.statusMessage = "Renderizando \(projectionMode.rawValue) (\(aspectPreset.rawValue))..."
                }

                VideoStitcher.shared.stitchReframedVideo(
                    inputURL: sourceURL,
                    outputURL: outURL,
                    projectionMode: projectionMode,
                    yaw: yaw,
                    pitch: pitch,
                    fovDeg: fovDeg,
                    aspectPreset: aspectPreset,
                    location: shotLocation,
                    progress: { [weak self] p in
                        self?.downloadProgress = Float(p)
                        self?.statusMessage = "Renderizando \(projectionMode.rawValue)... \(Int(p * 100))%"
                    },
                    completion: { [weak self] result in
                        guard let self = self else { return }
                        if shouldCleanupSource {
                            try? FileManager.default.removeItem(at: sourceURL)
                        }
                        switch result {
                        case .success(let finalURL):
                            PHPhotoLibrary.shared().performChanges({
                                let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: finalURL)
                                if let loc = shotLocation {
                                    req?.location = loc
                                }
                            }) { success, saveError in
                                try? FileManager.default.removeItem(at: finalURL)
                                DispatchQueue.main.async {
                                    self.isDownloading = false
                                    if success {
                                        completion(true, "¡Video \(projectionMode.rawValue) (\(aspectPreset.rawValue)) guardado en Apple Fotos!")
                                    } else {
                                        completion(false, saveError?.localizedDescription ?? "Error al guardar el video en Fotos.")
                                    }
                                }
                            }
                        case .failure(let err):
                            try? FileManager.default.removeItem(at: outURL)
                            DispatchQueue.main.async {
                                self.isDownloading = false
                                completion(false, "Error al renderizar video: \(err.localizedDescription)")
                            }
                        }
                    }
                )
            }

            if let localAsset = LocalLibraryManager.shared.asset(for: item) {
                let localOrig = LocalLibraryManager.shared.originalURL(for: localAsset)
                runReframe(localOrig, false)
            } else {
                self.downloadToTemporaryFile(item: item) { tempURL in
                    guard let tempURL = tempURL else {
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            completion(false, "No se pudo descargar \(item.filename) de la cámara.")
                        }
                        return
                    }
                    runReframe(tempURL, true)
                }
            }
        }
    }
}
