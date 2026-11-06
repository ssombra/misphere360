#!/usr/bin/env python3
"""
Corrige las fechas de carpetas, nombres de archivo, metadatos EXIF internos
y fechas de sistema (macOS Finder) para las fotos con reloj reiniciado en 2014.

Foto de referencia:
  IMG_20140105_120341.JPG  (2014-01-05 12:03:41)
  Fecha/hora real:          2026-10-22 15:48:41  (Delta = +4673 días, +3h 45m)
"""

from __future__ import annotations

import os
import re
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

DESCARGAS_DIR = Path(__file__).parent / "Descargas"

REF_CAMERA_DT = datetime(2014, 1, 5, 12, 3, 41)
REF_REAL_DT = datetime(2026, 10, 22, 15, 48, 41)
DELTA = REF_REAL_DT - REF_CAMERA_DT

TARGET_FOLDERS = ["20140105", "20140106", "20140108"]


def patch_jpeg_exif_dates(data: bytes, new_dt: datetime) -> tuple[bytes, int]:
    """
    Reemplaza en la cabecera EXIF (primeros 64 KB) todas las cadenas de fecha
    '20YY:MM:DD HH:MM:SS' (19 bytes exactos) por la nueva fecha corregida,
    preservando intactos los datos JPEG y los metadatos XMP 360° (GPano).
    """
    header_limit = min(len(data), 65536)
    header = data[:header_limit]
    rest = data[header_limit:]

    new_exif_str = new_dt.strftime("%Y:%m:%d %H:%M:%S").encode("ascii")
    assert len(new_exif_str) == 19

    pattern = re.compile(rb"20\d{2}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}")
    matches = list(pattern.finditer(header))
    if not matches:
        return data, 0

    patched_header = pattern.sub(new_exif_str, header)
    return patched_header + rest, len(matches)


def set_macos_file_dates(filepath: Path, dt: datetime):
    """Actualiza atime, mtime y fecha de creación en macOS."""
    ts = dt.timestamp()
    os.utime(filepath, (ts, ts))
    touch_str = dt.strftime("%Y%m%d%H%M.%S")
    try:
        subprocess.run(["touch", "-t", touch_str, str(filepath)], check=False)
    except Exception:
        pass


def parse_camera_dt_from_filename(filename: str) -> datetime | None:
    m = re.match(r"^(?:IMG|VID)_(\d{8})_(\d{6})", Path(filename).name, flags=re.IGNORECASE)
    if not m:
        return None
    return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")


def fix_local_folders_by_reference(
    folder_names: list[str],
    ref_filename: str,
    ref_real_str: str,
    base_dir: Path | None = None,
) -> dict:
    """
    Calcula el desfase de reloj a partir de ref_filename y ref_real_str ('YYYY-MM-DD HH:MM' o 'YYYY-MM-DD HH:MM:SS'),
    y corrige nombres de carpeta, nombres de archivo, fechas EXIF y fechas de Finder en las carpetas indicadas.
    """
    target_base = Path(base_dir).resolve() if base_dir else DESCARGAS_DIR.resolve()
    ref_cam_dt = parse_camera_dt_from_filename(ref_filename)
    if not ref_cam_dt:
        return {"ok": False, "error": f"No se pudo extraer fecha/hora del nombre: {ref_filename}"}

    ref_real_str = ref_real_str.strip().replace("T", " ")
    try:
        if len(ref_real_str) == 16:  # YYYY-MM-DD HH:MM -> conservar los segundos originales de la foto
            base_dt = datetime.strptime(ref_real_str, "%Y-%m-%d %H:%M")
            ref_real_dt = base_dt.replace(second=ref_cam_dt.second)
        else:
            ref_real_dt = datetime.strptime(ref_real_str, "%Y-%m-%d %H:%M:%S")
    except ValueError as e:
        return {"ok": False, "error": f"Formato de fecha real inválido ({ref_real_str}): {e}"}

    delta = ref_real_dt - ref_cam_dt
    total_files = 0
    renamed_folders = []

    for old_folder_name in folder_names:
        is_root = (old_folder_name == ".")
        old_folder = target_base if is_root else (target_base / old_folder_name)
        if not old_folder.exists() or not old_folder.is_dir():
            continue

        files = sorted(
            [f for f in old_folder.iterdir() if f.is_file() and f.suffix.upper() in (".JPG", ".MP4")]
        )
        if not files:
            continue

        target_folder_names = set()
        for f in files:
            m = re.match(r"^(IMG|VID)_(\d{8})_(\d{6})(.*)\.(JPG|MP4)$", f.name, flags=re.IGNORECASE)
            if not m:
                continue
            prefix, old_date_part, old_time_part, suffix, ext = (
                m.group(1).upper(),
                m.group(2),
                m.group(3),
                m.group(4),
                m.group(5).upper(),
            )
            cam_dt = datetime.strptime(old_date_part + old_time_part, "%Y%m%d%H%M%S")
            real_dt = cam_dt + delta

            new_date_part = real_dt.strftime("%Y%m%d")
            new_time_part = real_dt.strftime("%H%M%S")
            target_folder_names.add(new_date_part)
            new_filename = f"{prefix}_{new_date_part}_{new_time_part}{suffix}.{ext}"

            new_folder_path = target_base if is_root else (target_base / new_date_part)
            new_folder_path.mkdir(parents=True, exist_ok=True)
            new_file_path = new_folder_path / new_filename

            if ext == "JPG":
                raw_bytes = f.read_bytes()
                patched_bytes, _ = patch_jpeg_exif_dates(raw_bytes, real_dt)
                new_file_path.write_bytes(patched_bytes)
            else:
                if new_file_path.resolve() != f.resolve():
                    f.rename(new_file_path)

            set_macos_file_dates(new_file_path, real_dt)
            if new_file_path.resolve() != f.resolve() and f.exists():
                f.unlink()

            total_files += 1

        if not is_root and old_folder.exists() and not any(old_folder.iterdir()):
            old_folder.rmdir()
            renamed_folders.append(f"{old_folder_name} → {', '.join(sorted(target_folder_names))}")

    return {
        "ok": True,
        "corrected_files": total_files,
        "renamed_folders": renamed_folders,
        "delta_seconds": int(delta.total_seconds()),
    }


def main():
    res = fix_local_folders_by_reference(
        TARGET_FOLDERS,
        "IMG_20140105_120341.JPG",
        REF_REAL_DT.strftime("%Y-%m-%d %H:%M:%S"),
    )
    print(res)


if __name__ == "__main__":
    main()
