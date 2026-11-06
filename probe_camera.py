#!/usr/bin/env python3
"""
Script de diagnóstico y descubrimiento automático para Xiaomi Mi Sphere 360 (Mijia 360).
Espera hasta detectar la cámara en 192.168.42.1:7878, consulta todos sus parámetros,
guarda el reporte en camera_report.json y cierra la sesión limpiamente.
"""

import json
import socket
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

CAMERA_IP = "192.168.42.1"
CONTROL_PORT = 7878
HTTP_PORT = 50422
REPORT_PATH = Path(__file__).parent / "camera_report.json"

# Comandos conocidos del protocolo Xiaomi Mi Sphere 360 (Ambarella A12)
MSG_CONNECT = 257
MSG_DISCONNECT = 258
MSG_GET_SERIAL_NO = 4097
MSG_GET_WIFI = 1539
MSG_GET_STORAGE = 4358
MSG_GET_DEVICE = 4364
MSG_GET_CAMERA = 4365
MSG_CHANGE_DIR = 1283
MSG_LIST_DIR = 1282
MSG_PHOTO_PRESS = 4864


def play_sound(sound_name="Glass"):
    """Reproduce un sonido del sistema en macOS para avisar sin mirar la pantalla."""
    try:
        import subprocess
        sound_file = f"/System/Library/Sounds/{sound_name}.aiff"
        subprocess.Popen(["afplay", sound_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def get_local_ip_for_camera():
    """Obtiene la IP asignada a la Mac dentro de la red 192.168.42.x."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.0)
        s.connect((CAMERA_IP, CONTROL_PORT))
        local_ip = s.getsockname()[0]
        s.close()
        return local_ip
    except Exception:
        return None


def wait_for_camera(timeout_sec=300):
    """Espera hasta que el puerto 7878 de la cámara esté accesible."""
    print("=" * 68)
    print("📡 BUSCANDO CÁMARA XIAOMI MI SPHERE 360 EN 192.168.42.1:7878 ...")
    print("=" * 68)
    print("👉 Pasos:")
    print("   1. Enciende tu cámara Mi Sphere 360 y activa su Wi-Fi (botón Wi-Fi).")
    print("   2. Conecta el Wi-Fi de tu Mac a la red de la cámara (clave usual: 12345678).")
    print("   3. En cuanto conecte, este script hará todo solo en ~5 segundos")
    print("      y sonará una campana cuando puedas volver a tu Wi-Fi normal.\n")

    start = time.time()
    attempt = 0
    while time.time() - start < timeout_sec:
        attempt += 1
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(1.5)
            sock.connect((CAMERA_IP, CONTROL_PORT))
            print(f"\n✅ ¡Cámara detectada en {CAMERA_IP}:{CONTROL_PORT}!")
            play_sound("Morse")
            return sock
        except OSError:
            elapsed = int(time.time() - start)
            sys.stdout.write(f"\r⏳ Esperando conexión Wi-Fi con la cámara... ({elapsed}s transcurridos)")
            sys.stdout.flush()
            time.sleep(1.5)

    raise TimeoutError("No se detectó la cámara después de esperar 5 minutos.")


def recv_json_messages(sock, timeout=1.5):
    """Lee y decodifica uno o varios objetos JSON enviados por la cámara en el socket TCP."""
    sock.settimeout(timeout)
    buffer = ""
    messages = []
    deadline = time.time() + timeout

    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buffer += chunk.decode("utf-8", errors="replace")
            while buffer.strip():
                buffer = buffer.lstrip()
                try:
                    obj, idx = json.JSONDecoder().raw_decode(buffer)
                    messages.append(obj)
                    buffer = buffer[idx:]
                except json.JSONDecodeError:
                    # Esperar más bytes si el JSON está incompleto
                    break
            if messages:
                # Pequeña ventana adicional por si vienen mensajes asíncronos pegados
                sock.settimeout(0.25)
        except socket.timeout:
            break
        except Exception as e:
            messages.append({"_recv_error": str(e), "_raw_buffer": buffer})
            break

    return messages


def send_cmd(sock, msg_id, token, extra=None, wait_timeout=1.5):
    """Envía un comando JSON y devuelve la lista de respuestas JSON recibidas."""
    payload = {"msg_id": msg_id, "token": token}
    if extra:
        payload.update(extra)
    raw = json.dumps(payload).encode("utf-8")
    print(f"➡️  Enviando msg_id={msg_id}: {payload}")
    sock.sendall(raw)
    time.sleep(0.35)
    resps = recv_json_messages(sock, timeout=wait_timeout)
    for r in resps:
        print(f"⬅️  Respuesta: {r}")
    return resps


def probe_http_server():
    """Verifica si el servidor HTTP de archivos (puerto 50422) responde."""
    url = f"http://{CAMERA_IP}:{HTTP_PORT}/"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=2.0) as resp:
            body = resp.read(2048).decode("utf-8", errors="replace")
            return {
                "reachable": True,
                "status": resp.status,
                "headers": dict(resp.headers),
                "sample_body": body[:500],
            }
    except Exception as e:
        return {"reachable": False, "error": str(e)}


def main():
    take_test_photo = "--photo" in sys.argv
    report = {
        "timestamp": datetime.now().isoformat(),
        "camera_ip": CAMERA_IP,
        "control_port": CONTROL_PORT,
        "http_port": HTTP_PORT,
        "local_ip": None,
        "token": None,
        "responses": {},
        "async_messages": [],
        "http_probe": None,
        "errors": [],
    }

    sock = None
    try:
        sock = wait_for_camera()
        report["local_ip"] = get_local_ip_for_camera()
        print(f"💻 IP local de tu Mac en la red de la cámara: {report['local_ip']}")

        # 1. Iniciar sesión (msg_id = 257, token = 0)
        connect_resps = send_cmd(sock, MSG_CONNECT, token=0, wait_timeout=2.0)
        report["responses"]["CONNECT_257"] = connect_resps

        token = None
        for r in connect_resps:
            if r.get("msg_id") == MSG_CONNECT and "param" in r:
                token = r["param"]
                break

        if token is None:
            raise RuntimeError(
                f"La cámara no devolvió un token válido al conectar. Respuesta: {connect_resps}"
            )

        report["token"] = token
        print(f"🔑 Token de sesión obtenido: {token}\n")

        # 2. Consultar información general, batería, modos, almacenamiento, Wi-Fi y serie
        queries = [
            ("GET_DEVICE_4364", MSG_GET_DEVICE, None),
            ("GET_CAMERA_4365", MSG_GET_CAMERA, None),
            ("GET_STORAGE_4358", MSG_GET_STORAGE, None),
            ("GET_WIFI_1539", MSG_GET_WIFI, None),
            ("GET_SERIAL_4097", MSG_GET_SERIAL_NO, None),
            ("CHANGE_DIR_DCIM_1283", MSG_CHANGE_DIR, {"param": "/tmp/SD0/DCIM/"}),
            ("LIST_DIR_1282", MSG_LIST_DIR, None),
        ]

        for label, msg_id, extra in queries:
            try:
                resps = send_cmd(sock, msg_id, token=token, extra=extra, wait_timeout=1.5)
                report["responses"][label] = resps
            except Exception as e:
                report["errors"].append({label: str(e)})

        # 3. Opcional: Disparar foto de prueba si se pidió con --photo
        if take_test_photo:
            print("\n📸 Disparando foto de prueba (msg_id=4864)...")
            resps = send_cmd(sock, MSG_PHOTO_PRESS, token=token, wait_timeout=3.0)
            report["responses"]["PHOTO_PRESS_4864"] = resps

        # 4. Probar servidor HTTP de archivos (puerto 50422)
        print("\n🌐 Probando servidor HTTP de fotos/videos en puerto 50422...")
        report["http_probe"] = probe_http_server()
        print(f"⬅️  HTTP 50422: {report['http_probe']}")

        # 5. Cerrar sesión limpiamente para no dejar bloqueada la cámara
        print("\n👋 Cerrando sesión con la cámara (msg_id=258)...")
        disconnect_resps = send_cmd(sock, MSG_DISCONNECT, token=token, wait_timeout=1.0)
        report["responses"]["DISCONNECT_258"] = disconnect_resps

    except Exception as e:
        print(f"\n❌ Error durante la prueba: {e}")
        report["errors"].append({"fatal": str(e)})
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass

    # Guardar el reporte en disco
    REPORT_PATH.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    play_sound("Glass")

    print("\n" + "=" * 68)
    print(f"🎉 ¡LISTO! Reporte guardado en: {REPORT_PATH.name}")
    print("📶 YA PUEDES VOLVER A CONECTAR TU MAC A TU WI-FI NORMAL CON INTERNET")
    print("=" * 68)


if __name__ == "__main__":
    main()
