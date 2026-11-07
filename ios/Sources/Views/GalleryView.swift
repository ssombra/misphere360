import SwiftUI

public enum GalleryFilterType: Equatable {
    case last7Days
    case last30Days
    case all
    case custom(start: Date, end: Date)

    public static func == (lhs: GalleryFilterType, rhs: GalleryFilterType) -> Bool {
        switch (lhs, rhs) {
        case (.last7Days, .last7Days): return true
        case (.last30Days, .last30Days): return true
        case (.all, .all): return true
        case (.custom(let s1, let e1), .custom(let s2, let e2)):
            return s1 == s2 && e1 == e2
        default: return false
        }
    }
}

struct GalleryView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var camera = CameraManager.shared
    @ObservedObject var downloader = MediaDownloader.shared

    @State private var allFiles: [SDFileItem] = []
    @State private var rawFolders: [String] = []
    @State private var isLoading = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    // Filtros de fecha y guardado
    @State private var activeFilter: GalleryFilterType = .last7Days
    @State private var showDatePickerSheet = false
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()
    @AppStorage("defaultStitchMode") private var selectedStitchMode: StitchMode = .stitched360

    // Vista previa 360 interactiva WebGL
    @State private var previewItem: SDFileItem? = nil

    // Modo Selección Múltiple
    @State private var isSelectionMode = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0)
    private let darkBg = Color(red: 0.05, green: 0.06, blue: 0.09)
    private let cardBg = Color(red: 0.10, green: 0.12, blue: 0.18)

    private var isCustomActive: Bool {
        if case .custom = activeFilter { return true }
        return false
    }

    var body: some View {
        NavigationView {
            ZStack {
                darkBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Barra de Almacenamiento microSD (Compacta)
                    compactStorageBar
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 6)

                    // 2. Barra de Filtros de Fecha (7 Días, 30 Días, Todo, Filtrar) + Modo
                    filterAndModeBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    // 3. Cuadrícula de Archivos
                    if isLoading && allFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 14) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: brandOrange))
                                .scaleEffect(1.4)
                            Text("Consultando fotos de la cámara...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else if allFiles.isEmpty {
                        Spacer()
                        emptyStateView
                        Spacer()
                    } else {
                        mainTimelineGrid
                    }

                    // 4. Barra Inferior de Acciones en Modo Selección
                    if isSelectionMode && !selectedItemIDs.isEmpty {
                        selectionActionBar
                    }
                }

                // Overlay de Descarga
                if downloader.isDownloading {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.4)
                        Text(downloader.statusMessage)
                            .foregroundColor(.white)
                            .font(.callout)
                            .fontWeight(.medium)
                    }
                    .padding(26)
                    .background(Color(red: 0.15, green: 0.18, blue: 0.26))
                    .cornerRadius(18)
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedItemIDs.count) seleccionados" : "Álbum Cámara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button("Cancelar") {
                            isSelectionMode = false
                            selectedItemIDs.removeAll()
                        }
                    } else {
                        Button(allFiles.isEmpty ? "" : "Seleccionar") {
                            isSelectionMode = true
                        }
                        .foregroundColor(brandOrange)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear {
                initialLoad()
            }
            .sheet(isPresented: $showDatePickerSheet) {
                datePickerSheetView
            }
            .fullScreenCover(item: $previewItem) { item in
                PhotoPreviewView(
                    item: item,
                    onDownloadRequested: { mode in
                        downloader.saveMediaToCameraRoll(item: item, mode: mode) { ok, msg in
                            alertMessage = msg
                            showAlert = true
                        }
                    },
                    onDeleteRequested: {
                        deleteSingleFile(item)
                    }
                )
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Aviso"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
            .alert("¿Eliminar \(selectedItemIDs.count) archivos de la microSD?", isPresented: $showBatchDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar Todo", role: .destructive) {
                    executeBatchDelete()
                }
            }
        }
    }

    // MARK: - Barra de Almacenamiento Compacta

    private var compactStorageBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "sdcard.fill")
                    .foregroundColor(brandOrange)
                    .font(.caption)
                Text("\(camera.sdFreeMB / 1024) GB libres de \(camera.sdTotalMB / 1024) GB")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()

            Text("\(camera.remainJPG) fotos · \(camera.remainVideo)s")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardBg)
        .cornerRadius(10)
    }

    // MARK: - Barra de Filtros de Fecha y Modo de Guardado

    private var filterAndModeBar: some View {
        HStack(spacing: 6) {
            // Píldoras de Fecha: 7 Días, 30 Días, Todo, Filtrar
            filterPill(title: "7 Días", isSelected: activeFilter == .last7Days) {
                activeFilter = .last7Days
                applyActiveFilter()
            }

            filterPill(title: "30 Días", isSelected: activeFilter == .last30Days) {
                activeFilter = .last30Days
                applyActiveFilter()
            }

            filterPill(title: "Todo", isSelected: activeFilter == .all) {
                activeFilter = .all
                applyActiveFilter()
            }

            filterPill(
                title: isCustomActive ? "Rango" : "Filtrar",
                icon: "calendar",
                isSelected: isCustomActive
            ) {
                showDatePickerSheet = true
            }

            Spacer()

            // Menú de Selección de Modo de Guardado
            Menu {
                ForEach(StitchMode.allCases) { mode in
                    Button {
                        selectedStitchMode = mode
                    } label: {
                        HStack {
                            Text(mode.title)
                            if selectedStitchMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text(selectedStitchMode == .stitched360 ? "360°" : (selectedStitchMode == .both ? "Ambas" : "Orig"))
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
    }

    private func filterPill(title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let ic = icon {
                    Image(systemName: ic)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? brandOrange : Color.white.opacity(0.09))
            .foregroundColor(isSelected ? .white : .white.opacity(0.85))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline Grid Estilo Insta360

    private var mainTimelineGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groupedSections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(section.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(section.items.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ], spacing: 10) {
                            ForEach(section.items) { item in
                                modernMediaCell(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Celda de Miniatura Moderna

    private func modernMediaCell(item: SDFileItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.id)

        return Button {
            if isSelectionMode {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                if isSelected {
                    selectedItemIDs.remove(item.id)
                } else {
                    selectedItemIDs.insert(item.id)
                }
            } else {
                previewItem = item
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                SDThumbnailView(item: item)
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                HStack(spacing: 4) {
                    if item.isVideo {
                        Image(systemName: "video.fill")
                        Text("VID")
                    } else {
                        Image(systemName: "globe")
                        Text("360°")
                    }
                }
                .font(.system(size: 9.5, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .foregroundColor(.white)
                .cornerRadius(5)
                .padding(6)

                VStack {
                    HStack {
                        Spacer()
                        if isSelectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(isSelected ? brandOrange : .white.opacity(0.8))
                                .padding(6)
                        } else {
                            Button {
                                downloader.saveMediaToCameraRoll(item: item, mode: selectedStitchMode) { ok, msg in
                                    alertMessage = msg
                                    showAlert = true
                                }
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.black.opacity(0.60))
                                    .clipShape(Circle())
                            }
                            .padding(6)
                        }
                    }
                    Spacer()
                }
            }
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? brandOrange : Color.white.opacity(0.08), lineWidth: isSelected ? 2.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Estado Vacío

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.6))

            let msg: String = {
                switch activeFilter {
                case .last7Days: return "No hay fotos en los últimos 7 días."
                case .last30Days: return "No hay fotos en los últimos 30 días."
                case .all: return "No se encontraron fotos en la microSD."
                case .custom: return "No hay fotos en el rango seleccionado."
                }
            }()

            Text(msg)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if activeFilter != .all {
                Button("Ver Todas las Fotos") {
                    activeFilter = .all
                    applyActiveFilter()
                }
                .buttonStyle(.borderedProminent)
                .tint(brandOrange)
            }
        }
    }

    // MARK: - Hoja de Selección de Fechas Personalizadas

    private var datePickerSheetView: some View {
        NavigationView {
            Form {
                Section(header: Text("Selecciona Rango de Búsqueda")) {
                    DatePicker("Desde", selection: $customStartDate, in: ...Date(), displayedComponents: .date)
                    DatePicker("Hasta", selection: $customEndDate, in: customStartDate...Date(), displayedComponents: .date)
                }

                Section {
                    Button {
                        activeFilter = .custom(start: customStartDate, end: customEndDate)
                        showDatePickerSheet = false
                        applyActiveFilter()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Aplicar Filtro")
                                .font(.body.weight(.bold))
                                .foregroundColor(brandOrange)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Filtrar por Fecha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { showDatePickerSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Barra de Acciones de Selección Múltiple

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Borrar (\(selectedItemIDs.count))")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.15))
                .cornerRadius(10)
            }

            Button {
                executeBatchDownload()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Descargar (\(selectedItemIDs.count))")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(brandOrange)
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(cardBg)
    }

    // MARK: - Agrupación por Días

    private struct GroupedSection {
        let title: String
        let items: [SDFileItem]
    }

    private var groupedSections: [GroupedSection] {
        var dict: [String: [SDFileItem]] = [:]
        var order: [String] = []

        for item in allFiles {
            let dayKey = formatHumanDay(from: item.filename)
            if dict[dayKey] == nil {
                dict[dayKey] = []
                order.append(dayKey)
            }
            dict[dayKey]?.append(item)
        }
        return order.map { GroupedSection(title: $0, items: dict[$0] ?? []) }
    }

    private func formatHumanDay(from filename: String) -> String {
        guard let d = parseDate(from: filename) else { return "Otras Fotos" }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return "Hoy · " + formatDate(d, format: "d 'de' MMMM")
        } else if cal.isDateInYesterday(d) {
            return "Ayer · " + formatDate(d, format: "d 'de' MMMM")
        } else {
            return formatDate(d, format: "d 'de' MMMM, yyyy")
        }
    }

    private func formatDate(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = format
        return f.string(from: date)
    }

    private func parseDate(from filename: String) -> Date? {
        let pattern = "(\\d{8})_(\\d{6})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let r1 = Range(match.range(at: 1), in: filename),
              let r2 = Range(match.range(at: 2), in: filename) else { return nil }
        let dateStr = "\(filename[r1])_\(filename[r2])"
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.date(from: dateStr)
    }

    private func parseFolderDate(_ folderName: String) -> Date? {
        let digits = folderName.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
        guard digits.count >= 8 else { return nil }
        let prefix = String(digits.prefix(8))
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f.date(from: prefix)
    }

    // MARK: - Lógica de Filtrado Inteligente de Carpetas

    private func getFilteredFolders() -> [String] {
        let cal = Calendar.current
        let today = Date()

        switch activeFilter {
        case .last7Days:
            let cutoff = cal.date(byAdding: .day, value: -7, to: today) ?? Date.distantPast
            let matches = rawFolders.filter { f in
                guard let d = parseFolderDate(f) else { return false }
                return d >= cutoff
            }
            // Si la cámara no tiene fotos en los últimos 7 días, mostrar al menos la carpeta más reciente
            return matches.isEmpty ? Array(rawFolders.prefix(1)) : matches

        case .last30Days:
            let cutoff = cal.date(byAdding: .day, value: -30, to: today) ?? Date.distantPast
            let matches = rawFolders.filter { f in
                guard let d = parseFolderDate(f) else { return false }
                return d >= cutoff
            }
            return matches.isEmpty ? Array(rawFolders.prefix(2)) : matches

        case .all:
            return rawFolders

        case .custom(let start, let end):
            let startDay = cal.startOfDay(for: start)
            let endDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
            return rawFolders.filter { f in
                guard let d = parseFolderDate(f) else { return false }
                return d >= startDay && d <= endDay
            }
        }
    }

    private func initialLoad() {
        isLoading = true
        camera.fetchStorageStatus()
        camera.listDCIMFolders { list in
            self.rawFolders = list.sorted(by: >)
            self.applyActiveFilter()
        }
    }

    private func applyActiveFilter() {
        let targets = getFilteredFolders()
        guard let first = targets.first else {
            self.allFiles = []
            self.isLoading = false
            return
        }

        self.isLoading = true
        self.allFiles = []

        // Cargar inmediatamente la primera carpeta para renderizar en <0.3s
        camera.listFilesInFolder(first) { recentItems in
            self.allFiles = recentItems
            self.isLoading = false

            // Cargar secuencialmente solo las demás carpetas incluidas en el filtro activo
            let remaining = Array(targets.dropFirst())
            self.loadRemainingFoldersSequentially(remaining: remaining)
        }
    }

    private func loadRemainingFoldersSequentially(remaining: [String]) {
        guard let nextFolder = remaining.first else { return }
        camera.listFilesInFolder(nextFolder) { olderItems in
            if !olderItems.isEmpty {
                var current = self.allFiles
                for item in olderItems where !current.contains(where: { $0.id == item.id }) {
                    current.append(item)
                }
                self.allFiles = current.sorted(by: { $0.filename > $1.filename })
            }
            self.loadRemainingFoldersSequentially(remaining: Array(remaining.dropFirst()))
        }
    }

    private func deleteSingleFile(_ item: SDFileItem) {
        camera.deleteSDFile(folder: item.folder, filename: item.filename) { ok in
            if ok {
                allFiles.removeAll(where: { $0.id == item.id })
                alertMessage = "Archivo eliminado de la tarjeta microSD."
            } else {
                alertMessage = "No se pudo borrar el archivo."
            }
            showAlert = true
        }
    }

    private func executeBatchDelete() {
        let targets = allFiles.filter { selectedItemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        func deleteNext(items: [SDFileItem]) {
            guard let first = items.first else {
                DispatchQueue.main.async {
                    self.isSelectionMode = false
                    self.selectedItemIDs.removeAll()
                    self.alertMessage = "Archivos eliminados exitosamente."
                    self.showAlert = true
                }
                return
            }

            camera.deleteSDFile(folder: first.folder, filename: first.filename) { ok in
                if ok {
                    self.allFiles.removeAll(where: { $0.id == first.id })
                }
                deleteNext(items: Array(items.dropFirst()))
            }
        }

        deleteNext(items: targets)
    }

    private func executeBatchDownload() {
        let targets = allFiles.filter { selectedItemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        func downloadNext(items: [SDFileItem], successCount: Int) {
            guard let first = items.first else {
                DispatchQueue.main.async {
                    self.isSelectionMode = false
                    self.selectedItemIDs.removeAll()
                    self.alertMessage = "Se descargaron \(successCount) archivos en Apple Fotos."
                    self.showAlert = true
                }
                return
            }

            downloader.saveMediaToCameraRoll(item: first, mode: selectedStitchMode) { ok, _ in
                downloadNext(items: Array(items.dropFirst()), successCount: ok ? successCount + 1 : successCount)
            }
        }

        downloadNext(items: targets, successCount: 0)
    }
}
