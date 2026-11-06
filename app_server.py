#!/usr/bin/env python3
"""
Servidor Web local (http://localhost:8080) para el Panel de Control de la Xiaomi Mi Sphere 360.
Permite controlar todos los ajustes de Foto y Video en tiempo real desde el navegador en Mac.
"""

from __future__ import annotations

import json
import mimetypes
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from misphere_controller import (
    CAMERA_IP,
    HTTP_PORT,
    MSG_AUTO_TURN_OFF,
    MSG_GYRO_CALIB,
    MSG_PHOTO_EV,
    MSG_PHOTO_ISO,
    MSG_PHOTO_LONGPRESS,
    MSG_PHOTO_PRESS,
    MSG_PHOTO_RES,
    MSG_PHOTO_SHUTTER,
    MSG_PHOTO_WB,
    MSG_SET_BUZZER,
    MSG_SET_DATE,
    MSG_SET_LED,
    MSG_SET_PHOTO_BRACKETING,
    MSG_SET_PHOTO_INTERVAL,
    MSG_SET_PHOTO_TIMER,
    MSG_SET_VIDEO_SHORT,
    MSG_SET_VIDEO_SLOWMO,
    MSG_SET_VIDEO_TIMELAPSE,
    MSG_SWITCH_MODE,
    MSG_TURN_OFF,
    MSG_VIDEO_EV,
    MSG_VIDEO_LONGPRESS,
    MSG_VIDEO_REC_START,
    MSG_VIDEO_REC_STOP,
    MSG_VIDEO_RES,
    MSG_VIDEO_WB,
    MiSphereController,
    encode_shutter,
)

STATIC_DIR = Path(__file__).parent / "static"
controller = MiSphereController()

# Mapa de acciones amigables a msg_id
ACTION_MAP = {
    "switch_mode": MSG_SWITCH_MODE,
    "photo_res": MSG_PHOTO_RES,
    "photo_wb": MSG_PHOTO_WB,
    "photo_iso": MSG_PHOTO_ISO,
    "photo_shutter": MSG_PHOTO_SHUTTER,
    "photo_ev": MSG_PHOTO_EV,
    "photo_timer": MSG_SET_PHOTO_TIMER,
    "photo_interval": MSG_SET_PHOTO_INTERVAL,
    "photo_bracketing": MSG_SET_PHOTO_BRACKETING,
    "photo_shutter_press": MSG_PHOTO_PRESS,
    "photo_shutter_long": MSG_PHOTO_LONGPRESS,
    "video_res": MSG_VIDEO_RES,
    "video_wb": MSG_VIDEO_WB,
    "video_ev": MSG_VIDEO_EV,
    "video_short": MSG_SET_VIDEO_SHORT,
    "video_timelapse": MSG_SET_VIDEO_TIMELAPSE,
    "video_slowmo": MSG_SET_VIDEO_SLOWMO,
    "video_start": MSG_VIDEO_REC_START,
    "video_long": MSG_VIDEO_LONGPRESS,
    "video_stop": MSG_VIDEO_REC_STOP,
    "buzzer": MSG_SET_BUZZER,
    "led": MSG_SET_LED,
    "auto_off": MSG_AUTO_TURN_OFF,
    "power_off": MSG_TURN_OFF,
    "gyro_calib": MSG_GYRO_CALIB,
    "sync_date": MSG_SET_DATE,
}


class MiSphereRequestHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Silenciar logs repetitivos de polling y cuadros en vivo
        req_line = args[0] if args else ""
        if "/api/status" not in req_line and "/api/live_frame" not in req_line:
            sys.stderr.write(f"[HTTP] {fmt % args}\n")

    def _send_json(self, data: dict, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/api/status":
            self._send_json({"ok": True, "status": controller.get_full_status()})
            return

        if path == "/api/live_lut":
            import stitch_photos

            try:
                lut_bytes = stitch_photos.get_webgl_lut_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(lut_bytes)))
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                self.wfile.write(lut_bytes)
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=500)
            return

        if path == "/api/live_frame":
            after_id = int(query.get("after", ["0"])[0] or 0)
            if after_id > 0 and controller.live_running:
                frame, fid = controller.wait_for_next_live_frame(after_id, timeout=1.5)
            else:
                frame, fid = controller.get_live_frame()

            if not frame:
                self._send_json({
                    "ok": False,
                    "error": controller.live_error or "Esperando señal RTSP de la cámara (rtsp://192.168.42.1/live)...",
                }, status=503)
                return

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("X-Frame-Id", str(fid))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            self.wfile.write(frame)
            return

        if path == "/api/live_stream":
            if not controller.live_running:
                try:
                    controller.start_live_view()
                except Exception as e:
                    self._send_json({"ok": False, "error": str(e)}, status=503)
                    return

            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            last_id = 0
            try:
                while controller.live_running:
                    frame, fid = controller.wait_for_next_live_frame(last_id, timeout=2.0)
                    if not frame:
                        continue
                    last_id = fid
                    header = (
                        b"--frame\r\n"
                        b"Content-Type: image/jpeg\r\n"
                        + f"Content-Length: {len(frame)}\r\n\r\n".encode("ascii")
                    )
                    self.wfile.write(header)
                    self.wfile.write(frame)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
            except Exception:
                pass
            return

        if path == "/api/files":
            folder = query.get("folder", [""])[0]
            try:
                res = controller.list_dcim_files(folder=folder or None)
                self._send_json({"ok": True, **res})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=500)
            return

        if path == "/api/local_folders":
            if controller.local_work_dir is None:
                self._send_json({
                    "ok": True,
                    "work_dir": "(Elige una carpeta con '📂 Elegir Carpeta en Mac...')",
                    "folders": [],
                })
                return
            try:
                work_dir = controller.local_work_dir.resolve()
                folders_info = []

                # Revisar primero si hay fotos sueltas en la raíz de la carpeta seleccionada
                candidates = [work_dir] + sorted([d for d in work_dir.iterdir() if d.is_dir()])
                for d in candidates:
                    is_root = (d == work_dir)
                    files = sorted([f for f in d.iterdir() if f.is_file()])
                    raw_jpgs = [
                        f.name for f in files
                        if f.suffix.upper() == ".JPG" and not f.name.upper().endswith("_360.JPG")
                    ]
                    stitched_jpgs = [
                        f.name for f in files
                        if f.name.upper().endswith("_360.JPG")
                    ]
                    mp4s = [f.name for f in files if f.suffix.upper() == ".MP4"]
                    if is_root and not (raw_jpgs or stitched_jpgs or mp4s):
                        continue
                    folders_info.append({
                        "name": "." if is_root else d.name,
                        "label": f"Raíz ({work_dir.name}/)" if is_root else d.name,
                        "raw_count": len(raw_jpgs),
                        "stitched_count": len(stitched_jpgs),
                        "video_count": len(mp4s),
                        "raw_photos": raw_jpgs,
                        "stitched_photos": stitched_jpgs,
                        "sample_photo": raw_jpgs[0] if raw_jpgs else (stitched_jpgs[0] if stitched_jpgs else ""),
                    })

                self._send_json({
                    "ok": True,
                    "work_dir": str(work_dir),
                    "folders": folders_info,
                })
            except Exception as e:
                self._send_json({
                    "ok": True,
                    "work_dir": str(controller.local_work_dir),
                    "folders": [],
                    "warning": str(e),
                })
            return

        if path == "/api/local_media":
            import stitch_photos

            if controller.local_work_dir is None:
                self._send_json({"ok": False, "error": "Primero selecciona una carpeta local."}, status=400)
                return
            folder = query.get("folder", ["."])[0]
            filename = query.get("file", [""])[0]
            force_dl = query.get("download", ["0"])[0] == "1"
            do_stitch = query.get("stitch", ["0"])[0] == "1"
            work_dir = controller.local_work_dir.resolve()
            target_dir = work_dir if folder in ("", ".") else (work_dir / folder).resolve()
            if not str(target_dir).startswith(str(work_dir)):
                self.send_error(403, "Acceso denegado")
                return
            file_path = (target_dir / filename).resolve()
            if not str(file_path).startswith(str(work_dir)) or not file_path.exists():
                self.send_error(404, "Archivo local no encontrado")
                return
            try:
                data = file_path.read_bytes()
                out_name = file_path.name
                if do_stitch and out_name.upper().endswith(".JPG") and not out_name.upper().endswith("_360.JPG"):
                    # Si ya existe el archivo _360.JPG en disco, usarlo directamente para respuesta instantánea
                    pre_360 = file_path.with_name(file_path.stem + "_360.JPG")
                    if pre_360.exists():
                        data = pre_360.read_bytes()
                        out_name = pre_360.name
                    else:
                        data, _ = stitch_photos.process_photo_bytes(data)
                        out_name = file_path.stem + "_360.JPG"

                ctype = mimetypes.guess_type(out_name)[0] or "image/jpeg"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                disp = "attachment" if force_dl else "inline"
                self.send_header("Content-Disposition", f'{disp}; filename="{out_name}"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=500)
            return

        if path == "/api/media":
            import stitch_photos

            rel_path = query.get("path", [""])[0].lstrip("/")
            force_dl = query.get("download", ["0"])[0] == "1"
            do_stitch = query.get("stitch", ["0"])[0] == "1"
            if not rel_path:
                self._send_json({"ok": False, "error": "Falta parámetro path"}, status=400)
                return
            try:
                data, content_type, resolved_name = controller.fetch_camera_media(rel_path)
                clean_name = resolved_name
                if clean_name.upper().endswith("AA.JPG"):
                    clean_name = clean_name[:-6] + ".JPG"

                if do_stitch and clean_name.upper().endswith(".JPG"):
                    data, _ = stitch_photos.process_photo_bytes(data)
                    clean_name = clean_name[:-4] + "_360.JPG"
                    content_type = "image/jpeg"

                self.send_response(200)
                self.send_header("Content-Type", content_type)
                if force_dl:
                    self.send_header("Content-Disposition", f'attachment; filename="{clean_name}"')
                else:
                    self.send_header("Content-Disposition", f'inline; filename="{clean_name}"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=502)
            return

        # Servir archivos estáticos
        if path == "/" or path == "":
            file_path = STATIC_DIR / "index.html"
        else:
            file_path = STATIC_DIR / path.lstrip("/")

        if file_path.exists() and file_path.is_file():
            ctype = mimetypes.guess_type(str(file_path))[0] or "text/html; charset=utf-8"
            content = file_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_error(404, "Archivo no encontrado")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        length = int(self.headers.get("Content-Length", "0"))
        body_bytes = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
        except Exception:
            payload = {}

        try:
            if path == "/api/connect":
                sync_clock = payload.get("sync_clock", True)
                status = controller.connect(sync_clock=sync_clock)
                self._send_json({"ok": True, "status": status})
                return

            if path == "/api/disconnect":
                status = controller.disconnect()
                self._send_json({"ok": True, "status": status})
                return

            if path == "/api/refresh":
                status = controller.refresh()
                self._send_json({"ok": True, "status": status})
                return

            if path == "/api/live/start":
                res = controller.start_live_view()
                self._send_json(res)
                return

            if path == "/api/live/stop":
                res = controller.stop_live_view(send_stop_msg=True)
                self._send_json(res)
                return

            if path == "/api/delete_file":
                folder = payload.get("folder", "")
                filename = payload.get("filename", "")
                if not folder or not filename:
                    self._send_json({"ok": False, "error": "Se requiere folder y filename"}, status=400)
                    return
                res = controller.delete_file(folder, filename)
                self._send_json({"ok": True, **res})
                return

            if path == "/api/delete_folder":
                folder = payload.get("folder", "")
                if not folder:
                    self._send_json({"ok": False, "error": "Se requiere folder"}, status=400)
                    return
                res = controller.delete_folder(folder)
                self._send_json({"ok": True, **res})
                return

            if path == "/api/choose_local_dir":
                res = controller.choose_local_work_dir()
                self._send_json(res)
                return

            if path == "/api/save_file_dialog":
                source = payload.get("source", "sd")
                folder = payload.get("folder", "")
                filename = payload.get("filename", "")
                do_stitch = bool(payload.get("stitch", False))
                if not filename:
                    self._send_json({"ok": False, "error": "Se requiere filename"}, status=400)
                    return
                res = controller.save_single_file_to_mac(
                    source=source,
                    folder=folder,
                    filename=filename,
                    do_stitch=do_stitch,
                )
                self._send_json(res)
                return

            if path == "/api/download_folder":
                folder = payload.get("folder", "")
                stitch_mode = payload.get("stitch_mode", "360")
                if not folder:
                    self._send_json({"ok": False, "error": "Se requiere folder"}, status=400)
                    return
                res = controller.download_folder_to_mac(folder, stitch_mode=stitch_mode)
                self._send_json({"ok": True, **res})
                return

            if path == "/api/local_stitch":
                import stitch_photos
                from misphere_controller import ask_mac_folder

                if controller.local_work_dir is None:
                    pick = controller.choose_local_work_dir()
                    if pick.get("cancelled") or controller.local_work_dir is None:
                        self._send_json({"ok": True, "cancelled": True})
                        return

                target_folder = payload.get("folder", "ALL")
                overwrite = bool(payload.get("overwrite", True))
                work_dir = controller.local_work_dir.resolve()

                if target_folder == "ALL":
                    dirs = [work_dir] + sorted([d for d in work_dir.iterdir() if d.is_dir()])
                    default_dest = work_dir
                elif target_folder == ".":
                    dirs = [work_dir]
                    default_dest = work_dir
                else:
                    dirs = [work_dir / target_folder]
                    default_dest = work_dir / target_folder

                chosen_out_base = ask_mac_folder(
                    f"Elige en qué carpeta guardar las fotos 360° procesadas ({target_folder}):",
                    default_dir=default_dest if default_dest.exists() else work_dir,
                )
                if chosen_out_base is None:
                    self._send_json({"ok": True, "cancelled": True})
                    return

                controller.last_user_save_dir = chosen_out_base

                stitched_dual = 0
                tagged_incam = 0
                skipped = 0
                errors = []

                for d in dirs:
                    if not d.exists() or not d.is_dir():
                        continue
                    src_files = [
                        f for f in sorted(d.iterdir())
                        if f.is_file() and f.suffix.upper() == ".JPG" and not f.name.upper().endswith("_360.JPG")
                    ]
                    if not src_files:
                        continue

                    if target_folder == "ALL" and d != work_dir and chosen_out_base.name != d.name:
                        out_dir = chosen_out_base / d.name
                    else:
                        out_dir = chosen_out_base
                    out_dir.mkdir(parents=True, exist_ok=True)

                    for f in src_files:
                        out_f = out_dir / (f.stem + "_360.JPG")
                        if out_f.exists() and not overwrite:
                            skipped += 1
                            continue
                        try:
                            info = stitch_photos.stitch_single_photo(f, out_f)
                            if info.get("mode") == "dual_fisheye":
                                stitched_dual += 1
                            else:
                                tagged_incam += 1
                        except Exception as e:
                            errors.append({f.name: str(e)})

                self._send_json({
                    "ok": True,
                    "cancelled": False,
                    "folder": target_folder,
                    "dest_dir": str(chosen_out_base),
                    "stitched_dual_fisheye": stitched_dual,
                    "tagged_in_camera": tagged_incam,
                    "skipped": skipped,
                    "total_processed": stitched_dual + tagged_incam,
                    "errors": errors,
                })
                return

            if path == "/api/local_fix_dates":
                import fix_photo_dates

                folders = payload.get("folders", [])
                ref_filename = payload.get("ref_filename", "")
                ref_real_dt = payload.get("ref_real_dt", "")
                if not folders or not ref_filename or not ref_real_dt:
                    self._send_json({
                        "ok": False,
                        "error": "Selecciona al menos una carpeta, la foto de referencia y su fecha/hora real.",
                    }, status=400)
                    return
                res = fix_photo_dates.fix_local_folders_by_reference(
                    folders,
                    ref_filename,
                    ref_real_dt,
                    base_dir=controller.local_work_dir,
                )
                self._send_json(res, status=200 if res.get("ok") else 400)
                return

            if path == "/api/command":
                action = payload.get("action")
                msg_id = payload.get("msg_id")
                param = payload.get("param")

                if action and not msg_id:
                    msg_id = ACTION_MAP.get(action)
                if not msg_id:
                    self._send_json({"ok": False, "error": f"Acción o msg_id inválido: {action}"}, status=400)
                    return

                msg_id = int(msg_id)
                if action == "photo_shutter" and isinstance(param, str):
                    param = encode_shutter(param)

                result = controller.send_command(msg_id=msg_id, param=param)
                self._send_json({"ok": True, **result})
                return

            self._send_json({"ok": False, "error": "Ruta no soportada"}, status=404)
        except Exception as e:
            self._send_json({
                "ok": False,
                "error": str(e),
                "status": controller.get_full_status(),
            }, status=500)


def main():
    import signal

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(("127.0.0.1", port), MiSphereRequestHandler)

    def _handle_sigterm(signum, frame):
        try:
            controller.disconnect()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_sigterm)

    print("=" * 68, flush=True)
    print(f"🎛️  Panel de Control Xiaomi Mi Sphere 360 activo en:", flush=True)
    print(f"👉  http://localhost:{port}", flush=True)
    print("=" * 68, flush=True)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        print("\nCerrando servidor y desconectando cámara...", flush=True)
        try:
            controller.disconnect()
        except Exception:
            pass
        server.server_close()


if __name__ == "__main__":
    main()
