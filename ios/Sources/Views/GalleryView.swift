import SwiftUI

struct GalleryView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var downloader = MediaDownloader.shared

    @State private var items: [MediaDownloader.MediaItem] = []
    @State private var isLoading = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 1.0, green: 0.4, blue: 0.0)))
                            .scaleEffect(1.4)
                        Text("Leyendo tarjeta microSD...")
                            .foregroundColor(.secondary)
                    }
                } else if items.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No se encontraron fotos o videos.")
                            .foregroundColor(.secondary)
                        Button("Reintentar Lectura") {
                            loadDCIMListing()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 1.0, green: 0.4, blue: 0.0))
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(red: 0.12, green: 0.15, blue: 0.22))
                                            .frame(height: 110)

                                        VStack(spacing: 6) {
                                            Image(systemName: item.isVideo ? "video.fill" : "camera.metering.matrix")
                                                .font(.system(size: 28))
                                                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.0))
                                            Text(item.isVideo ? "Video 360°" : "Foto 360°")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Text(item.filename)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    Button {
                                        downloader.saveMediaToCameraRoll(item: item) { ok, msg in
                                            alertMessage = msg
                                            showAlert = true
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "square.and.arrow.down")
                                            Text("Guardar")
                                        }
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(Color(red: 1.0, green: 0.4, blue: 0.0))
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                    }
                                }
                                .padding(8)
                                .background(Color(red: 0.08, green: 0.10, blue: 0.15))
                                .cornerRadius(14)
                            }
                        }
                        .padding()
                    }
                }

                if downloader.isDownloading {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.3)
                        Text(downloader.statusMessage)
                            .foregroundColor(.white)
                            .font(.callout)
                    }
                    .padding(24)
                    .background(Color(red: 0.15, green: 0.18, blue: 0.26))
                    .cornerRadius(16)
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
                loadDCIMListing()
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text("Descarga"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func loadDCIMListing() {
        isLoading = true
        // Consultar servidor HTTP de la cámara para listar carpetas de DCIM
        guard let url = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/") else {
            isLoading = false
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async { self.isLoading = false }
            guard let data = data, let html = String(data: data, encoding: .utf8) else { return }

            // Parsear enlaces simples de carpetas como 100MEDIA o 20140105
            let regex = try? NSRegularExpression(pattern: "href=[\"']([0-9A-Za-z_]+)/?[\"']", options: [])
            let matches = regex?.matches(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) ?? []
            let folders = matches.compactMap { match -> String? in
                if let r = Range(match.range(at: 1), in: html) {
                    let name = String(html[r])
                    return name != "DCIM" && name != ".." ? name : nil
                }
                return nil
            }

            for f in folders {
                self.fetchFilesInFolder(f)
            }
        }
        task.resume()
    }

    private func fetchFilesInFolder(_ folder: String) {
        guard let url = URL(string: "http://\(CameraManager.cameraIP):\(CameraManager.httpPort)/DCIM/\(folder)/") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) else { return }
            let regex = try? NSRegularExpression(pattern: "href=[\"']([0-9A-Za-z_\\.]+\\.(JPG|MP4))[\"']", options: [.caseInsensitive])
            let matches = regex?.matches(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)) ?? []
            let files = matches.compactMap { match -> String? in
                if let r = Range(match.range(at: 1), in: html) {
                    return String(html[r])
                }
                return nil
            }

            DispatchQueue.main.async {
                for file in files {
                    let isVid = file.uppercased().hasSuffix(".MP4")
                    let item = MediaDownloader.MediaItem(folder: folder, filename: file, isVideo: isVid)
                    if !self.items.contains(where: { $0.filename == item.filename }) {
                        self.items.append(item)
                    }
                }
            }
        }.resume()
    }
}
