#!/usr/bin/env python3
"""
Controlador completo para Xiaomi Mi Sphere 360 (Mijia 360 / Madventure 360).
Usa un hilo lector continuo (arquitectura asíncrona por msg_id) para que respuestas
lentas del firmware (como msg_id 257 que tarda ~2.2s o 6147 que tarda ~1.8s)
nunca desincronicen el buffer TCP ni disparen reconexiones duplicadas.
"""

from __future__ import annotations

import json
import select
import shutil
import socket
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

CAMERA_IP = "192.168.42.1"
CONTROL_PORT = 7878
HTTP_PORT = 50422
RTSP_URL = f"rtsp://{CAMERA_IP}/live"

BASE_DIR = Path(__file__).parent
SESSION_LOG_PATH = Path("/tmp/misphere_session_log.json")
REPORT_PATH = BASE_DIR / "camera_report.json"

# IDs de mensajes del protocolo Ambarella / Mi Sphere 360
MSG_CONNECT = 257
MSG_DISCONNECT = 258
MSG_START_LIVE = 259
MSG_STOP_LIVE = 260
MSG_REGISTER_TCP = 261
MSG_FILE_PREVIEW = 1025
MSG_FILE_INFO = 1026
MSG_DELETE_FILE = 1281
MSG_LIST_DIR = 1282
MSG_CHANGE_DIR = 1283
MSG_GET_WIFI = 1539
MSG_SESSION_KICKED = 1793
MSG_GET_SERIAL_NO = 4097
MSG_GET_STORAGE = 4358
MSG_BATTERY_STATUS = 4361
MSG_STANDBY = 4362
MSG_GET_DEVICE = 4364
MSG_GET_CAMERA = 4365

# Modos y captura
MSG_SWITCH_MODE = 4611          # 1: Foto, 0: Video
MSG_VIDEO_RES = 4612            # Resolución de video
MSG_SET_VIDEO_SHORT = 4618      # 0, 10, 20, 30 s
MSG_SET_VIDEO_TIMELAPSE = 4621  # 0, 255(0.5s), 1, 2, 5, 10, 30, 60 s
MSG_VIDEO_LONGPRESS = 4623
MSG_PHOTO_PRESS = 4864          # Disparar foto
MSG_SET_PHOTO_TIMER = 4866      # 0, 3, 4, 5, 6, 7, 8, 9, 10 s
MSG_PHOTO_LONGPRESS = 4868      # Disparar foto con timer
MSG_PHOTO_RES = 4872            # 0: 6912x3456, 1: 3456x1728(stitched), 2: 6912x3456(stitched), 3: RAW
MSG_SET_VIDEO_SLOWMO = 4916     # 0, 2x
MSG_SET_GPS = 4917
MSG_SET_PHOTO_BRACKETING = 4918 # param = int(2 * ev_step)
MSG_SET_PHOTO_INTERVAL = 4929   # 0, 2, 5, 10, 30, 60, 120, 300 s
MSG_VIDEO_REC_START = 5028      # Iniciar grabación de video
MSG_VIDEO_REC_STOP = 514        # Detener grabación de video

# Parámetros de imagen (Video y Foto)
MSG_VIDEO_WB = 5136             # 0: Auto, 1: Exterior, 2: Nublado, 3: Incandescente, 4: Fluorescente
MSG_VIDEO_EV = 5137             # param = int(2 * ev) [-6 a +6]
MSG_PHOTO_WB = 5168             # 0: Auto, 1: Exterior, 2: Nublado, 3: Incandescente, 4: Fluorescente
MSG_PHOTO_EV = 5169             # param = int(2 * ev) [-6 a +6]
MSG_PHOTO_SHUTTER = 5171        # 0: Auto, >=1: segs, <1: (1<<15) + denominador
MSG_PHOTO_ISO = 5172            # 0: Auto, 50, 100, 200, 400, 800, 1600

# Sistema
MSG_SET_BUZZER = 6145           # 0..4
MSG_SET_DATE = 6147             # "YYYY-MM-DD-HH-MM-SS-weekday"
MSG_AUTO_TURN_OFF = 6151        # 0, 5, 10 min
MSG_TURN_OFF = 6155             # Apagar cámara
MSG_SET_LED = 6156              # 0, 1
MSG_GYRO_CALIB = 6165           # Calibrar giroscopio


PHOTO_RES_OPTIONS = [
    {"id": 0, "label": "6912×3456 (Original Dual Fisheye)"},
    {"id": 1, "label": "3456×1728 (Cosido 360° en cámara)"},
    {"id": 2, "label": "6912×3456 (Cosido 360° en cámara)"},
    {"id": 3, "label": "6912×3456 + RAW (.DNG)"},
]

VIDEO_RES_OPTIONS = [
    {"id": 0, "label": "3456×1728 | 30 fps (3.5K)"},
    {"id": 1, "label": "2304×1152 | 30 fps (2.3K)"},
    {"id": 2, "label": "2304×1152 | 60 fps"},
    {"id": 7, "label": "2048×512 | 120 fps (Superior)"},
    {"id": 9, "label": "2048×512 | 120 fps (Bullet Time)"},
    {"id": 10, "label": "3456×1728 | 30 fps (Alto Bitrate)"},
]

WB_OPTIONS = [
    {"id": 0, "label": "Auto"},
    {"id": 1, "label": "Exterior (Sol)"},
    {"id": 2, "label": "Nublado"},
    {"id": 3, "label": "Incandescente"},
    {"id": 4, "label": "Fluorescente"},
]

ISO_OPTIONS = [
    {"id": 0, "label": "Auto"},
    {"id": 50, "label": "ISO 50"},
    {"id": 100, "label": "ISO 100"},
    {"id": 200, "label": "ISO 200"},
    {"id": 400, "label": "ISO 400"},
    {"id": 800, "label": "ISO 800"},
    {"id": 1600, "label": "ISO 1600"},
]

SHUTTER_STRINGS = [
    "Auto",
    "1/6400", "1/3200", "1/2000", "1/1000", "1/500", "1/240",
    "1/120", "1/60", "1/30", "1/15", "1/8", "1/4",
    "1", "2", "4", "8", "12", "16", "20", "24", "28", "32"
]


def play_sound(sound_name="Glass"):
    try:
        sound_file = f"/System/Library/Sounds/{sound_name}.aiff"
        subprocess.Popen(["afplay", sound_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def ask_mac_folder(prompt_msg: str, default_dir: Path | None = None) -> Path | None:
    """Abre el diálogo nativo de macOS Finder para que el usuario elija siempre en qué carpeta guardar o trabajar."""
    safe_prompt = prompt_msg.replace('"', "'")
    loc_clause = ""
    if default_dir and default_dir.exists():
        safe_loc = str(default_dir.resolve()).replace('"', '\\"')
        loc_clause = f' default location (POSIX file "{safe_loc}")'
    script = (
        'tell application "System Events"\n'
        '  activate\n'
        f'  set p to POSIX path of (choose folder with prompt "{safe_prompt}"{loc_clause})\n'
        '  return p\n'
        'end tell'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        return None
    return Path(res.stdout.strip()).resolve()


def ask_mac_save_file(prompt_msg: str, default_name: str, default_dir: Path | None = None) -> Path | None:
    """Abre el diálogo nativo 'Guardar como...' de macOS Finder para que el usuario elija dónde guardar un archivo."""
    safe_prompt = prompt_msg.replace('"', "'")
    safe_name = default_name.replace('"', "'")
    loc_clause = ""
    if default_dir and default_dir.exists():
        safe_loc = str(default_dir.resolve()).replace('"', '\\"')
        loc_clause = f' default location (POSIX file "{safe_loc}")'
    script = (
        'tell application "System Events"\n'
        '  activate\n'
        f'  set p to POSIX path of (choose file name with prompt "{safe_prompt}" default name "{safe_name}"{loc_clause})\n'
        '  return p\n'
        'end tell'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if res.returncode != 0 or not res.stdout.strip():
        return None
    return Path(res.stdout.strip()).resolve()


def get_local_ip_for_camera():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.8)
        s.connect((CAMERA_IP, CONTROL_PORT))
        local_ip = s.getsockname()[0]
        s.close()
        return local_ip
    except Exception:
        return None


def encode_shutter(val_str: str) -> int:
    val_str = str(val_str).strip()
    if val_str.lower() == "auto" or val_str == "0":
        return 0
    if val_str.startswith("1/"):
        denom = int(val_str[2:])
        return (1 << 15) + denom
    if val_str.endswith("s"):
        val_str = val_str[:-1]
    return int(val_str)


def decode_shutter(raw_val: int) -> str:
    if raw_val == 0:
        return "Auto"
    if raw_val >= (1 << 15):
        return f"1/{raw_val - (1 << 15)}"
    if 0 < raw_val < len(SHUTTER_STRINGS) and str(raw_val) not in SHUTTER_STRINGS:
        return SHUTTER_STRINGS[raw_val]
    return str(raw_val)


def decode_iso(raw_val: int) -> int:
    valid_isos = [0, 50, 100, 200, 400, 800, 1600]
    if raw_val in valid_isos:
        return raw_val
    if 0 <= raw_val < len(valid_isos):
        return valid_isos[raw_val]
    return 0


def decode_battery(raw_val: int) -> dict:
    charging = raw_val > 100
    percent = raw_val - 128 if raw_val >= 128 else raw_val
    percent = max(0, min(100, percent))
    return {"raw": raw_val, "percent": percent, "charging": charging}


SHUTTER_OPTIONS = [
    {"id": encode_shutter(s), "code": s, "label": "Auto" if s == "Auto" else f"{s} s"}
    for s in SHUTTER_STRINGS
]

EV_OPTIONS = [
    {"id": int(ev * 2), "ev": ev, "label": f"{ev:+.1f} EV" if ev != 0 else "0.0 EV"}
    for ev in [-3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
]


class MiSphereController:
    def __init__(self, auto_connect: bool = True):
        self.sock = None
        self.token = None
        self.connected = False
        self.connecting = False
        self.recv_running = False
        self.user_paused_autoconnect = False

        self.connect_lock = threading.Lock()
        self.send_lock = threading.Lock()
        self.last_send_time = 0.0

        # Eventos y respuestas por msg_id
        self.wait_events = {}
        self.last_responses = {}

        self.device_state = {}
        self.camera_state = {}
        self.storage_state = {}
        self.dcim_folders = []
        self.logs = []

        # Estado de Vista en Vivo (RTSP -> MJPEG / WebGL)
        self.live_running = False
        self.live_proc = None
        self.live_lock = threading.Lock()
        self.live_frame_cond = threading.Condition()
        self.live_frame_bytes = None
        self.live_frame_id = 0
        self.live_frame_time = 0.0
        self.live_last_client_access = 0.0
        self.live_error = ""
        self.live_transport = "udp"

        # Carpeta recordada durante la sesión para los diálogos nativos de Finder y el Procesador Local
        self.last_user_save_dir: Path | None = None
        self.local_work_dir: Path | None = None

        self._load_cached_report()
        self._log("INFO", {"msg": "Controlador listo. Esperando Wi-Fi de la cámara (192.168.42.1:7878)..."})

        if auto_connect:
            self.watcher_thread = threading.Thread(target=self._auto_connect_loop, daemon=True)
            self.watcher_thread.start()

    def _load_cached_report(self):
        if REPORT_PATH.exists():
            try:
                data = json.loads(REPORT_PATH.read_text(encoding="utf-8"))
                resps = data.get("responses", {})
                if resps.get("GET_DEVICE_4364"):
                    self.device_state = resps["GET_DEVICE_4364"][0]
                if resps.get("GET_CAMERA_4365"):
                    self.camera_state = resps["GET_CAMERA_4365"][0]
                if resps.get("GET_STORAGE_4358"):
                    self.storage_state = resps["GET_STORAGE_4358"][0]
                if resps.get("LIST_DIR_1282"):
                    listing = resps["LIST_DIR_1282"][0].get("listing", [])
                    self.dcim_folders = [list(item.keys())[0].rstrip("/") for item in listing if item]
            except Exception:
                pass

    def _log(self, direction: str, payload: dict):
        entry = {
            "time": datetime.now().strftime("%H:%M:%S.%f")[:-3],
            "dir": direction,
            "data": payload,
        }
        self.logs.append(entry)
        if len(self.logs) > 200:
            self.logs = self.logs[-200:]
        try:
            SESSION_LOG_PATH.write_text(
                json.dumps(self.logs[-100:], indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
        except Exception:
            pass

    def _recv_loop(self, sock: socket.socket):
        """
        Hilo lector continuo (idéntico al diseño de pysphere) que decodifica todos
        los mensajes JSON entrantes sin perder paquetes tardíos ni desincronizar comandos.
        """
        buffer = ""
        while self.recv_running and self.sock is sock:
            try:
                r, _, _ = select.select([sock], [], [], 0.25)
                if not r:
                    continue
                chunk = sock.recv(4096)
                if not chunk:
                    self._log("ERR", {"msg": "La cámara cerró el socket TCP."})
                    self.connected = False
                    break
                buffer += chunk.decode("utf-8", errors="replace")
                while buffer.strip():
                    buffer = buffer.lstrip()
                    try:
                        obj, idx = json.JSONDecoder().raw_decode(buffer)
                        buffer = buffer[idx:]
                        self._handle_incoming_message(obj)
                    except json.JSONDecodeError:
                        # Esperar más bytes si el JSON viene fragmentado
                        break
            except Exception as e:
                if self.recv_running:
                    self._log("ERR", {"recv_loop_error": str(e)})
                self.connected = False
                break

    def _handle_incoming_message(self, msg: dict):
        self._log("IN", msg)
        mid = msg.get("msg_id")

        if mid == MSG_CONNECT and msg.get("rval", 0) >= 0 and "param" in msg:
            self.token = msg["param"]
            self.connected = True
        elif mid == MSG_DISCONNECT:
            self.connected = False
        elif mid == MSG_GET_DEVICE and msg.get("rval", 0) >= 0:
            self.device_state.update(msg)
        elif mid == MSG_GET_CAMERA and msg.get("rval", 0) >= 0:
            self.camera_state.update(msg)
        elif mid == MSG_GET_STORAGE and msg.get("rval", 0) >= 0:
            self.storage_state.update(msg)
        elif mid in (8192, 8193):
            # Evento asíncrono de foto (8193) o video (8192) guardado en la microSD
            for k in ("remain_jpg", "remain_video", "sd_total", "sd_free", "sd_full"):
                if k in msg:
                    self.storage_state[k] = msg[k]
            if "param" in msg:
                self.device_state["last_file"] = msg["param"]
                parts = str(msg["param"]).replace("/", "\\").split("\\")
                if len(parts) >= 3 and parts[1].upper() == "DCIM":
                    folder_name = parts[2]
                    if folder_name and folder_name not in self.dcim_folders:
                        self.dcim_folders.append(folder_name)
            if mid == 8193 and "cam_jpg" in self.device_state:
                self.device_state["cam_jpg"] = self.device_state.get("cam_jpg", 0) + 1
            elif mid == 8192 and "cam_mp4" in self.device_state:
                self.device_state["cam_mp4"] = self.device_state.get("cam_mp4", 0) + 1
        elif mid == MSG_BATTERY_STATUS and "param" in msg:
            self.device_state["battery"] = msg["param"]
        elif mid == MSG_SWITCH_MODE and msg.get("rval", 0) >= 0:
            if "param" in msg:
                try:
                    self.camera_state["mode"] = int(msg["param"])
                except Exception:
                    pass
            if "sub_mode" in msg:
                self.camera_state["sub_mode"] = msg["sub_mode"]

        if mid is not None:
            self.last_responses[mid] = msg
            ev = self.wait_events.get(mid)
            if ev:
                ev.set()
            # Algunos comandos de captura (5028, 4868, 4623) responden con msg_id=513
            if mid == 513:
                for alias_id in (MSG_VIDEO_REC_START, MSG_PHOTO_LONGPRESS, MSG_VIDEO_LONGPRESS):
                    self.last_responses[alias_id] = msg
                    alias_ev = self.wait_events.get(alias_id)
                    if alias_ev:
                        alias_ev.set()

    def _send_and_wait(self, msg_id: int, token=None, extra: dict = None, timeout: float = 3.0) -> dict:
        with self.send_lock:
            if not self.sock:
                raise RuntimeError("No hay socket TCP activo con la cámara.")

            # Respetar pausa mínima de 0.4s entre envíos como requiere el firmware Ambarella
            elapsed = time.time() - self.last_send_time
            if elapsed < 0.4:
                time.sleep(0.4 - elapsed)

            use_token = self.token if token is None else token
            payload = {"msg_id": msg_id, "token": use_token}
            if extra:
                for k, v in extra.items():
                    payload[k] = str(v) if k == "param" else v

            ev = threading.Event()
            self.wait_events[msg_id] = ev
            self.last_responses.pop(msg_id, None)

            raw = json.dumps(payload).encode("utf-8")
            self._log("OUT", payload)
            self.sock.sendall(raw)
            self.last_send_time = time.time()

        # Esperar la respuesta específica de este msg_id fuera del send_lock
        ev.wait(timeout=timeout)
        return self.last_responses.get(msg_id, {"_timeout": True, "msg_id": msg_id})

    def _auto_connect_loop(self):
        while True:
            try:
                if not self.connected and not self.connecting and not self.user_paused_autoconnect:
                    local_ip = get_local_ip_for_camera()
                    if local_ip and local_ip.startswith("192.168.42."):
                        try:
                            self.connect(sync_clock=True, silent_fail=True)
                        except Exception:
                            pass
                elif self.connected and not self.connecting:
                    # Keep-alive cada 45 segundos para reducir actividad Wi-Fi y calentamiento de la cámara
                    if time.time() - self.last_send_time > 45.0:
                        try:
                            self._send_and_wait(MSG_GET_DEVICE, timeout=2.5)
                        except Exception as e:
                            self._log("ERR", {"keepalive_error": str(e)})
                            self._close_socket()
            except Exception:
                pass
            time.sleep(3.0)

    def _close_socket(self):
        self._terminate_live_proc()
        self.recv_running = False
        self.connected = False
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.token = None

    def _terminate_live_proc(self):
        self.live_running = False
        proc = self.live_proc
        self.live_proc = None
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=1.0)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        with self.live_frame_cond:
            self.live_frame_cond.notify_all()

    def start_live_view(self) -> dict:
        with self.live_lock:
            self.live_last_client_access = time.time()
            if self.live_running and self.live_proc is not None and self.live_proc.poll() is None:
                return {"ok": True, "live_running": True, "status": self.get_full_status()}

            if not self.connected:
                self.connect(sync_clock=False)

            self.live_error = ""
            # Activar/reiniciar el viewfinder en el firmware Ambarella (msg_id: 259)
            try:
                resp_vf = self._send_and_wait(MSG_START_LIVE, timeout=2.0)
                self._log("INFO", {"live_view_reset_vf_259": resp_vf})
            except Exception as e:
                self._log("ERR", {"live_view_reset_vf_error": str(e)})

            self._terminate_live_proc()
            self.live_running = True
            self.live_last_client_access = time.time()

            t = threading.Thread(target=self._live_stream_worker, daemon=True)
            t.start()
            return {"ok": True, "live_running": True, "status": self.get_full_status()}

    def stop_live_view(self, send_stop_msg: bool = True) -> dict:
        with self.live_lock:
            was_running = self.live_running or (self.live_proc is not None)
            self._terminate_live_proc()
            if send_stop_msg and was_running and self.connected and self.sock:
                try:
                    resp = self._send_and_wait(MSG_STOP_LIVE, timeout=1.5)
                    self._log("INFO", {"live_view_stop_vf_260": resp})
                except Exception:
                    pass
            return {"ok": True, "live_running": False, "status": self.get_full_status()}

    def _find_ffmpeg_bin(self) -> str:
        for cand in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", shutil.which("ffmpeg") or ""):
            if cand and Path(cand).exists():
                return cand
        raise RuntimeError("No se encontró ffmpeg instalado en el Mac (/opt/homebrew/bin/ffmpeg).")

    def _live_stream_worker(self):
        """
        Subproceso lector de rtsp://192.168.42.1/live mediante ffmpeg.
        Intenta primero transporte UDP (por defecto en Ambarella :554) y si no recibe cuadros
        en 4 segundos, reintenta automáticamente con transporte TCP (-rtsp_transport tcp).
        Se apaga automáticamente si el navegador deja de pedir cuadros por más de 15 segundos.
        """
        try:
            ffmpeg_bin = self._find_ffmpeg_bin()
        except Exception as e:
            self.live_error = str(e)
            self.live_running = False
            self._log("ERR", {"live_ffmpeg_missing": str(e)})
            return

        transports = ["udp", "tcp"]
        t_idx = 0

        while self.live_running and self.connected:
            if time.time() - self.live_last_client_access > 15.0:
                self._log("INFO", {"msg": "Vista en vivo detenida automáticamente por inactividad (ahorro térmico)."})
                self.stop_live_view(send_stop_msg=True)
                break

            transport = transports[t_idx % len(transports)]
            self.live_transport = transport

            cmd = [
                ffmpeg_bin,
                "-hide_banner",
                "-loglevel", "error",
            ]
            if transport == "tcp":
                cmd += ["-rtsp_transport", "tcp"]
            cmd += [
                "-fflags", "nobuffer",
                "-flags", "low_delay",
                "-probesize", "32768",
                "-analyzeduration", "500000",
                "-i", RTSP_URL,
                "-f", "image2pipe",
                "-vcodec", "mjpeg",
                "-q:v", "5",
                "-r", "15",
                "-",
            ]

            self._log("INFO", {"msg": f"Iniciando flujo RTSP en vivo ({RTSP_URL}, transporte={transport})..."})
            try:
                proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0,
                )
                self.live_proc = proc
            except Exception as e:
                self.live_error = f"Error al iniciar ffmpeg: {e}"
                self.live_running = False
                break

            buf = bytearray()
            got_frames_this_run = 0
            start_ts = time.time()

            try:
                while self.live_running and proc.poll() is None:
                    if time.time() - self.live_last_client_access > 15.0:
                        self._log("INFO", {"msg": "Vista en vivo en pausa automática (sin clientes activos >15s)."})
                        self.stop_live_view(send_stop_msg=True)
                        return

                    r, _, _ = select.select([proc.stdout], [], [], 0.5)
                    if not r:
                        if got_frames_this_run == 0 and (time.time() - start_ts) > 4.5:
                            # Cambiar de transporte (UDP <-> TCP) y reenviar 259
                            break
                        continue

                    chunk = proc.stdout.read(32768)
                    if not chunk:
                        break
                    buf.extend(chunk)

                    # Extraer todos los cuadros JPEG completos (0xFFD8 ... 0xFFD9) del buffer
                    while True:
                        soi = buf.find(b"\xff\xd8")
                        if soi < 0:
                            buf.clear()
                            break
                        if soi > 0:
                            del buf[:soi]
                        eoi = buf.find(b"\xff\xd9", 2)
                        if eoi < 0:
                            break
                        frame = bytes(buf[: eoi + 2])
                        del buf[: eoi + 2]

                        got_frames_this_run += 1
                        with self.live_frame_cond:
                            self.live_frame_bytes = frame
                            self.live_frame_id += 1
                            self.live_frame_time = time.time()
                            self.live_error = ""
                            self.live_frame_cond.notify_all()
            except Exception as e:
                self._log("ERR", {"live_reader_error": str(e)})
            finally:
                try:
                    proc.terminate()
                except Exception:
                    pass

            if not self.live_running:
                break

            if got_frames_this_run == 0:
                t_idx += 1
                try:
                    if self.connected:
                        self._send_and_wait(MSG_START_LIVE, timeout=1.5)
                except Exception:
                    pass
                time.sleep(0.5)
            else:
                time.sleep(0.3)

    def get_live_frame(self) -> tuple[bytes | None, int]:
        self.live_last_client_access = time.time()
        if not self.live_running:
            try:
                self.start_live_view()
            except Exception as e:
                self.live_error = str(e)
                return None, 0

        # Si aún no hay un cuadro reciente, esperar hasta 2.5s al primer cuadro
        with self.live_frame_cond:
            if self.live_frame_bytes is None or (time.time() - self.live_frame_time > 3.0):
                self.live_frame_cond.wait(timeout=2.5)
            return self.live_frame_bytes, self.live_frame_id

    def wait_for_next_live_frame(self, last_id: int, timeout: float = 1.5) -> tuple[bytes | None, int]:
        self.live_last_client_access = time.time()
        with self.live_frame_cond:
            if self.live_frame_id <= last_id:
                self.live_frame_cond.wait(timeout=timeout)
            return self.live_frame_bytes, self.live_frame_id

    def connect(self, sync_clock: bool = True, silent_fail: bool = False) -> dict:
        if not self.connect_lock.acquire(blocking=False):
            # Ya hay una conexión en curso; esperar a que termine
            with self.connect_lock:
                return self.get_full_status()

        self.connecting = True
        try:
            self.user_paused_autoconnect = False
            if self.connected and self.sock and self.token is not None:
                return self.get_full_status()

            self._close_socket()
            local_ip = get_local_ip_for_camera()

            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(2.5)

            try:
                sock.connect((CAMERA_IP, CONTROL_PORT))
            except Exception as e:
                sock.close()
                if not silent_fail:
                    self._log("ERR", {
                        "connect_failed": str(e),
                        "local_ip_detected": local_ip,
                    })
                raise

            self.sock = sock
            self.recv_running = True
            recv_thread = threading.Thread(target=self._recv_loop, args=(sock,), daemon=True)
            recv_thread.start()

            time.sleep(0.25)
            self._log("INFO", {"connected_tcp": f"{CAMERA_IP}:{CONTROL_PORT}", "local_ip": local_ip})

            # NOTA CLAVE: En tu cámara vimos que msg_id 257 tarda ~2.15 segundos en responder.
            # Le damos hasta 5.0 segundos sin interrumpirlo para nunca disparar sesiones duplicadas.
            resp = self._send_and_wait(MSG_CONNECT, token=0, timeout=5.0)
            if not self.connected or self.token is None:
                self._close_socket()
                self._log("ERR", {"token_timeout_or_error": resp})
                raise RuntimeError(f"La cámara no entregó token tras 5s: {resp}")

            play_sound("Glass")
            self._log("INFO", {"msg": f"¡Sesión activa con Token #{self.token}!"})

            if sync_clock:
                now = datetime.now()
                date_str = now.strftime("%Y-%m-%d-%H-%M-%S-") + str(now.isoweekday())
                # En tu cámara vimos que 6147 tarda ~1.75s en responder
                self._send_and_wait(MSG_SET_DATE, extra={"param": date_str}, timeout=3.5)

            self._refresh_internal()
            return self.get_full_status()
        finally:
            self.connecting = False
            self.connect_lock.release()

    def disconnect(self) -> dict:
        with self.connect_lock:
            self.user_paused_autoconnect = True
            if self.live_running:
                try:
                    self.stop_live_view(send_stop_msg=True)
                except Exception:
                    pass
            if self.sock and self.token is not None:
                try:
                    self._send_and_wait(MSG_DISCONNECT, timeout=1.5)
                except Exception:
                    pass
            self._close_socket()
            self._log("INFO", {"msg": "Sesión cerrada limpiamente."})
            return self.get_full_status()

    def _refresh_internal(self):
        self._send_and_wait(MSG_GET_DEVICE, timeout=2.5)
        self._send_and_wait(MSG_GET_CAMERA, timeout=2.5)
        self._send_and_wait(MSG_GET_STORAGE, timeout=2.5)
        try:
            self.list_dcim_files(None)
        except Exception:
            pass

    def refresh(self) -> dict:
        if not self.connected:
            return self.connect(sync_clock=False)
        self._refresh_internal()
        return self.get_full_status()

    def send_command(self, msg_id: int, param=None, extra: dict = None, refresh_after: bool = True) -> dict:
        if not self.connected:
            self.connect(sync_clock=False)

        # Si hay un sub-modo activo (Timer, Intervalómetro, Bracketing, Video Corto, Timelapse, SlowMo),
        # el botón principal de disparo debe usar el comando de sub-modo (4868 en Foto, 4623 en Video).
        sub_mode = self.camera_state.get("sub_mode", 0)
        if msg_id == MSG_PHOTO_PRESS and sub_mode in (1, 2, 4):
            self._log("INFO", {"msg": f"Sub-modo de foto activo (sub_mode={sub_mode}): usando msg_id 4868 (PHOTO_LONGPRESS)"})
            msg_id = MSG_PHOTO_LONGPRESS
        elif msg_id == MSG_VIDEO_REC_START and sub_mode in (1, 2, 4):
            self._log("INFO", {"msg": f"Sub-modo de video activo (sub_mode={sub_mode}): usando msg_id 4623 (VIDEO_LONGPRESS)"})
            msg_id = MSG_VIDEO_LONGPRESS

        # Si la Vista en Vivo está activa y se va a disparar una foto o cambiar modo/resolución,
        # pausar momentáneamente el stream para que el ISP de la cámara capture a resolución completa
        # y reanudarlo automáticamente al terminar.
        was_live = self.live_running
        pause_live_for_cmd = was_live and msg_id in (
            MSG_PHOTO_PRESS,
            MSG_PHOTO_LONGPRESS,
            MSG_SWITCH_MODE,
            MSG_PHOTO_RES,
            MSG_VIDEO_RES,
        )
        if pause_live_for_cmd:
            self.stop_live_view(send_stop_msg=True)

        cmd_extra = dict(extra or {})
        if param is not None:
            cmd_extra["param"] = param

        resp = self._send_and_wait(msg_id, extra=cmd_extra if cmd_extra else None, timeout=3.5)

        # Actualizar nuestro estado local de inmediato si el comando fue exitoso (rval == 0)
        if resp.get("rval") == 0:
            self._apply_optimistic_update(msg_id, param)

        # Si se acaba de disparar con Temporizador (4868 con sub_mode==1), no bombardear la cámara
        # con consultas 4364/4365 durante la cuenta regresiva; esperar el evento asíncrono 8193.
        if msg_id == MSG_PHOTO_LONGPRESS and sub_mode == 1:
            timer_sec = int(self.camera_state.get("timing", 3) or 3)
            self.last_send_time = time.time() + timer_sec
            refresh_after = False
            if pause_live_for_cmd:
                def _resume_after_timer(delay_s):
                    time.sleep(delay_s + 1.5)
                    if self.connected:
                        self.start_live_view()
                threading.Thread(target=_resume_after_timer, args=(timer_sec,), daemon=True).start()
                pause_live_for_cmd = False

        if refresh_after:
            self._send_and_wait(MSG_GET_DEVICE, timeout=2.5)
            self._send_and_wait(MSG_GET_CAMERA, timeout=2.5)
            if msg_id in (MSG_PHOTO_PRESS, MSG_PHOTO_LONGPRESS, MSG_VIDEO_REC_STOP, MSG_DELETE_FILE):
                self._send_and_wait(MSG_GET_STORAGE, timeout=2.5)

        if pause_live_for_cmd and self.connected:
            self.start_live_view()

        return {
            "responses": [resp],
            "status": self.get_full_status(),
        }

    def _apply_optimistic_update(self, msg_id: int, param):
        """Actualiza el diccionario de estado inmediatamente tras recibir rval=0."""
        try:
            if param is None:
                return
            val = int(param)
            if msg_id == MSG_SWITCH_MODE:
                self.camera_state["mode"] = val
            elif msg_id == MSG_PHOTO_RES:
                self.device_state["p_res"] = val
            elif msg_id == MSG_PHOTO_ISO:
                self.device_state["still_iso"] = val
            elif msg_id == MSG_PHOTO_SHUTTER:
                self.device_state["still_shutter"] = val
            elif msg_id == MSG_PHOTO_WB:
                self.device_state["still_wb"] = val
            elif msg_id == MSG_PHOTO_EV:
                self.device_state["still_ev"] = val
            elif msg_id == MSG_SET_PHOTO_TIMER:
                self.camera_state["timing"] = val
                self.camera_state["sub_mode"] = 1 if val > 0 else 0
            elif msg_id == MSG_SET_PHOTO_INTERVAL:
                self.camera_state["cap_interval"] = val
                self.camera_state["sub_mode"] = 2 if val > 0 else 0
            elif msg_id == MSG_SET_PHOTO_BRACKETING:
                self.camera_state["surroundexp"] = val
                self.camera_state["sub_mode"] = 4 if val > 0 else 0
            elif msg_id == MSG_VIDEO_RES:
                self.device_state["v_res"] = val
            elif msg_id == MSG_VIDEO_WB:
                self.device_state["video_wb"] = val
            elif msg_id == MSG_VIDEO_EV:
                self.device_state["video_ev"] = val
            elif msg_id == MSG_SET_VIDEO_SHORT:
                self.camera_state["second"] = val
                self.camera_state["sub_mode"] = 1 if val > 0 else 0
            elif msg_id == MSG_SET_VIDEO_TIMELAPSE:
                self.camera_state["lapse"] = val
                self.camera_state["sub_mode"] = 2 if val > 0 else 0
            elif msg_id == MSG_SET_VIDEO_SLOWMO:
                self.camera_state["speedx"] = val
                self.camera_state["sub_mode"] = 4 if val > 0 else 0
            elif msg_id == MSG_SET_BUZZER:
                self.device_state["buzzer"] = val
            elif msg_id == MSG_SET_LED:
                self.device_state["led"] = val
        except Exception:
            pass

    def _filename_variants(self, filename: str) -> list:
        """
        Genera variantes del nombre de archivo porque Ambarella LIST_DIR (1282) oculta el sufijo 'AA'
        en los .JPG (reporta IMG_YYYYMMDD_HHMMSS.JPG), mientras que en el sistema de archivos FAT32
        y en el servidor HTTP Cherokee (:50422) el archivo real se llama IMG_YYYYMMDD_HHMMSSAA.JPG.
        """
        clean = filename.strip("/")
        variants = [clean]
        upper = clean.upper()
        if upper.endswith(".JPG") and not upper.endswith("AA.JPG"):
            stem = clean[:-4]
            ext = clean[-4:]
            variants.insert(0, f"{stem}AA{ext}")
            variants.append(f"{stem}aa{ext.lower()}")
        elif upper.endswith("AA.JPG"):
            stem = clean[:-6]
            ext = clean[-4:]
            variants.append(f"{stem}{ext}")
        elif upper.endswith(".MP4") and not upper.endswith("AA.MP4"):
            stem = clean[:-4]
            ext = clean[-4:]
            variants.append(f"{stem}AA{ext}")
        return list(dict.fromkeys(variants))

    def _discover_http_folder_links(self, folder: str) -> dict:
        """
        Consulta el índice HTML de Cherokee (192.168.42.1:50422) para la carpeta indicada y
        extrae los enlaces reales (<a href="...">) servidos por HTTP.
        """
        import re
        import urllib.parse
        import urllib.request

        clean_folder = folder.strip("/")
        base_http = f"http://{CAMERA_IP}:{HTTP_PORT}"
        candidate_dirs = [
            f"{base_http}/DCIM/{clean_folder}/",
            f"{base_http}/{clean_folder}/",
            f"{base_http}/SD0/DCIM/{clean_folder}/",
            f"{base_http}/tmp/SD0/DCIM/{clean_folder}/",
        ]

        # También inspeccionar la raíz de :50422 si aún no sabemos cómo estructura Cherokee las rutas
        try:
            with urllib.request.urlopen(f"{base_http}/", timeout=2.5) as resp:
                root_html = resp.read().decode("utf-8", errors="replace")
                root_hrefs = re.findall(r'href=["\']([^"\']+)["\']', root_html, flags=re.IGNORECASE)
                for h in root_hrefs:
                    if clean_folder in h:
                        full_dir = urllib.parse.urljoin(f"{base_http}/", h)
                        if not full_dir.endswith("/"):
                            full_dir += "/"
                        if full_dir not in candidate_dirs:
                            candidate_dirs.insert(0, full_dir)
        except Exception:
            pass

        found_map = {}
        for dir_url in candidate_dirs:
            try:
                req = urllib.request.Request(dir_url, method="GET")
                with urllib.request.urlopen(req, timeout=3.0) as resp:
                    if resp.status != 200:
                        continue
                    html = resp.read().decode("utf-8", errors="replace")
                    hrefs = re.findall(r'href=["\']([^"\']+)["\']', html, flags=re.IGNORECASE)
                    for h in hrefs:
                        if h in ("../", "./", "/") or h.startswith("?") or "/icons/" in h:
                            continue
                        full_file_url = urllib.parse.urljoin(dir_url, h)
                        fname = urllib.parse.unquote(full_file_url.rstrip("/").split("/")[-1])
                        if not fname or fname == clean_folder:
                            continue
                        found_map[fname] = full_file_url
                        found_map[fname.upper()] = full_file_url
                        # Mapear también sin el sufijo AA para que coincida con LIST_DIR (1282)
                        if fname.upper().endswith("AA.JPG"):
                            short_name = fname[:-6] + fname[-4:]
                            found_map[short_name] = full_file_url
                            found_map[short_name.upper()] = full_file_url
                    if found_map:
                        self._log("INFO", {"http_dir_resolved": dir_url, "files_found": len(found_map) // 2})
                        break
            except Exception:
                continue

        return found_map

    def fetch_camera_media(self, rel_path: str) -> tuple:
        """
        Descarga un archivo desde el servidor HTTP de la cámara (:50422) probando tanto las rutas
        descubiertas en el índice Cherokee como las variantes con/sin sufijo 'AA.JPG'.
        Retorna (bytes_data, content_type, resolved_filename).
        """
        import mimetypes
        import urllib.request

        parts = [p for p in rel_path.strip("/").split("/") if p]
        if len(parts) >= 2 and parts[0].upper() == "DCIM":
            parts = parts[1:]
        if len(parts) < 2:
            raise ValueError(f"Ruta de archivo inválida: {rel_path}")

        folder, filename = parts[0], parts[-1]
        base_http = f"http://{CAMERA_IP}:{HTTP_PORT}"

        candidate_urls = []
        # 1. Consultar primero el índice del directorio en Cherokee (:50422)
        dir_map = self._discover_http_folder_links(folder)
        for var in self._filename_variants(filename):
            if var in dir_map:
                candidate_urls.append(dir_map[var])
            elif var.upper() in dir_map:
                candidate_urls.append(dir_map[var.upper()])

        # 2. Agregar URLs candidatas directas con y sin 'AA.JPG'
        for var in self._filename_variants(filename):
            for prefix in (f"/DCIM/{folder}", f"/{folder}", f"/SD0/DCIM/{folder}", f"/tmp/SD0/DCIM/{folder}"):
                u = f"{base_http}{prefix}/{var}"
                if u not in candidate_urls:
                    candidate_urls.append(u)

        last_err = None
        for url in candidate_urls:
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=15.0) as resp:
                    data = resp.read()
                    resolved_name = url.rstrip("/").split("/")[-1]
                    content_type = (
                        resp.headers.get("Content-Type")
                        or mimetypes.guess_type(resolved_name)[0]
                        or "application/octet-stream"
                    )
                    self._log("INFO", {"http_download_ok": url, "bytes": len(data)})
                    return data, content_type, resolved_name
            except Exception as e:
                last_err = e
                continue

        self._log("ERR", {"http_download_failed": rel_path, "tried": candidate_urls[:6], "error": str(last_err)})
        raise RuntimeError(f"No se encontró en la cámara ({last_err}). URLs probadas: {', '.join(candidate_urls[:3])}")

    def list_dcim_files(self, folder: str = None) -> dict:
        if not self.connected:
            self.connect(sync_clock=False)
        target_dir = f"/tmp/SD0/DCIM/{folder.strip('/')}/" if folder else "/tmp/SD0/DCIM/"
        self._send_and_wait(MSG_CHANGE_DIR, extra={"param": target_dir}, timeout=2.5)
        r = self._send_and_wait(MSG_LIST_DIR, timeout=3.5)

        http_map = self._discover_http_folder_links(folder) if folder else {}

        items = []
        if r.get("msg_id") == MSG_LIST_DIR and "listing" in r:
            for entry in r["listing"]:
                for name, date_str in entry.items():
                    clean_name = name.rstrip("/")
                    is_dir = name.endswith("/")
                    http_url = None
                    if folder and not is_dir:
                        http_url = (
                            http_map.get(clean_name)
                            or http_map.get(clean_name.upper())
                            or f"http://{CAMERA_IP}:{HTTP_PORT}/DCIM/{folder.strip('/')}/{clean_name}"
                        )
                    items.append({
                        "name": clean_name,
                        "is_dir": is_dir,
                        "date": date_str,
                        "url": http_url,
                    })
        if not folder:
            self.dcim_folders = [i["name"] for i in items if i["is_dir"]]
        return {"folder": folder or "", "items": items}

    def _delete_single_path(self, folder: str, filename: str) -> dict:
        """Borra un archivo dentro de una carpeta de DCIM probando con y sin sufijo 'AA'."""
        clean_folder = folder.strip("/")
        variants = self._filename_variants(filename)
        last_resp = {"rval": -1}

        for cand in variants:
            full_path = f"/tmp/SD0/DCIM/{clean_folder}/{cand}"
            resp = self._send_and_wait(MSG_DELETE_FILE, extra={"param": full_path}, timeout=3.0)
            if resp.get("rval") == 0:
                last_resp = resp
            else:
                # Intentar también con ruta relativa dentro de la carpeta
                self._send_and_wait(MSG_CHANGE_DIR, extra={"param": f"/tmp/SD0/DCIM/{clean_folder}/"}, timeout=2.0)
                rel_resp = self._send_and_wait(MSG_DELETE_FILE, extra={"param": cand}, timeout=3.0)
                if rel_resp.get("rval") == 0:
                    last_resp = rel_resp
                elif last_resp.get("rval", -1) < 0:
                    last_resp = resp

        return last_resp

    def delete_file(self, folder: str, filename: str) -> dict:
        if not self.connected:
            self.connect(sync_clock=False)
        resp = self._delete_single_path(folder, filename)
        self._send_and_wait(MSG_GET_STORAGE, timeout=2.5)
        self._send_and_wait(MSG_GET_DEVICE, timeout=2.5)
        return {
            "deleted": filename,
            "response": resp,
            "files": self.list_dcim_files(folder),
            "status": self.get_full_status(),
        }

    def delete_folder(self, folder: str) -> dict:
        """Lista todos los archivos dentro de la carpeta, los borra uno por uno y limpia la carpeta."""
        if not self.connected:
            self.connect(sync_clock=False)
        clean_folder = folder.strip("/")
        listing = self.list_dcim_files(clean_folder).get("items", [])
        deleted_count = 0
        errors = []

        for item in listing:
            if not item.get("is_dir"):
                r = self._delete_single_path(clean_folder, item["name"])
                if r.get("rval") == 0:
                    deleted_count += 1
                else:
                    errors.append({item["name"]: r})

        # Intentar borrar también el directorio vacío en DCIM
        self._send_and_wait(MSG_CHANGE_DIR, extra={"param": "/tmp/SD0/DCIM/"}, timeout=2.0)
        self._send_and_wait(MSG_DELETE_FILE, extra={"param": f"/tmp/SD0/DCIM/{clean_folder}"}, timeout=2.0)
        self._send_and_wait(MSG_DELETE_FILE, extra={"param": f"{clean_folder}/"}, timeout=2.0)

        # Actualizar lista de carpetas y almacenamiento
        self.list_dcim_files(None)
        self._send_and_wait(MSG_GET_STORAGE, timeout=2.5)
        self._send_and_wait(MSG_GET_DEVICE, timeout=2.5)

        if clean_folder in self.dcim_folders and deleted_count >= len(listing):
            # Si el firmware deja la carpeta vacía hasta reiniciar, quitarla de la vista si quedó vacía
            rem = self.list_dcim_files(clean_folder).get("items", [])
            if not rem and clean_folder in self.dcim_folders:
                self.dcim_folders.remove(clean_folder)

        return {
            "folder": clean_folder,
            "deleted_files": deleted_count,
            "errors": errors,
            "status": self.get_full_status(),
        }

    def choose_local_work_dir(self) -> dict:
        chosen = ask_mac_folder(
            "Selecciona la carpeta de tu Mac donde tienes tus fotos/carpetas 360°:",
            default_dir=self.local_work_dir,
        )
        if chosen is None:
            return {"ok": True, "cancelled": True, "local_work_dir": str(self.local_work_dir)}
        self.local_work_dir = chosen
        self.last_user_save_dir = chosen
        return {"ok": True, "cancelled": False, "local_work_dir": str(self.local_work_dir)}

    def save_single_file_to_mac(self, source: str, folder: str, filename: str, do_stitch: bool = False) -> dict:
        """
        Pregunta siempre al usuario en qué carpeta y con qué nombre guardar un archivo individual
        (tanto desde la tarjeta microSD de la cámara como desde el visor/procesador local).
        """
        import fix_photo_dates
        import stitch_photos

        clean_name = filename.strip("/")
        if clean_name.upper().endswith("AA.JPG"):
            clean_name = clean_name[:-6] + ".JPG"

        suggested_name = clean_name
        if do_stitch and suggested_name.upper().endswith(".JPG") and not suggested_name.upper().endswith("_360.JPG"):
            suggested_name = suggested_name[:-4] + "_360.JPG"

        prompt_msg = f"Elige dónde guardar '{suggested_name}' en tu Mac:"
        dest_file = ask_mac_save_file(prompt_msg, suggested_name, default_dir=self.last_user_save_dir)
        if dest_file is None:
            return {"ok": True, "cancelled": True}

        self.last_user_save_dir = dest_file.parent

        if source == "local":
            base_dir = self.local_work_dir.resolve()
            target_dir = base_dir if folder in ("", ".") else (base_dir / folder).resolve()
            src_path = (target_dir / filename).resolve()
            if not src_path.exists():
                raise RuntimeError(f"Archivo local no encontrado: {src_path}")
            data = src_path.read_bytes()
            if do_stitch and src_path.name.upper().endswith(".JPG") and not src_path.name.upper().endswith("_360.JPG"):
                pre_360 = src_path.with_name(src_path.stem + "_360.JPG")
                if pre_360.exists():
                    data = pre_360.read_bytes()
                else:
                    data, _ = stitch_photos.process_photo_bytes(data)
        else:
            if not self.connected:
                self.connect(sync_clock=False)
            data, _, _ = self.fetch_camera_media(f"{folder.strip('/')}/{filename}")
            if do_stitch and clean_name.upper().endswith(".JPG"):
                data, _ = stitch_photos.process_photo_bytes(data)

        dest_file.parent.mkdir(parents=True, exist_ok=True)
        dest_file.write_bytes(data)

        cam_dt = fix_photo_dates.parse_camera_dt_from_filename(clean_name)
        if cam_dt:
            fix_photo_dates.set_macos_file_dates(dest_file, cam_dt)

        return {
            "ok": True,
            "cancelled": False,
            "saved_path": str(dest_file),
            "filename": dest_file.name,
        }

    def download_folder_to_mac(self, folder: str, stitch_mode: str = "360") -> dict:
        """
        Pregunta siempre al usuario mediante el selector nativo de Finder en qué carpeta de su Mac
        desea guardar la carpeta de la microSD, y descarga/procesa sus archivos allí.
        stitch_mode:
          - "360": Guarda únicamente la versión procesada 360° (_360.JPG con EXIF + XMP GPano) para fotos, y MP4 directo.
          - "both": Guarda tanto el archivo original (.JPG) como la versión procesada (_360.JPG).
          - "raw": Guarda únicamente el archivo original sin procesar.
        """
        import fix_photo_dates
        import stitch_photos

        clean_folder = folder.strip("/")
        chosen_parent = ask_mac_folder(
            f"Elige en qué carpeta de tu Mac guardar la carpeta '{clean_folder}':",
            default_dir=self.last_user_save_dir,
        )
        if chosen_parent is None:
            return {"ok": True, "cancelled": True, "folder": clean_folder}

        self.last_user_save_dir = chosen_parent
        self.local_work_dir = chosen_parent

        if not self.connected:
            self.connect(sync_clock=False)
        listing = self.list_dcim_files(clean_folder).get("items", [])

        dest_dir = chosen_parent if chosen_parent.name == clean_folder else (chosen_parent / clean_folder)
        dest_dir.mkdir(parents=True, exist_ok=True)

        downloaded = []
        stitched_360 = []
        errors = []
        for item in listing:
            if item.get("is_dir"):
                continue
            fname = item["name"]
            try:
                data, _, resolved_name = self.fetch_camera_media(f"{clean_folder}/{fname}")
                # Normalizar nombre quitando el sufijo interno AA de Ambarella (ej. IMG_...AA.JPG -> IMG_....JPG)
                clean_name = resolved_name
                if clean_name.upper().endswith("AA.JPG"):
                    clean_name = clean_name[:-6] + ".JPG"
                elif clean_name.upper().endswith(".JPG"):
                    clean_name = clean_name[:-4] + ".JPG"

                cam_dt = fix_photo_dates.parse_camera_dt_from_filename(clean_name)
                is_jpg = clean_name.upper().endswith(".JPG")

                if is_jpg:
                    if stitch_mode in ("raw", "both"):
                        raw_file = dest_dir / clean_name
                        raw_file.write_bytes(data)
                        if cam_dt:
                            fix_photo_dates.set_macos_file_dates(raw_file, cam_dt)
                        downloaded.append(clean_name)

                    if stitch_mode in ("360", "both"):
                        out_360_name = clean_name[:-4] + "_360.JPG"
                        out_360_file = dest_dir / out_360_name
                        stitched_bytes, info = stitch_photos.process_photo_bytes(data)
                        out_360_file.write_bytes(stitched_bytes)
                        if cam_dt:
                            fix_photo_dates.set_macos_file_dates(out_360_file, cam_dt)
                        downloaded.append(out_360_name)
                        stitched_360.append({"file": out_360_name, "mode": info.get("mode")})
                else:
                    dest_file = dest_dir / clean_name
                    dest_file.write_bytes(data)
                    if cam_dt:
                        fix_photo_dates.set_macos_file_dates(dest_file, cam_dt)
                    downloaded.append(clean_name)
            except Exception as e:
                errors.append({fname: str(e)})

        if not downloaded and not any(dest_dir.iterdir()):
            try:
                dest_dir.rmdir()
            except Exception:
                pass

        return {
            "cancelled": False,
            "folder": clean_folder,
            "dest_dir": str(dest_dir),
            "stitch_mode": stitch_mode,
            "downloaded": downloaded,
            "stitched_360": stitched_360,
            "errors": errors,
        }

    def get_full_status(self) -> dict:
        dev = self.device_state
        cam = self.camera_state
        sto = self.storage_state

        raw_shutter = dev.get("still_shutter", 0)
        shutter_str = decode_shutter(raw_shutter)
        iso_val = decode_iso(dev.get("still_iso", 0))
        batt = decode_battery(dev.get("battery", 0))

        sd_total_gb = round(sto.get("sd_total", 0) / (1024 * 1024), 2) if sto.get("sd_total") else 0
        sd_free_gb = round(sto.get("sd_free", 0) / (1024 * 1024), 2) if sto.get("sd_free") else 0

        return {
            "connected": self.connected,
            "local_ip": get_local_ip_for_camera(),
            "camera_ip": CAMERA_IP,
            "token": self.token,
            "product": dev.get("product", "MJXJ-010135"),
            "serial": dev.get("sn", ""),
            "firmware": dev.get("ver", ""),
            "battery": batt,
            "live": {
                "running": self.live_running,
                "frame_id": self.live_frame_id,
                "active_stream": bool(self.live_running and (time.time() - self.live_frame_time < 3.0)),
                "transport": self.live_transport,
                "error": self.live_error,
            },
            "storage": {
                "sd_total_gb": sd_total_gb,
                "sd_free_gb": sd_free_gb,
                "remain_jpg": sto.get("remain_jpg", 0),
                "remain_video_sec": sto.get("remain_video", 0),
                "cam_jpg": dev.get("cam_jpg", 0),
                "cam_mp4": dev.get("cam_mp4", 0),
            },
            "current": {
                "mode": cam.get("mode", 1),
                "sub_mode": cam.get("sub_mode", 0),
                "recording_status": cam.get("status", 0),
                "photo": {
                    "p_res": dev.get("p_res", 0),
                    "wb": dev.get("still_wb", 0),
                    "iso": iso_val,
                    "shutter_raw": encode_shutter(shutter_str),
                    "shutter_str": shutter_str,
                    "ev_raw": dev.get("still_ev", 0),
                    "ev": dev.get("still_ev", 0) / 2.0,
                    "timer_sec": cam.get("timing", 3),
                    "interval_sec": cam.get("cap_interval", 5),
                    "bracketing_raw": cam.get("surroundexp", 0),
                    "bracketing_ev": cam.get("surroundexp", 0) / 2.0,
                },
                "video": {
                    "v_res": dev.get("v_res", 1),
                    "wb": dev.get("video_wb", 0),
                    "ev_raw": dev.get("video_ev", 0),
                    "ev": dev.get("video_ev", 0) / 2.0,
                    "short_sec": cam.get("second", 10),
                    "timelapse_sec": cam.get("lapse", 1),
                    "slowmo_rate": cam.get("speedx", 2),
                },
                "system": {
                    "buzzer": dev.get("buzzer", 4),
                    "led": dev.get("led", 1),
                    "poweroff_time": dev.get("poweroff_time", 10),
                },
            },
            "options": {
                "photo_res": PHOTO_RES_OPTIONS,
                "video_res": VIDEO_RES_OPTIONS,
                "wb": WB_OPTIONS,
                "iso": ISO_OPTIONS,
                "shutter": SHUTTER_OPTIONS,
                "ev": EV_OPTIONS,
                "timer": [0, 3, 4, 5, 6, 7, 8, 9, 10],
                "interval": [0, 2, 5, 10, 30, 60, 120, 300],
                "bracketing": [
                    {"raw": 0, "label": "Desactivado"},
                    {"raw": 1, "label": "±0.5 EV"},
                    {"raw": 2, "label": "±1.0 EV"},
                    {"raw": 3, "label": "±1.5 EV"},
                    {"raw": 4, "label": "±2.0 EV"},
                    {"raw": 5, "label": "±2.5 EV"},
                    {"raw": 6, "label": "±3.0 EV"},
                ],
                "short_video": [0, 10, 20, 30],
                "timelapse": [
                    {"raw": 0, "label": "Desactivado"},
                    {"raw": 255, "label": "0.5 s"},
                    {"raw": 1, "label": "1 s"},
                    {"raw": 2, "label": "2 s"},
                    {"raw": 5, "label": "5 s"},
                    {"raw": 10, "label": "10 s"},
                    {"raw": 30, "label": "30 s"},
                    {"raw": 60, "label": "60 s"},
                ],
                "slowmo": [
                    {"raw": 0, "label": "Desactivado"},
                    {"raw": 2, "label": "2x Slow Motion"},
                ],
            },
            "dcim_folders": list(reversed(self.dcim_folders)),
            "logs": self.logs[-40:],
        }
