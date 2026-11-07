import SwiftUI
import CoreLocation

/// Previsualización a pantalla completa en 360° interactiva antes de descargar la foto
public struct PhotoPreviewView: View {
    let item: SDFileItem
    var onDownloadRequested: ((StitchMode) -> Void)?
    var onDeleteRequested: (() -> Void)?
    @Environment(\.dismiss) var dismiss

    @State private var stitchedImage: UIImage? = nil
    @State private var isLoading = true
    @State private var loadingMessage = "Cargando foto desde la cámara..."
    @State private var enableGyro = false
    @State private var showDeleteConfirm = false
    @State private var showInfoSheet = false
    @State private var downloadedFileSize: Int64? = nil
    @State private var errorMessage: String? = nil

    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0)

    private var formattedFileSize: String {
        if let size = downloadedFileSize, size > 0 {
            let bcf = ByteCountFormatter()
            bcf.allowedUnits = [.useMB, .useKB]
            bcf.countStyle = .file
            return bcf.string(fromByteCount: size)
        }
        return "~6.8 MB"
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 1. Visor WebGL 360° interactivo
            if let img = stitchedImage {
                Web360Viewer(image: img, enableMotion: enableGyro)
                    .ignoresSafeArea()
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundColor(brandOrange)
                    Text(err)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(brandOrange)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: brandOrange))
                        .scaleEffect(1.5)
                    Text(loadingMessage)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // 2. Controles Superiores Flotantes (Minimalistas, solo íconos)
            VStack {
                HStack {
                    // Botón Cerrar (Izquierda)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
                    }

                    Spacer()

                    // Botón Giroscopio / Táctil (Derecha, solo ícono redondo)
                    if stitchedImage != nil {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            enableGyro.toggle()
                        } label: {
                            Image(systemName: enableGyro ? "gyroscope" : "hand.draw")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 42, height: 42)
                                .background(enableGyro ? brandOrange : Color.black.opacity(0.45))
                                .background(enableGyro ? AnyShapeStyle(brandOrange) : AnyShapeStyle(.ultraThinMaterial))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .shadow(color: enableGyro ? brandOrange.opacity(0.4) : Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()

                // 3. Botones Flotantes Inferiores (Estilo iOS redondo, ultra-limpio y no invasivo)
                if stitchedImage != nil {
                    HStack(spacing: 28) {
                        // 1. Borrar con confirmación
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.red.opacity(0.95))
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }

                        // 2. Información de la foto ("i")
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            showInfoSheet = true
                        } label: {
                            Image(systemName: "info")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }

                        // 3. Descarga / Guardar en Fotos
                        Menu {
                            Button {
                                onDownloadRequested?(.stitched360)
                                dismiss()
                            } label: {
                                Label("Solo 360° (Recomendado)", systemImage: "globe")
                            }
                            Button {
                                onDownloadRequested?(.both)
                                dismiss()
                            } label: {
                                Label("Ambas (Original + 360°)", systemImage: "square.stack.3d.down.right")
                            }
                            Button {
                                onDownloadRequested?(.original)
                                dismiss()
                            } label: {
                                Label("Solo Original (microSD)", systemImage: "doc")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(brandOrange)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                                )
                                .shadow(color: brandOrange.opacity(0.4), radius: 8, x: 0, y: 4)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear {
            loadAndStitchPreview()
        }
        .alert("¿Eliminar archivo de la microSD?", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                onDeleteRequested?()
                dismiss()
            }
        } message: {
            Text("Esta acción borrará permanentemente \(item.filename) de la tarjeta de memoria.")
        }
        .sheet(isPresented: $showInfoSheet) {
            PhotoInfoSheetView(item: item, fileSizeFormatted: formattedFileSize)
        }
    }

    private func loadAndStitchPreview() {
        isLoading = true
        loadingMessage = "Descargando para vista previa 360°..."

        // Descargar la foto a un archivo temporal (priorizando /DCIM que es donde sirve Cherokee)
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nameVariants = ["\(item.filename.dropLast(4))AA.JPG", item.filename, "\(item.filename.dropLast(4))aa.jpg"]
        let prefixes = ["/DCIM", "", "/SD0/DCIM", "/tmp/SD0/DCIM"]

        var candidateURLs: [URL] = []
        for p in prefixes {
            for v in nameVariants {
                if let u = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(p)/\(cleanFolder)/\(v)") {
                    if !candidateURLs.contains(u) {
                        candidateURLs.append(u)
                    }
                }
            }
        }

        downloadCandidate(urls: candidateURLs)
    }

    private func downloadCandidate(urls: [URL]) {
        guard let url = urls.first else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "No se pudo cargar la vista previa. Comprueba la conexión Wi-Fi con la cámara."
            }
            return
        }

        let remaining = Array(urls.dropFirst())

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5

        URLSession.shared.downloadTask(with: req) { localURL, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let localURL = localURL {
                if let attr = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                   let size = attr[.size] as? Int64 {
                    DispatchQueue.main.async {
                        self.downloadedFileSize = size
                    }
                }

                DispatchQueue.main.async {
                    self.loadingMessage = "Cosiendo esfera 360°..."
                }

                // Copiar a temporal seguro
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("preview_\(UUID().uuidString).JPG")
                try? FileManager.default.removeItem(at: tempURL)
                do {
                    try FileManager.default.copyItem(at: localURL, to: tempURL)
                } catch {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = "Error preparando archivo: \(error.localizedDescription)"
                    }
                    return
                }

                // Coser en segundo plano en <0.3s optimizado para pantalla
                DispatchQueue.global(qos: .userInitiated).async {
                    let previewImg = PhotoStitcher.shared.stitchForInteractivePreview(from: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)

                    DispatchQueue.main.async {
                        if let img = previewImg {
                            self.stitchedImage = img
                            self.isLoading = false
                        } else {
                            self.isLoading = false
                            self.errorMessage = "No se pudo generar la vista 360°."
                        }
                    }
                }
            } else {
                self.downloadCandidate(urls: remaining)
            }
        }.resume()
    }
}

/// Hoja modal de detalles de la foto (metadatos, dimensiones, GPS)
struct PhotoInfoSheetView: View {
    let item: SDFileItem
    let fileSizeFormatted: String
    @Environment(\.dismiss) var dismiss

    var bestLocation: CLLocation? {
        LocationManager.shared.getBestLocation(for: item.filename)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Archivo y Almacenamiento") {
                    infoRow(icon: "doc", label: "Nombre", value: item.filename)
                    infoRow(icon: "folder", label: "Carpeta", value: "DCIM/\(item.folder)")
                    infoRow(icon: "calendar", label: "Fecha", value: item.date)
                    infoRow(icon: "internaldrive", label: "Tamaño en tarjeta", value: fileSizeFormatted)
                }

                Section("Imagen y Resolución") {
                    infoRow(icon: "globe", label: "Formato", value: "Panorama Equirrectangular 360°")
                    infoRow(icon: "aspectratio", label: "Proporción", value: "2:1 (360° × 180°)")
                    infoRow(icon: "camera", label: "Resolución", value: "6912 × 3456 px (24 MP)")
                    infoRow(icon: "tag", label: "Metadatos", value: "Google Photo Sphere (GPano)")
                }

                Section("Geolocalización GPS") {
                    if let loc = bestLocation {
                        infoRow(icon: "checkmark.circle.fill", label: "Estado", value: "GPS Vinculado con iPhone", valueColor: .green)
                        infoRow(icon: "location.north.line", label: "Coordenadas", value: String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude))
                        infoRow(icon: "mountain.2", label: "Altitud", value: String(format: "%.1f m", loc.altitude))
                        infoRow(icon: "scope", label: "Precisión", value: String(format: "±%.1f m", loc.horizontalAccuracy))
                    } else {
                        infoRow(icon: "location.slash", label: "Estado", value: "Sin datos GPS vinculados", valueColor: .secondary)
                        Text("Para registrar la ubicación en cada foto, asegúrate de mantener la app abierta durante las tomas.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Detalles de la Foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func infoRow(icon: String, label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}
