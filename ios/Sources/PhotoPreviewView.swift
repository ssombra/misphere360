import SwiftUI
import CoreLocation

/// Previsualización a pantalla completa en 360° interactiva antes de descargar la foto
public struct PhotoPreviewView: View {
    let item: SDFileItem
    var initialImage: UIImage? = nil
    var onDownloadRequested: ((StitchMode) -> Void)?
    var onDeleteRequested: (() -> Void)?
    @Environment(\.dismiss) var dismiss

    @State private var stitchedImage: UIImage?
    @State private var isLoading: Bool
    @State private var loadingMessage = "Cargando foto desde la cámara..."
    @State private var enableGyro = false
    @State private var projectionMode: PhotoProjectionMode = .normal
    @State private var panoScale: CGFloat = 1.0
    @GestureState private var panoMagnifyBy: CGFloat = 1.0
    @State private var showDeleteConfirm = false
    @State private var showInfoSheet = false
    @State private var downloadedFileSize: Int64? = nil
    @State private var errorMessage: String? = nil
    @State private var snapshotMessage: String? = nil
    @State private var showSnapshotAlert = false

    private let webController = Web360ViewerController()
    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0)

    public init(
        item: SDFileItem,
        initialImage: UIImage? = nil,
        onDownloadRequested: ((StitchMode) -> Void)? = nil,
        onDeleteRequested: (() -> Void)? = nil
    ) {
        self.item = item
        self.initialImage = initialImage
        self.onDownloadRequested = onDownloadRequested
        self.onDeleteRequested = onDeleteRequested
        _stitchedImage = State(initialValue: initialImage)
        _isLoading = State(initialValue: initialImage == nil)
    }

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

            // 1. Visor WebGL 360° interactivo o Pano 360
            if let img = stitchedImage {
                if projectionMode == .pano360 {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(max(1.0, min(4.0, panoScale * panoMagnifyBy)))
                        .gesture(
                            MagnificationGesture()
                                .updating($panoMagnifyBy) { value, state, _ in
                                    state = value
                                }
                                .onEnded { value in
                                    panoScale = max(1.0, min(4.0, panoScale * value))
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                panoScale = 1.0
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Web360Viewer(
                        image: img,
                        enableMotion: enableGyro,
                        projectionMode: projectionMode,
                        controller: webController
                    )
                    .ignoresSafeArea()
                }
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
                    if stitchedImage != nil && projectionMode != .pano360 {
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

                // 3. Botones Flotantes Inferiores (Estilo Apple translúcido e íconos blancos)
                if stitchedImage != nil {
                    HStack(spacing: 22) {
                        // 1. Borrar con confirmación
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
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
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }

                        // 3. Descarga / Guardar en Fotos
                        Menu {
                            if let currentImg = stitchedImage {
                                Section("Captura de esta vista") {
                                    Button {
                                        captureCurrentViewSnapshot(img: currentImg)
                                    } label: {
                                        Label("Guardar captura (\(projectionMode.rawValue))", systemImage: "camera.viewfinder")
                                    }
                                }
                            }

                            Section("Exportar a Apple Fotos") {
                                ForEach(StitchMode.allCases) { mode in
                                    Button {
                                        onDownloadRequested?(mode)
                                        dismiss()
                                    } label: {
                                        Label(mode.title, systemImage: mode.systemImage)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }

                        // 4. Modo de proyección 360°
                        Menu {
                            Section("Modo de visualización") {
                                ForEach(PhotoProjectionMode.allCases) { mode in
                                    Button {
                                        let impact = UIImpactFeedbackGenerator(style: .light)
                                        impact.impactOccurred()
                                        projectionMode = mode
                                        if mode == .pano360 {
                                            panoScale = 1.0
                                        }
                                    } label: {
                                        if projectionMode == mode {
                                            Label(mode.rawValue, systemImage: "checkmark")
                                        } else {
                                            Label(mode.rawValue, systemImage: mode.systemImage)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: projectionMode.systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(projectionMode == .normal ? .white : brandOrange)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(
                                        projectionMode == .normal ? Color.white.opacity(0.18) : brandOrange.opacity(0.6),
                                        lineWidth: projectionMode == .normal ? 0.5 : 1.0
                                    )
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .onAppear {
            if stitchedImage == nil {
                loadAndStitchPreview()
            }
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
        .alert("Captura de vista", isPresented: $showSnapshotAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(snapshotMessage ?? "")
        }
    }

    private func captureCurrentViewSnapshot(img: UIImage) {
        if projectionMode == .pano360 {
            MediaDownloader.shared.saveSnapshotImage(img, for: item, label: projectionMode.rawValue) { _, msg in
                snapshotMessage = msg
                showSnapshotAlert = true
            }
            return
        }

        webController.captureSnapshot { snapshot in
            guard let snapshot = snapshot else {
                snapshotMessage = "No se pudo capturar la vista actual."
                showSnapshotAlert = true
                return
            }
            MediaDownloader.shared.saveSnapshotImage(snapshot, for: item, label: projectionMode.rawValue) { _, msg in
                snapshotMessage = msg
                showSnapshotAlert = true
            }
        }
    }

    private func loadAndStitchPreview() {
        isLoading = true

        // 1. Si ya está en la biblioteca Local, abrir instantáneamente sin usar Wi-Fi
        if let localAsset = LocalLibraryManager.shared.asset(for: item) {
            self.downloadedFileSize = localAsset.fileSizeBytes
            if let stitchedURL = LocalLibraryManager.shared.stitchedURL(for: localAsset) {
                loadingMessage = "Abriendo desde Local..."
                DispatchQueue.global(qos: .userInitiated).async {
                    let cachedImg = UIImage(contentsOfFile: stitchedURL.path)
                    DispatchQueue.main.async {
                        if let img = cachedImg {
                            self.stitchedImage = img
                            self.isLoading = false
                        } else {
                            self.stitchFromLocalOriginal(localAsset)
                        }
                    }
                }
                return
            } else {
                stitchFromLocalOriginal(localAsset)
                return
            }
        }

        // 2. No está en Local: descargar de la cámara, coser y guardar automáticamente en Local
        loadingMessage = "Descargando para vista previa 360°..."

        MediaDownloader.shared.downloadToTemporaryFile(item: item) { localURL in
            guard let localURL = localURL else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = "No se pudo cargar la vista previa. Comprueba la conexión Wi-Fi con la cámara."
                }
                return
            }

            if let attr = try? FileManager.default.attributesOfItem(atPath: localURL.path),
               let size = attr[.size] as? Int64 {
                DispatchQueue.main.async {
                    self.downloadedFileSize = size
                }
            }

            DispatchQueue.main.async {
                self.loadingMessage = "Cosiendo esfera 360°..."
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let previewImg = PhotoStitcher.shared.stitchForInteractivePreview(from: localURL, maxPixelSize: 3840)

                if let img = previewImg {
                    // Persistir en Local (original + cosida) antes de borrar el archivo temporal
                    LocalLibraryManager.shared.saveMedia(item: item, originalTempURL: localURL, stitchedImage: img) { _ in
                        try? FileManager.default.removeItem(at: localURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: localURL)
                }

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
        }
    }

    private func stitchFromLocalOriginal(_ localAsset: LocalMediaAsset) {
        let origURL = LocalLibraryManager.shared.originalURL(for: localAsset)
        loadingMessage = "Cosiendo esfera 360°..."
        DispatchQueue.global(qos: .userInitiated).async {
            let previewImg = PhotoStitcher.shared.stitchForInteractivePreview(from: origURL, maxPixelSize: 3840)
            if let img = previewImg {
                LocalLibraryManager.shared.saveStitchedImage(img, forId: item.id)
            }
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
