import Foundation
import CoreGraphics
import ImageIO

public enum StitchMode: String, CaseIterable, Identifiable {
    case stitched360 = "360"
    case both = "both"
    case original = "raw"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .stitched360: return "🌐 Solo 360°"
        case .both: return "📦 Ambas"
        case .original: return "🔘 Solo Original"
        }
    }

    public var explanation: String {
        switch self {
        case .stitched360:
            return "Guarda la versión 360° interactiva con metadatos GPano lista para ver en Apple Fotos."
        case .both:
            return "Guarda tanto el archivo original de la cámara como la versión 360° procesada."
        case .original:
            return "Guarda únicamente el archivo original tal cual viene en la tarjeta microSD."
        }
    }
}

public class PhotoStitcher {
    public static let shared = PhotoStitcher()

    private let lutURL: URL? = {
        Bundle.main.url(forResource: "factory_lut", withExtension: "bin")
    }()

    /// Procesa una foto según el modo seleccionado (360°, Original o Ambas)
    /// Retorna la lista de URLs locales que deben guardarse en el Carrete de Fotos
    public func processDownloadedFile(at localURL: URL, isVideo: Bool, mode: StitchMode) -> [URL] {
        if isVideo || mode == .original {
            return [localURL]
        }

        guard let jpgData = try? Data(contentsOf: localURL) else {
            return [localURL]
        }

        let stitchedResultURL = processPhotoTo360(inputURL: localURL, data: jpgData)

        switch mode {
        case .stitched360:
            return [stitchedResultURL ?? localURL]
        case .both:
            if let st = stitchedResultURL, st != localURL {
                return [localURL, st]
            } else {
                return [localURL]
            }
        case .original:
            return [localURL]
        }
    }

    private func processPhotoTo360(inputURL: URL, data: Data) -> URL? {
        let info = parseJpegInfo(data)
        let width = info.width
        let height = info.height

        // Si ya cuenta con metadatos GPano oficiales, ya es 360° interactiva
        if info.hasGPano {
            return inputURL
        }

        let origExif = extractOriginalExif(from: data)
        let xmpSeg = buildGPanoXMP(width: width, height: height)

        let fileManager = FileManager.default
        let outName = "MiSphere_360_\(UUID().uuidString).JPG"
        let outURL = fileManager.temporaryDirectory.appendingPathComponent(outName)

        // CASO 1: Foto cosida en cámara (en 3.5K o 7K cosido directo)
        // Solo requiere inyección del bloque XMP GPano oficial para que Apple Fotos la abra en 360°
        if !info.isDualFisheye {
            let cleanData: Data
            if let base = info.lutBase, base > 0 && base < data.count {
                cleanData = data.subdata(in: 0..<base)
            } else {
                cleanData = data
            }
            let finalData = injectExifAndXmp(renderedJpg: cleanData, origExifSeg: origExif, xmpSeg: xmpSeg)
            if (try? finalData.write(to: outURL)) != nil {
                return outURL
            }
            return inputURL
        }

        // CASO 2: Foto de doble ojo de pez (Dual Fisheye 6912x3456)
        // Coser ópticamente usando el núcleo C multihilo y la tabla de calibración de fábrica
        guard let lut = lutURL, fileManager.fileExists(atPath: lut.path) else {
            // Si falta el archivo LUT, inyectar GPano directamente como fallback
            let finalData = injectExifAndXmp(renderedJpg: data, origExifSeg: origExif, xmpSeg: xmpSeg)
            try? finalData.write(to: outURL)
            return outURL
        }

        let intermediateName = "MiSphere_raw_stitch_\(UUID().uuidString).JPG"
        let intermediateURL = fileManager.temporaryDirectory.appendingPathComponent(intermediateName)

        let status = stitch_dual_fisheye_c(
            inputURL.path,
            lut.path,
            intermediateURL.path
        )

        if status == 0, let stitchedBytes = try? Data(contentsOf: intermediateURL) {
            let finalBytes = injectExifAndXmp(renderedJpg: stitchedBytes, origExifSeg: origExif, xmpSeg: xmpSeg)
            try? finalBytes.write(to: outURL)
            try? fileManager.removeItem(at: intermediateURL)
            return outURL
        } else {
            try? fileManager.removeItem(at: intermediateURL)
            // Fallback si falló el cosido C
            let finalData = injectExifAndXmp(renderedJpg: data, origExifSeg: origExif, xmpSeg: xmpSeg)
            try? finalData.write(to: outURL)
            return outURL
        }
    }

    // MARK: - Análisis de Dimensiones y Banderas EXIF

    private struct JpegInfo {
        var width: Int
        var height: Int
        var hasGPano: Bool
        var isDualFisheye: Bool
        var lutBase: Int?
    }

    private func parseJpegInfo(_ data: Data) -> JpegInfo {
        var width = 6912
        var height = 3456
        let gpanoSign = "http://ns.google.com/photos/1.0/panorama/".data(using: .utf8)!
        let searchRange = 0..<min(65536, data.count)
        let hasGPano = data.subdata(in: searchRange).range(of: gpanoSign) != nil

        let lutBase = findLutBase(in: data)
        let hasLutTrailer = lutBase != nil

        // Buscar SOF0 (0xFFC0) o SOF2 (0xFFC2) para dimensiones exactas
        if data.count > 10, data[0] == 0xFF, data[1] == 0xD8 {
            var idx = 2
            while idx < data.count - 9 {
                if data[idx] != 0xFF { idx += 1; continue }
                let marker = data[idx + 1]
                if marker == 0xDA { break } // SOS
                if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) {
                    idx += 2
                    continue
                }
                let len = Int(data[idx + 2]) << 8 | Int(data[idx + 3])
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                    let h = Int(data[idx + 5]) << 8 | Int(data[idx + 6])
                    let w = Int(data[idx + 7]) << 8 | Int(data[idx + 8])
                    if w > 0 && h > 0 {
                        width = w
                        height = h
                    }
                    break
                }
                idx += 2 + len
            }
        }

        // Tag EXIF 0xA300 (FileSource) donde la Mi Sphere marca 'Y' (0x59) si son 2 esferas sin coser
        var a300Val: UInt32? = nil
        if let exif = extractOriginalExif(from: data), exif.count > 18 {
            let tiff = exif.subdata(in: 10..<exif.count)
            if tiff.count > 8 {
                let isLittle = tiff[0] == 0x49 && tiff[1] == 0x49
                let ifd0Off = Int(readU32(tiff, offset: 4, littleEndian: isLittle))
                if ifd0Off + 2 <= tiff.count {
                    let n0 = Int(readU16(tiff, offset: ifd0Off, littleEndian: isLittle))
                    var exifOff = 0
                    for i in 0..<n0 {
                        let pos = ifd0Off + 2 + i * 12
                        if pos + 12 <= tiff.count {
                            let tag = readU16(tiff, offset: pos, littleEndian: isLittle)
                            if tag == 0x8769 {
                                exifOff = Int(readU32(tiff, offset: pos + 8, littleEndian: isLittle))
                                break
                            }
                        }
                    }
                    if exifOff > 0 && exifOff + 2 <= tiff.count {
                        let ne = Int(readU16(tiff, offset: exifOff, littleEndian: isLittle))
                        for i in 0..<ne {
                            let pos = exifOff + 2 + i * 12
                            if pos + 12 <= tiff.count {
                                let tag = readU16(tiff, offset: pos, littleEndian: isLittle)
                                if tag == 0xA300 {
                                    a300Val = readU32(tiff, offset: pos + 8, littleEndian: isLittle)
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }

        let isDualFisheye: Bool
        if hasGPano {
            isDualFisheye = false
        } else if let a300 = a300Val {
            isDualFisheye = (a300 != 0)
        } else {
            isDualFisheye = (width == 6912 && height == 3456 && hasLutTrailer)
        }

        return JpegInfo(
            width: width,
            height: height,
            hasGPano: hasGPano,
            isDualFisheye: isDualFisheye,
            lutBase: lutBase
        )
    }

    private func findLutBase(in data: Data) -> Int? {
        let searchStart = max(0, data.count - 900_000)
        let searchData = data.subdata(in: searchStart..<data.count)
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if let range = searchData.range(of: pngHeader) {
            let base = searchStart + range.lowerBound - 64
            if base >= 0 && base < data.count {
                return base
            }
        }
        return nil
    }

    // MARK: - Inyección de EXIF y XMP GPano

    private func extractOriginalExif(from data: Data) -> Data? {
        guard data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var idx = 2
        while idx < data.count - 4 {
            if data[idx] != 0xFF { break }
            let marker = data[idx + 1]
            if marker == 0xDA { break }
            let len = Int(data[idx + 2]) << 8 | Int(data[idx + 3])
            if idx + 2 + len > data.count { break }
            let seg = data.subdata(in: idx..<(idx + 2 + len))
            if marker == 0xE1, seg.count >= 10 {
                let exifSign = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
                if seg.subdata(in: 4..<10) == exifSign {
                    return seg
                }
            }
            idx += 2 + len
        }
        return nil
    }

    private func clearDualFisheyeFlag(in exifSeg: Data) -> Data {
        guard exifSeg.count > 18 else { return exifSeg }
        var buf = exifSeg
        let tiffStart = 10
        let isLittle = buf[tiffStart] == 0x49 && buf[tiffStart + 1] == 0x49
        let ifd0Off = Int(readU32(buf, offset: tiffStart + 4, littleEndian: isLittle))
        if tiffStart + ifd0Off + 2 <= buf.count {
            let n0 = Int(readU16(buf, offset: tiffStart + ifd0Off, littleEndian: isLittle))
            var exifOff = 0
            for i in 0..<n0 {
                let pos = tiffStart + ifd0Off + 2 + i * 12
                if pos + 12 <= buf.count {
                    let tag = readU16(buf, offset: pos, littleEndian: isLittle)
                    if tag == 0x8769 {
                        exifOff = Int(readU32(buf, offset: pos + 8, littleEndian: isLittle))
                        break
                    }
                }
            }
            if exifOff > 0 && tiffStart + exifOff + 2 <= buf.count {
                let ne = Int(readU16(buf, offset: tiffStart + exifOff, littleEndian: isLittle))
                for i in 0..<ne {
                    let pos = tiffStart + exifOff + 2 + i * 12
                    if pos + 12 <= buf.count {
                        let tag = readU16(buf, offset: pos, littleEndian: isLittle)
                        if tag == 0xA300 || tag == 0xA301 {
                            // Poner valor 0 para indicar que ya está cosida
                            writeU32(&buf, offset: pos + 8, value: 0, littleEndian: isLittle)
                        }
                    }
                }
            }
        }
        return buf
    }

    private func buildGPanoXMP(width: Int, height: Int) -> Data {
        let xmpXml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="MiSphere 360 Native Stitcher">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:GPano="http://ns.google.com/photos/1.0/panorama/">
              <GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>
              <GPano:ProjectionType>equirectangular</GPano:ProjectionType>
              <GPano:FullPanoWidthPixels>\(width)</GPano:FullPanoWidthPixels>
              <GPano:FullPanoHeightPixels>\(height)</GPano:FullPanoHeightPixels>
              <GPano:CroppedAreaImageWidthPixels>\(width)</GPano:CroppedAreaImageWidthPixels>
              <GPano:CroppedAreaImageHeightPixels>\(height)</GPano:CroppedAreaImageHeightPixels>
              <GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>
              <GPano:CroppedAreaTopPixels>0</GPano:CroppedAreaTopPixels>
              <GPano:StitchingSoftware>MiSphere 360 Native Stitcher</GPano:StitchingSoftware>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        var payload = "http://ns.adobe.com/xap/1.0/\0".data(using: .utf8)!
        payload.append(xmpXml.data(using: .utf8)!)
        let length = UInt16(payload.count + 2)
        var seg = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        seg.append(payload)
        return seg
    }

    private func injectExifAndXmp(renderedJpg: Data, origExifSeg: Data?, xmpSeg: Data) -> Data {
        guard renderedJpg.count > 4, renderedJpg[0] == 0xFF, renderedJpg[1] == 0xD8 else {
            return renderedJpg
        }
        var idx = 2
        var app0Segments = Data()
        var otherSegments = Data()

        while idx < renderedJpg.count - 4 {
            if renderedJpg[idx] != 0xFF { break }
            let marker = renderedJpg[idx + 1]
            if marker == 0xDB || marker == 0xC0 || marker == 0xC4 || marker == 0xDA {
                break
            }
            let len = Int(renderedJpg[idx + 2]) << 8 | Int(renderedJpg[idx + 3])
            if idx + 2 + len > renderedJpg.count { break }
            let seg = renderedJpg.subdata(in: idx..<(idx + 2 + len))
            if marker == 0xE0 {
                app0Segments.append(seg)
            } else if marker != 0xE1 {
                otherSegments.append(seg)
            }
            idx += 2 + len
        }

        var result = Data([0xFF, 0xD8])
        result.append(app0Segments)
        if let exif = origExifSeg {
            result.append(clearDualFisheyeFlag(in: exif))
        }
        result.append(xmpSeg)
        result.append(otherSegments)
        result.append(renderedJpg.subdata(in: idx..<renderedJpg.count))
        return result
    }

    // MARK: - Helpers binarios

    private func readU16(_ data: Data, offset: Int, littleEndian: Bool) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    private func readU32(_ data: Data, offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if littleEndian {
            return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
        } else {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    private func writeU32(_ data: inout Data, offset: Int, value: UInt32, littleEndian: Bool) {
        guard offset + 4 <= data.count else { return }
        if littleEndian {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        } else {
            data[offset] = UInt8((value >> 24) & 0xFF)
            data[offset + 1] = UInt8((value >> 16) & 0xFF)
            data[offset + 2] = UInt8((value >> 8) & 0xFF)
            data[offset + 3] = UInt8(value & 0xFF)
        }
    }
}
