import Foundation
import UIKit
import AVFoundation

/// Representa un archivo guardado en la biblioteca privada local de la app (`Documents/MiSphereLocal/`).
public struct LocalMediaAsset: Identifiable, Codable, Hashable {
    public let id: String
    public let folder: String
    public let filename: String
    public let isVideo: Bool
    public let date: String
    public let originalRelativePath: String
    public var stitchedRelativePath: String?
    public var thumbnailRelativePath: String?
    public let savedAt: Date
    public var fileSizeBytes: Int64
    public var exportedToPhotos: Bool
}

/// Administra la biblioteca local persistente de originales, versiones cosidas 360° y miniaturas.
public final class LocalLibraryManager: ObservableObject {
    public static let shared = LocalLibraryManager()

    @Published public private(set) var assets: [LocalMediaAsset] = []
    @Published public private(set) var totalStorageBytes: Int64 = 0

    private let ioQueue = DispatchQueue(label: "com.ssombra.misphere360.locallib", qos: .utility)
    private let baseDirectory: URL
    private let originalsDirectory: URL
    private let stitchedDirectory: URL
    private let thumbnailsDirectory: URL
    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseDirectory = docs.appendingPathComponent("MiSphereLocal", isDirectory: true)
        originalsDirectory = baseDirectory.appendingPathComponent("Originals", isDirectory: true)
        stitchedDirectory = baseDirectory.appendingPathComponent("Stitched", isDirectory: true)
        thumbnailsDirectory = baseDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        indexURL = baseDirectory.appendingPathComponent("index.json")

        createDirectoriesIfNeeded()
        loadIndex()
    }

    private func createDirectoriesIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stitchedDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    private func safeKey(for id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LocalMediaAsset].self, from: data) else {
            self.assets = []
            self.totalStorageBytes = 0
            return
        }
        // Filtrar entradas cuyo archivo original ya no exista en disco
        let fm = FileManager.default
        let valid = decoded.filter { asset in
            let orig = baseDirectory.appendingPathComponent(asset.originalRelativePath)
            return fm.fileExists(atPath: orig.path)
        }
        self.assets = valid
        self.totalStorageBytes = calculateTotalBytes(valid)
        if valid.count != decoded.count {
            persistIndex(valid)
        }
    }

    private func persistIndex(_ list: [LocalMediaAsset]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func calculateTotalBytes(_ list: [LocalMediaAsset]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for item in list {
            total += item.fileSizeBytes
            if let s = item.stitchedRelativePath,
               let attr = try? fm.attributesOfItem(atPath: baseDirectory.appendingPathComponent(s).path),
               let sz = attr[.size] as? Int64 {
                total += sz
            }
            if let t = item.thumbnailRelativePath,
               let attr = try? fm.attributesOfItem(atPath: baseDirectory.appendingPathComponent(t).path),
               let sz = attr[.size] as? Int64 {
                total += sz
            }
        }
        return total
    }

    // MARK: - Consultas

    public func asset(for id: String) -> LocalMediaAsset? {
        assets.first(where: { $0.id == id })
    }

    public func asset(for item: SDFileItem) -> LocalMediaAsset? {
        asset(for: item.id)
    }

    public func isDownloaded(_ item: SDFileItem) -> Bool {
        asset(for: item.id) != nil
    }

    public func originalURL(for asset: LocalMediaAsset) -> URL {
        baseDirectory.appendingPathComponent(asset.originalRelativePath)
    }

    public func stitchedURL(for asset: LocalMediaAsset) -> URL? {
        guard let rel = asset.stitchedRelativePath else { return nil }
        let url = baseDirectory.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func thumbnailURL(forId id: String) -> URL? {
        guard let asset = asset(for: id), let rel = asset.thumbnailRelativePath else { return nil }
        let url = baseDirectory.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func toSDFileItem(_ asset: LocalMediaAsset) -> SDFileItem {
        SDFileItem(folder: asset.folder, filename: asset.filename, isVideo: asset.isVideo, date: asset.date)
    }

    public var formattedTotalStorage: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB, .useKB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: totalStorageBytes)
    }

    // MARK: - Guardado en Local

    /// Guarda una foto (original dual-fisheye + versión cosida + miniatura) en la biblioteca local.
    public func saveMedia(
        item: SDFileItem,
        originalTempURL: URL,
        stitchedImage: UIImage? = nil,
        completion: ((LocalMediaAsset?) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            self.createDirectoriesIfNeeded()
            let fm = FileManager.default
            let key = self.safeKey(for: item.id)
            let ext = item.isVideo ? "MP4" : "JPG"

            let origRel = "Originals/\(key).\(ext)"
            let origDest = self.baseDirectory.appendingPathComponent(origRel)

            do {
                if fm.fileExists(atPath: origDest.path) {
                    try fm.removeItem(at: origDest)
                }
                try fm.copyItem(at: originalTempURL, to: origDest)
            } catch {
                print("⚠️ Error guardando original en Local: \(error)")
                DispatchQueue.main.async { completion?(nil) }
                return
            }

            let fileSize = (try? fm.attributesOfItem(atPath: origDest.path)[.size] as? Int64) ?? 0

            var stitchedRel: String? = nil
            if let img = stitchedImage, !item.isVideo {
                let sRel = "Stitched/\(key)_360.jpg"
                let sDest = self.baseDirectory.appendingPathComponent(sRel)
                if let jpgData = img.jpegData(compressionQuality: 0.92) {
                    try? jpgData.write(to: sDest, options: .atomic)
                    stitchedRel = sRel
                }
            }

            var thumbRel: String? = nil
            if let thumbImg = self.generateThumbnail(for: item, originalURL: origDest, stitchedImage: stitchedImage),
               let thumbData = thumbImg.jpegData(compressionQuality: 0.80) {
                let tRel = "Thumbnails/\(key)_thm.jpg"
                let tDest = self.baseDirectory.appendingPathComponent(tRel)
                try? thumbData.write(to: tDest, options: .atomic)
                thumbRel = tRel
            }

            let existingExported = self.assets.first(where: { $0.id == item.id })?.exportedToPhotos ?? false
            let newAsset = LocalMediaAsset(
                id: item.id,
                folder: item.folder,
                filename: item.filename,
                isVideo: item.isVideo,
                date: item.date,
                originalRelativePath: origRel,
                stitchedRelativePath: stitchedRel ?? self.assets.first(where: { $0.id == item.id })?.stitchedRelativePath,
                thumbnailRelativePath: thumbRel ?? self.assets.first(where: { $0.id == item.id })?.thumbnailRelativePath,
                savedAt: Date(),
                fileSizeBytes: fileSize,
                exportedToPhotos: existingExported
            )

            DispatchQueue.main.async {
                var updated = self.assets.filter { $0.id != item.id }
                updated.insert(newAsset, at: 0)
                self.assets = updated
                self.totalStorageBytes = self.calculateTotalBytes(updated)
                self.persistIndex(updated)
                completion?(newAsset)
            }
        }
    }

    /// Guarda o actualiza solo la imagen cosida para una foto ya existente en Local.
    public func saveStitchedImage(_ image: UIImage, forId id: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let key = self.safeKey(for: id)
            let sRel = "Stitched/\(key)_360.jpg"
            let sDest = self.baseDirectory.appendingPathComponent(sRel)
            guard let jpgData = image.jpegData(compressionQuality: 0.92) else { return }
            try? jpgData.write(to: sDest, options: .atomic)

            DispatchQueue.main.async {
                guard let idx = self.assets.firstIndex(where: { $0.id == id }) else { return }
                var updated = self.assets
                updated[idx].stitchedRelativePath = sRel
                self.assets = updated
                self.totalStorageBytes = self.calculateTotalBytes(updated)
                self.persistIndex(updated)
            }
        }
    }

    public func markExported(id: String) {
        DispatchQueue.main.async {
            guard let idx = self.assets.firstIndex(where: { $0.id == id }) else { return }
            var updated = self.assets
            updated[idx].exportedToPhotos = true
            self.assets = updated
            self.persistIndex(updated)
        }
    }

    public func deleteAsset(id: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            if let existing = self.assets.first(where: { $0.id == id }) {
                try? fm.removeItem(at: self.baseDirectory.appendingPathComponent(existing.originalRelativePath))
                if let s = existing.stitchedRelativePath {
                    try? fm.removeItem(at: self.baseDirectory.appendingPathComponent(s))
                }
                if let t = existing.thumbnailRelativePath {
                    try? fm.removeItem(at: self.baseDirectory.appendingPathComponent(t))
                }
            }
            DispatchQueue.main.async {
                let updated = self.assets.filter { $0.id != id }
                self.assets = updated
                self.totalStorageBytes = self.calculateTotalBytes(updated)
                self.persistIndex(updated)
            }
        }
    }

    public func clearAll() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            try? fm.removeItem(at: self.originalsDirectory)
            try? fm.removeItem(at: self.stitchedDirectory)
            try? fm.removeItem(at: self.thumbnailsDirectory)
            try? fm.removeItem(at: self.indexURL)
            self.createDirectoriesIfNeeded()

            DispatchQueue.main.async {
                self.assets = []
                self.totalStorageBytes = 0
            }
        }
    }

    private func generateThumbnail(for item: SDFileItem, originalURL: URL, stitchedImage: UIImage?) -> UIImage? {
        let targetWidth: CGFloat = 360
        if let stitched = stitchedImage {
            let scale = targetWidth / max(stitched.size.width, 1)
            let size = CGSize(width: targetWidth, height: stitched.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                stitched.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        if item.isVideo {
            let asset = AVURLAsset(url: originalURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 270)
            if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                return UIImage(cgImage: cgImg)
            }
            return nil
        } else if let img = UIImage(contentsOfFile: originalURL.path) {
            let scale = targetWidth / max(img.size.width, 1)
            let size = CGSize(width: targetWidth, height: img.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return nil
    }
}
