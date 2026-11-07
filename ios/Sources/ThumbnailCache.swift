import Foundation
import UIKit
import SwiftUI
import ImageIO

/// Administra la descarga asíncrona, decodificación eficiente y caché en disco/RAM de miniaturas de la microSD
public class ThumbnailCache: ObservableObject {
    public static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let downloadQueue = OperationQueue()
    private var inFlightKeys: Set<String> = []
    private let syncQueue = DispatchQueue(label: "com.misphere360.thumbcache.sync")
    private let diskCacheURL: URL

    /// Prefijo HTTP que ya funcionó para evitar pruebas redundantes
    private var rememberedPrefix: String? = "/DCIM"

    public init() {
        memoryCache.countLimit = 150
        downloadQueue.maxConcurrentOperationCount = 2
        downloadQueue.qualityOfService = .userInitiated

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    private func cacheKey(for item: SDFileItem) -> String {
        return "\(item.folder)_\(item.filename)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func diskFileURL(for key: String) -> URL {
        return diskCacheURL.appendingPathComponent("\(key).jpg")
    }

    /// Obtiene miniatura de memoria o disco síncronamente si ya existe
    public func getThumbnail(for item: SDFileItem) -> UIImage? {
        let key = cacheKey(for: item)

        // 1. Memoria RAM
        if let memImg = memoryCache.object(forKey: key as NSString) {
            return memImg
        }

        // 2. Caché en Disco
        let fileURL = diskFileURL(for: key)
        if let data = try? Data(contentsOf: fileURL), let diskImg = UIImage(data: data) {
            memoryCache.setObject(diskImg, forKey: key as NSString)
            return diskImg
        }

        return nil
    }

    /// Carga la miniatura de forma asíncrona sin bloquear la UI ni saturar el servidor Cherokee de la cámara
    public func loadThumbnail(for item: SDFileItem, completion: @escaping (UIImage?) -> Void) {
        let key = cacheKey(for: item)

        if let existing = getThumbnail(for: item) {
            completion(existing)
            return
        }

        syncQueue.async {
            if self.inFlightKeys.contains(key) {
                return
            }
            self.inFlightKeys.insert(key)

            // Para archivos de video, intentar buscar el archivo .THM de Ambarella
            if item.isVideo {
                self.queueVideoThumbnailFetch(item: item, key: key, completion: completion)
            } else {
                self.queuePhotoThumbnailFetch(item: item, key: key, completion: completion)
            }
        }
    }

    private func queuePhotoThumbnailFetch(item: SDFileItem, key: String, completion: @escaping (UIImage?) -> Void) {
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawName = item.filename
        var candidates: [String] = []

        if rawName.uppercased().hasSuffix(".JPG") {
            let stem = rawName.dropLast(4)
            candidates.append("\(stem)AA.JPG")
            candidates.append(rawName)
            candidates.append("\(stem)aa.jpg")
            candidates.append(rawName.lowercased())
        } else {
            candidates.append(rawName)
        }

        var prefixes = ["/DCIM", "", "/SD0/DCIM", "/tmp/SD0/DCIM"]
        if let pref = rememberedPrefix {
            prefixes.removeAll(where: { $0 == pref })
            prefixes.insert(pref, at: 0)
        }

        var candidateURLs: [URL] = []
        for p in prefixes {
            for c in candidates {
                if let u = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(p)/\(cleanFolder)/\(c)") {
                    if !candidateURLs.contains(u) {
                        candidateURLs.append(u)
                    }
                }
            }
        }

        downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.downloadAndProcessThumbnail(urls: candidateURLs, key: key) { [weak self] image in
                self?.syncQueue.async {
                    self?.inFlightKeys.remove(key)
                }
                DispatchQueue.main.async {
                    completion(image)
                }
            }
        }
    }

    private func queueVideoThumbnailFetch(item: SDFileItem, key: String, completion: @escaping (UIImage?) -> Void) {
        // En cámaras Ambarella, la miniatura de un video VID_xxx.MP4 suele llamarse VID_xxx.THM
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawName = item.filename
        var thmNames: [String] = []
        if rawName.uppercased().hasSuffix(".MP4") {
            let stem = rawName.dropLast(4)
            thmNames.append("\(stem)AA.THM")
            thmNames.append("\(stem).THM")
            thmNames.append("\(stem)aa.thm")
            thmNames.append("\(stem).thm")
        }

        let prefixes = ["/DCIM", "", "/SD0/DCIM"]
        var candidateURLs: [URL] = []
        for p in prefixes {
            for t in thmNames {
                if let u = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(p)/\(cleanFolder)/\(t)") {
                    candidateURLs.append(u)
                }
            }
        }

        downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.downloadAndProcessThumbnail(urls: candidateURLs, key: key) { [weak self] image in
                self?.syncQueue.async {
                    self?.inFlightKeys.remove(key)
                }
                DispatchQueue.main.async {
                    completion(image)
                }
            }
        }
    }

    private func downloadAndProcessThumbnail(urls: [URL], key: String, completion: @escaping (UIImage?) -> Void) {
        guard let url = urls.first else {
            completion(nil)
            return
        }

        let remaining = Array(urls.dropFirst())

        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0

        let sema = DispatchSemaphore(value: 0)
        var resultImage: UIImage? = nil
        var didSucceed = false

        let task = URLSession.shared.downloadTask(with: req) { [weak self] localURL, resp, _ in
            defer { sema.signal() }
            guard let self = self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

            if code == 200, let localURL = localURL {
                if let thumb = self.generateOptimizedThumbnail(from: localURL) {
                    resultImage = thumb
                    didSucceed = true
                    self.saveThumbnailToCaches(thumb, key: key)

                    // Recordar prefijo exitoso
                    let path = url.path
                    if path.contains("/DCIM/") {
                        self.rememberedPrefix = "/DCIM"
                    } else if path.contains("/SD0/DCIM/") {
                        self.rememberedPrefix = "/SD0/DCIM"
                    } else {
                        self.rememberedPrefix = ""
                    }
                }
            }
        }
        task.resume()
        sema.wait()

        if didSucceed, let img = resultImage {
            completion(img)
        } else {
            // Probar siguiente URL candidata
            downloadAndProcessThumbnail(urls: remaining, key: key, completion: completion)
        }
    }

    private func generateOptimizedThumbnail(from fileURL: URL) -> UIImage? {
        // Cose ópticamente el doble ojo de pez a un panorama 360° rectangular estilo Insta360
        if let stitched = PhotoStitcher.shared.generateStitchedThumbnail(from: fileURL, maxPixelSize: 480) {
            return stitched
        }

        // Fallback en caso de que sea video o falle el cosido C
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, imageSourceOptions) else {
            return nil
        }

        let downsampledOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampledOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgThumb)
    }

    private func saveThumbnailToCaches(_ image: UIImage, key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

        let targetDiskURL = diskFileURL(for: key)
        if let jpeg = image.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: targetDiskURL, options: .atomic)
        }
    }
}

/// Vista de miniatura asíncrona estilo Insta360 con carga progresiva fluida
public struct SDThumbnailView: View {
    let item: SDFileItem
    @State private var thumbnail: UIImage? = nil
    @State private var isLoading = true

    public var body: some View {
        ZStack {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            } else {
                ZStack {
                    Color(red: 0.10, green: 0.12, blue: 0.17)
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: item.isVideo ? "video.fill" : "camera.metering.matrix")
                            .foregroundColor(.white.opacity(0.25))
                            .font(.system(size: 26))
                    }
                }
            }
        }
        .onAppear {
            if let cached = ThumbnailCache.shared.getThumbnail(for: item) {
                self.thumbnail = cached
                self.isLoading = false
            } else {
                ThumbnailCache.shared.loadThumbnail(for: item) { img in
                    self.thumbnail = img
                    self.isLoading = false
                }
            }
        }
    }
}
