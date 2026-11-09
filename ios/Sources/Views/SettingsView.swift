import SwiftUI

struct SettingsView: View {
    @ObservedObject var camera = CameraManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var autoOffMinutes = 10
    @State private var buzzerLevel = 4
    @State private var ledEnabled = true
    @State private var showCacheAlert = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Gestión de Energía")) {
                    Picker("Apagado Automático", selection: $autoOffMinutes) {
                        Text("Desactivado").tag(0)
                        Text("5 minutos").tag(5)
                        Text("10 minutos").tag(10)
                    }
                    .onChange(of: autoOffMinutes) { val in
                        camera.sendCommand(msgId: 6151, param: val)
                    }

                    Button(role: .destructive) {
                        camera.powerOffCamera()
                        dismiss()
                    } label: {
                        Label("Apagar Cámara a Distancia", systemImage: "power")
                    }
                }

                Section(header: Text("Sonido y Luces")) {
                    Picker("Volumen del Buzzer", selection: $buzzerLevel) {
                        Text("Silencio").tag(0)
                        Text("Bajo").tag(1)
                        Text("Medio").tag(2)
                        Text("Alto").tag(4)
                    }
                    .onChange(of: buzzerLevel) { val in
                        camera.sendCommand(msgId: 6145, param: val)
                    }

                    Toggle("Luces LED de Estado", isOn: $ledEnabled)
                        .onChange(of: ledEnabled) { val in
                            camera.sendCommand(msgId: 6156, param: val ? 1 : 0)
                        }
                }

                Section(header: Text("Calibración")) {
                    Button {
                        camera.sendCommand(msgId: 6165, param: nil)
                    } label: {
                        Label("Calibrar Giroscopio de la Cámara", systemImage: "gyroscope")
                    }
                }

                Section(header: Text("Tarjeta MicroSD")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Capacidad")
                            Spacer()
                            Text(camera.formattedStorageSpace)
                                .foregroundColor(.secondary)
                        }

                        if camera.isConnected && camera.sdTotalMB > 0 {
                            let usedPercent = Double(camera.sdTotalMB - camera.sdFreeMB) / Double(camera.sdTotalMB)
                            ProgressView(value: max(0.0, min(1.0, usedPercent)))
                                .tint(usedPercent > 0.90 ? Color.red : (usedPercent > 0.75 ? Color.orange : Color.blue))
                        }
                    }
                    .padding(.vertical, 2)

                    HStack {
                        Text("Fotos restantes")
                        Spacer()
                        if camera.isConnected {
                            Text(camera.remainJPG > 0 ? "\(camera.remainJPG.formatted()) fotos" : "Calculando...")
                                .foregroundColor(.secondary)
                        } else {
                            Text("No disponible")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Video restante")
                        Spacer()
                        Text(camera.formattedRemainVideo)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Almacenamiento Local del iPhone")) {
                    Button(role: .destructive) {
                        ThumbnailCache.shared.clearAllCache()
                        showCacheAlert = true
                    } label: {
                        Label("Borrar Caché de Miniaturas", systemImage: "trash")
                    }
                }

                Section(header: Text("Acerca de")) {
                    if camera.isConnected && !camera.deviceName.isEmpty {
                        HStack {
                            Text("Nombre de Dispositivo")
                            Spacer()
                            Text(camera.deviceName)
                                .foregroundColor(.secondary)
                        }
                    }

                    if camera.isConnected && !camera.serialNumber.isEmpty {
                        HStack {
                            Text("Número de Serie")
                            Spacer()
                            Text(camera.serialNumber)
                                .foregroundColor(.secondary)
                        }
                    }

                    if camera.isConnected && !camera.firmwareVersion.isEmpty {
                        HStack {
                            Text("Firmware de Cámara")
                            Spacer()
                            Text(camera.firmwareVersion)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Modelo")
                        Spacer()
                        Text("Xiaomi Mi Sphere 360")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("IP de Control")
                        Spacer()
                        Text("192.168.42.1:7878")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Versión App")
                        Spacer()
                        Text("1.0.0 iOS")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                if camera.isConnected {
                    camera.fetchStorageStatus()
                    camera.sendCommand(msgId: 4364, param: nil)
                }
            }
            .alert("Caché Borrado", isPresented: $showCacheAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Se eliminaron las miniaturas guardadas. La galería generará versiones cosidas 360° actualizadas.")
            }
            .navigationTitle("Ajustes de Cámara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
