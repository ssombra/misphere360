import SwiftUI

struct GalleryView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var camera = CameraManager.shared
    @ObservedObject var downloader = MediaDownloader.shared

    @State private var folders: [String] = []
    @State private var selectedFolder: String = ""
    @State private var files: [SDFileItem] = []
    @State private var isLoading = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var itemToDelete: SDFileItem?
    @State private var showDeleteConfirm = false

    private let brandOrange = Color(red: 1.0, green: 0.404, blue: 0.0)
    private let darkBg = Color(red: 0.05, green: 0.06, blue: 0.09)
    private let cardBg = Color(red: 0.10, green: 0.12, blue: 0.18)

    var body: some View {
        NavigationView {
            ZStack {
                darkBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Barra de Almacenamiento microSD
                    storageStatusBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                    // 2. Selector Horizontal de Carpetas
                    if !folders.isEmpty {
                        folderPickerBar
                            .padding(.bottom, 8)
                    }

                    // 3. Contenido Principal (Lista de Fotos / Videos)
                    if isLoading {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: brandOrange))
                                .scaleEffect(1.4)
                            Text("Leyendo archivos de la microSD...")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    } else if files.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            Text("No hay archivos en esta carpeta.")
                                .foregroundColor(.secondary)
                            Button("Refrescar") {
                                refreshAll()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(brandOrange)
                        }
                        Spacer()
                    } else {
                        fileGrid
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
            .navigationTitle("microSD Cámara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear {
                refreshAll()
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Aviso"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
            .alert("¿Borrar archivo de la microSD?", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Borrar", role: .destructive) {
                    if let item = itemToDelete {
                        deleteFile(item)
                    }
                }
            } message: {
                Text(itemToDelete?.filename ?? "")
            }
        }
    }

    // MARK: - Barra de Almacenamiento

    private var storageStatusBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Almacenamiento SD")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(camera.sdFreeMB / 1024) GB libres de \(camera.sdTotalMB / 1024) GB")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Capacidad")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(camera.remainJPG) fotos • \(camera.remainVideo)s video")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(brandOrange)
            }
        }
        .padding(12)
        .background(cardBg)
        .cornerRadius(12)
    }

    // MARK: - Selector de Carpetas

    private var folderPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders, id: \.self) { folder in
                    Button {
                        selectedFolder = folder
                        loadFiles(in: folder)
                    } label: {
                        Text(folder)
                            .font(.caption)
                            .fontWeight(selectedFolder == folder ? .bold : .medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selectedFolder == folder ? brandOrange : cardBg)
                            .foregroundColor(selectedFolder == folder ? .white : .secondary)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Cuadrícula de Archivos

    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                ForEach(files) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        // Tarjeta Visual
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.14, green: 0.17, blue: 0.24))
                                .frame(height: 105)

                            VStack(spacing: 6) {
                                Image(systemName: item.isVideo ? "video.fill" : "camera.metering.matrix")
                                    .font(.system(size: 32))
                                    .foregroundColor(brandOrange)
                                Text(item.isVideo ? "VIDEO 360°" : "FOTO 360°")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // Botón Borrar
                            Button {
                                itemToDelete = item
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .padding(6)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            .padding(6)
                        }

                        // Info de Archivo
                        Text(item.filename)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(item.date)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        // Botón Guardar en Carrete
                        Button {
                            downloader.saveMediaToCameraRoll(item: item) { ok, msg in
                                alertMessage = msg
                                showAlert = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Guardar en Fotos")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(brandOrange)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    .padding(8)
                    .background(cardBg)
                    .cornerRadius(14)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Operaciones

    private func refreshAll() {
        isLoading = true
        camera.fetchStorageStatus()
        camera.listDCIMFolders { list in
            self.folders = list
            if let first = list.first {
                self.selectedFolder = first
                self.loadFiles(in: first)
            } else {
                self.isLoading = false
            }
        }
    }

    private func loadFiles(in folder: String) {
        isLoading = true
        camera.listFilesInFolder(folder) { items in
            self.files = items
            self.isLoading = false
        }
    }

    private func deleteFile(_ item: SDFileItem) {
        camera.deleteSDFile(folder: item.folder, filename: item.filename) { ok in
            if ok {
                files.removeAll(where: { $0.id == item.id })
                alertMessage = "Archivo eliminado de la tarjeta microSD."
            } else {
                alertMessage = "No se pudo borrar el archivo."
            }
            showAlert = true
        }
    }
}
