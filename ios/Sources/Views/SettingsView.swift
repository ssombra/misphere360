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

                Section(header: Text("Almacenamiento Local del iPhone")) {
                    Button(role: .destructive) {
                        ThumbnailCache.shared.clearAllCache()
                        showCacheAlert = true
                    } label: {
                        Label("Borrar Caché de Miniaturas", systemImage: "trash")
                    }
                }

                Section(header: Text("Acerca de")) {
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
