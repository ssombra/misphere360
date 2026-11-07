import Foundation
import UIKit
import SwiftUI
import ImageIO

/// Administra la descarga asíncrona y caché de miniaturas de la tarjeta microSD de la cámara
public class ThumbnailCache: ObservableObject {
    public static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: URLSessionDataTask] = [:]
    private let queue = DispatchQueue(label: "com.misphere360.thumbcache", qos: .userInitiated)

    public init() {
        cache.countLimit = 200 // Máximo 200 miniaturas en RAM
    }

    public func getThumbnail(for item: SDFileItem) -> UIImage? {
        let key = "\(item.folder)/\(item.filename)" as NSString
        return cache.object(forKey: key)
    }

    public func loadThumbnail(for item: SDFileItem, completion: @escaping (UIImage?) -> Void) {
        let key = "\(item.folder)/\(item.filename)" as NSString

        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        // Descargar primeros 90 KB o imagen para decodificar miniatura rápida
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawName = item.filename
        var candidates: [String] = []

        if rawName.uppercased().hasSuffix(".JPG") {
            let stem = rawName.dropLast(4)
            candidates.append("\(stem)AA.JPG")
            candidates.append(rawName)
        } else {
            candidates.append(rawName)
        }

        let prefixes = ["", "/DCIM", "/SD0/DCIM", "/tmp/SD0/DCIM"]
        var candidateURLs: [URL] = []
        for p in prefixes {
            for c in candidates {
                if let u = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(p)/\(cleanFolder)/\(c)") {
                    candidateURLs.append(u)
                }
            }
        }

        tryFetchThumbnail(urls: candidateURLs, key: key, completion: completion)
    }

    private func tryFetchThumbnail(urls: [URL], key: NSString, completion: @escaping (UIImage?) -> Void) {
        guard let url = urls.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let remaining = Array(urls.dropFirst())

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        // Solicitar primeros 32 KB donde viene incrustada la miniatura EXIF de 5 KB
        req.setValue("bytes=0-32768", forHTTPHeaderField: "Range")

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 200 (Completo) o 206 (Partial Content por Range)
            if (statusCode == 200 || statusCode == 206), let data = data, !data.isEmpty {
                if let thumb = self.extractThumbnail(data: data) {
                    self.cache.setObject(thumb, forKey: key)
                    DispatchQueue.main.async { completion(thumb) }
                    return
                }
            }

            // Probar siguiente URL candidata
            self.tryFetchThumbnail(urls: remaining, key: key, completion: completion)
        }
        task.resume()
    }

    private func extractThumbnail(data: Data) -> UIImage? {
        // En los archivos JPG de Xiaomi Mi Sphere, a partir del byte ~1536 se encuentra incrustada
        // la miniatura EXIF completa de 5 KB delimitada por 0xFFD8 y 0xFFD9
        if data.count > 10, data[0] == 0xFF, data[1] == 0xD8 {
            let limit = min(data.count - 1, 65536)
            var secondSOI: Int? = nil
            for i in 2..<limit {
                if data[i] == 0xFF && data[i + 1] == 0xD8 {
                    secondSOI = i
                    break
                }
            }
            if let start = secondSOI {
                for i in (start + 2)..<limit {
                    if data[i] == 0xFF && data[i + 1] == 0xD9 {
                        let thumbSlice = data.subdata(in: start..<(i + 2))
                        if let img = UIImage(data: thumbSlice) {
                            return img
                        }
                        break
                    }
                }
            }
        }
        return downsampleImage(data: data, maxPixelSize: 360)
    }

    private func downsampleImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            // Si la lectura parcial de bytes no cerró el JPEG, probar UIImage directo
            return UIImage(data: data)
        }

        let downsampledOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampledOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: downsampledImage)
    }
}

/// Vista de miniatura asíncrona estilo Insta360
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
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                ZStack {
                    Color(red: 0.12, green: 0.14, blue: 0.20)
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: item.isVideo ? "video.fill" : "camera.metering.matrix")
                            .foregroundColor(.white.opacity(0.3))
                            .font(.system(size: 24))
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
