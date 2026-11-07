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
    @State private var selectedSaveMode: StitchMode = .stitched360
    @State private var errorMessage: String? = nil

    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0)

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 1. Visor WebGL 360° idéntico a la app de Mac
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

            // 2. Barra Superior Flotante
            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(item.date)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    // Botón de alternar Giroscopio
                    if stitchedImage != nil {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            enableGyro.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: enableGyro ? "gyroscope" : "hand.draw")
                                Text(enableGyro ? "Giroscopio" : "Táctil")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(enableGyro ? brandOrange : Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()

                // 3. Barra Inferior Flotante (Acciones y Metadatos)
                if stitchedImage != nil {
                    VStack(spacing: 10) {
                        // Fila de metadatos sutiles
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                Text("Panorama 360° · 6912×3456")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))

                            Spacer()

                            if LocationManager.shared.getBestLocation(for: item.filename) != nil {
                                HStack(spacing: 3) {
                                    Image(systemName: "location.fill")
                                    Text("GPS Vinculado")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.45))
                            }
                        }

                        // Botones de Acción
                        HStack(spacing: 10) {
                            // Botón Borrar
                            Button {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 16))
                                    .foregroundColor(.red.opacity(0.9))
                                    .frame(width: 44, height: 44)
                                    .background(Color.white.opacity(0.12))
                                    .cornerRadius(12)
                            }

                            // Botón Guardar en Carrete con Menú de opciones
                            Menu {
                                Button {
                                    onDownloadRequested?(.stitched360)
                                    dismiss()
                                } label: {
                                    Label("🌐 Solo 360° (Recomendado)", systemImage: "globe")
                                }
                                Button {
                                    onDownloadRequested?(.both)
                                    dismiss()
                                } label: {
                                    Label("📦 Ambas (Original + 360°)", systemImage: "square.stack.3d.down.right")
                                }
                                Button {
                                    onDownloadRequested?(.original)
                                    dismiss()
                                } label: {
                                    Label("🔘 Solo Original (microSD)", systemImage: "doc")
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("Guardar en Fotos")
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(brandOrange)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(18)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
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
    }

    private func loadAndStitchPreview() {
        isLoading = true
        loadingMessage = "Descargando para vista previa 360°..."

        // Descargar la foto a un archivo temporal
        let cleanFolder = item.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let nameVariants = ["\(item.filename.dropLast(4))AA.JPG", item.filename]
        let prefixes = ["", "/DCIM", "/SD0/DCIM", "/tmp/SD0/DCIM"]

        var candidateURLs: [URL] = []
        for p in prefixes {
            for v in nameVariants {
                if let u = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)\(p)/\(cleanFolder)/\(v)") {
                    candidateURLs.append(u)
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
        req.timeoutInterval = 15.0

        URLSession.shared.downloadTask(with: req) { localURL, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let localURL = localURL {
                DispatchQueue.main.async {
                    self.loadingMessage = "Cosiendo esfera 360° interactiva..."
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

                // Coser en segundo plano
                DispatchQueue.global(qos: .userInitiated).async {
                    let loc = LocationManager.shared.getBestLocation(for: self.item.filename)
                    let processed = PhotoStitcher.shared.processDownloadedFile(
                        at: tempURL,
                        isVideo: self.item.isVideo,
                        mode: .stitched360,
                        location: loc
                    )

                    let finalURL = processed.first ?? tempURL
                    if let data = try? Data(contentsOf: finalURL), let uiImg = UIImage(data: data) {
                        try? FileManager.default.removeItem(at: tempURL)
                        if finalURL != tempURL {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        DispatchQueue.main.async {
                            self.stitchedImage = uiImg
                            self.isLoading = false
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.isLoading = false
                            self.errorMessage = "No se pudo decodificar la imagen 360°."
                        }
                    }
                }
            } else {
                self.downloadCandidate(urls: remaining)
            }
        }.resume()
    }
}
