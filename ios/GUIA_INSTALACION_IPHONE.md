# Guía de Instalación: Mi Sphere 360 en tu iPhone (Camino 1)

Esta solución compila la app nativa en los servidores Mac de **GitHub Actions en la nube**, entregándote directamente el archivo instalador (`MiSphere360.ipa`) **sin consumir espacio de disco en tu Mac ni requerir la instalación pesada de Xcode**.

---

## 📱 ¿Qué incluye esta App de iPhone?
1. **Control Total por Socket TCP (`192.168.42.1:7878`):**
   * Disparo de Foto 360° con retroalimentación háptica (vibración).
   * Grabación de Video 360° (3.5K).
   * Control manual de exposición: EV (-2 a +2), ISO (Auto a 1600), Balance de Blancos y Temporizador.
2. **Geolocalización en Tiempo Real (Camino A):**
   * Utiliza el chip GPS satelital del iPhone (`CoreLocation`) mientras estás conectado al Wi-Fi de la cámara (`MJXJ-010135`).
   * Inyecta las coordenadas satelitales (`msg_id: 4917`) de forma automática al moverte o justo antes de disparar, para que la foto se guarde con metadatos EXIF de GPS en la microSD.
3. **Descarga Directa al Carrete de iOS:**
   * Explora los archivos de la microSD de la cámara y guárdalos directamente en tu álbum de Apple Fotos.
4. **Ajustes de Hardware:**
   * Volumen del buzzer, luces LED, calibración de giroscopio y apagado remoto de la cámara.

---

## 🚀 Pasos para Compilar y Descargar el Instalador (.ipa)

### Paso 1: Crear un repositorio en GitHub
1. Abre [github.com](https://github.com) en tu navegador e inicia sesión.
2. Haz clic en **New repository** (+ en la esquina superior derecha).
3. Nómbralo por ejemplo: `misphere-360`.
4. Elige **Private** (Privado) o Público, según prefieras, y haz clic en **Create repository**.

### Paso 2: Subir el código a tu repositorio
Abre una terminal en tu Mac (o puedes pedirme que lo ejecute) y corre estos 3 comandos:

```bash
cd /Users/ssombra/Documents/Apps/MiSphere
git init
git add .
git commit -m "Mi Sphere 360 para Mac e iOS"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/misphere-360.git
git push -u origin main
```
*(Reemplaza `TU_USUARIO` por tu usuario de GitHub).*

---

### Paso 3: Descargar el archivo `.ipa`
1. En tu repositorio en GitHub, ve a la pestaña superior **Actions**.
2. Verás el flujo **"Compilar Mi Sphere 360 para iOS"** ejecutándose automáticamente en un servidor Mac en la nube.
3. En aproximadamente 2 minutos aparecerá con un check verde (✅).
4. Haz clic en esa ejecución y en la sección inferior **Artifacts**, haz clic en **`MiSphere360-iOS-IPA`** para descargarlo a tu Mac (pesa apenas unos megabytes).

---

### Paso 4: Instalarlo en tu iPhone con Sideloadly (Ocupa solo ~80 MB en Mac)
1. Descarga e instala la herramienta gratuita **Sideloadly** desde [sideloadly.io](https://sideloadly.io) en tu Mac (pesa menos de 80 MB, no requiere Xcode).
2. Conecta tu iPhone a tu Mac con el cable USB.
3. Abre Sideloadly:
   * Arrastra el archivo `MiSphere360.ipa` a la ventana de Sideloadly.
   * Introduce tu Apple ID normal (el mismo de tu iPhone).
   * Haz clic en **Start**.
4. ¡Listo! En 30 segundos verás el icono de **Mi Sphere 360** en la pantalla de inicio de tu iPhone.

> **Primera apertura en el iPhone:** Si iOS muestra *"Desarrollador no confiable"*, ve en tu iPhone a **Ajustes > General > VPN y gestión de dispositivos**, selecciona tu Apple ID y pulsa **Confiar**.
