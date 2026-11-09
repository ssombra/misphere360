import SwiftUI

struct SettingsView: View {
    @ObservedObject var camera = CameraManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var autoOffMinutes = 10
    @State private var buzzerLevel = 4
    @State private var ledEnabled = true
    @State private var showCacheAlert = false
    @State private var showWiFiPassword = false
    @State private var showEditWiFiSheet = false

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

                Section(header: Text("Video"), footer: Text("Al llenarse la microSD, sobreescribe automáticamente los clips más antiguos para continuar grabando (función Dashcam).")) {
                    Picker("Ciclo de Grabación", selection: Binding(
                        get: { camera.videoLoop },
                        set: { val in camera.setVideoLoop(val) }
                    )) {
                        Text("Desactivado").tag(0)
                        Text("1 minuto").tag(1)
                        Text("2 minutos").tag(2)
                        Text("5 minutos").tag(5)
                    }
                }

                Section(header: Text("Visualización 360°"), footer: Text("Define la proyección predeterminada para explorar fotos y el visor en vivo.")) {
                    Picker("Modo de Previsualización", selection: Binding(
                        get: { camera.previewMode },
                        set: { camera.previewMode = $0 }
                    )) {
                        Text("Mirror ball (Esfera)").tag("Mirror ball")
                        Text("Panorámica").tag("Panorámica")
                        Text("Little Planet").tag("Little Planet")
                        Text("Ojo de Pez (Plana)").tag("Flat")
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

                Section(header: Text("Conectividad Wi-Fi de la Cámara")) {
                    HStack {
                        Text("Red Wi-Fi (SSID)")
                        Spacer()
                        Text(camera.wifiSSID.isEmpty ? (camera.isConnected ? "MJXJ-010135" : "No disponible") : camera.wifiSSID)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Contraseña Wi-Fi")
                        Spacer()
                        Text(camera.wifiPassword.isEmpty ? (camera.isConnected ? "••••••••" : "No disponible") : (showWiFiPassword ? camera.wifiPassword : "••••••••"))
                            .foregroundColor(.secondary)

                        if !camera.wifiPassword.isEmpty {
                            Button {
                                showWiFiPassword.toggle()
                            } label: {
                                Image(systemName: showWiFiPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIPasteboard.general.string = camera.wifiPassword
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 14))
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        showEditWiFiSheet = true
                    } label: {
                        Label("Cambiar Nombre y Contraseña Wi-Fi", systemImage: "wifi")
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
                    camera.fetchWiFiSettings()
                    camera.sendCommand(msgId: 4364, param: nil)
                }
            }
            .sheet(isPresented: $showEditWiFiSheet) {
                WiFiEditSheetView()
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

/// Hoja modal para editar SSID y Contraseña del Wi-Fi de la cámara
struct WiFiEditSheetView: View {
    @ObservedObject var camera = CameraManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var newSSID: String = ""
    @State private var newPass: String = ""
    @State private var isSaving: Bool = false
    @State private var alertMsg: String = ""
    @State private var showAlert: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Punto de Acceso de la Cámara")) {
                    TextField("Nombre de Red (SSID)", text: $newSSID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Contraseña (mínimo 8 caracteres)", text: $newPass)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section(footer: Text("Si cambias la contraseña o el nombre de red, la cámara reiniciará su antena Wi-Fi y deberás reconectar tu iPhone a la nueva red en los Ajustes de iOS.")) {
                    Button {
                        guard newPass.count >= 8 else {
                            alertMsg = "La contraseña debe tener al menos 8 caracteres."
                            showAlert = true
                            return
                        }
                        isSaving = true
                        camera.setWiFiSettings(ssid: newSSID, password: newPass) { success in
                            isSaving = false
                            if success {
                                alertMsg = "Ajustes de Wi-Fi aplicados. La cámara se reiniciará con las nuevas credenciales."
                                showAlert = true
                            } else {
                                alertMsg = "No se pudo actualizar el Wi-Fi. Comprueba la conexión."
                                showAlert = true
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Guardar y Aplicar")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(newSSID.isEmpty || newPass.count < 8 || isSaving)
                }
            }
            .navigationTitle("Ajustes de Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onAppear {
                newSSID = camera.wifiSSID
                newPass = camera.wifiPassword
            }
            .alert("Wi-Fi de la Cámara", isPresented: $showAlert) {
                Button("Entendido") { dismiss() }
            } message: {
                Text(alertMsg)
            }
        }
    }
}
