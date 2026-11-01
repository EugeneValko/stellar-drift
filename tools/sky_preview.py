#!/usr/bin/env python3
"""Turn a raw baked sky atlas (float16 RGBA, 3x2 equi-angular cube faces, dumped by
src/space/space_sky.gd with --dump_sky=<file>) into an equirectangular PNG preview.

  python3 tools/sky_preview.py atlas.bin <face_size> out.png [--exposure=1.0] [--width=2048]
Requires numpy + ffmpeg (for PNG encoding)."""
import subprocess
import sys

import numpy as np


def face_basis():
    return [
        ((1, 0, 0), (0, 0, -1), (0, 1, 0)),
        ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
        ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
        ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
        ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
        ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
    ]


def main():
    src, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    opts = dict(a[2:].split("=") for a in sys.argv[4:] if a.startswith("--"))
    exposure = float(opts.get("exposure", 1.0))
    w = int(opts.get("width", 2048))
    h = w // 2
    atlas = np.fromfile(src, dtype=np.float16).astype(np.float32).reshape(2 * n, 3 * n, 4)
    lon = (np.arange(w) + 0.5) / w * 2 * np.pi - np.pi
    lat = np.pi / 2 - (np.arange(h) + 0.5) / h * np.pi
    lon, lat = np.meshgrid(lon, lat)
    d = np.stack([np.cos(lat) * np.sin(lon), np.sin(lat), -np.cos(lat) * np.cos(lon)], -1)
    a = np.abs(d)
    face = np.where((a[..., 0] >= a[..., 1]) & (a[..., 0] >= a[..., 2]), np.where(d[..., 0] > 0, 0, 1),
                    np.where(a[..., 1] >= a[..., 2], np.where(d[..., 1] > 0, 2, 3), np.where(d[..., 2] > 0, 4, 5)))
    img = np.zeros((h, w, 3), np.float32)
    for f, (N, U, V) in enumerate(face_basis()):
        m = face == f
        dd = d[m]
        dn = dd @ np.array(N, np.float32)
        u = (dd @ np.array(U, np.float32)) / dn
        v = (dd @ np.array(V, np.float32)) / dn
        s = np.arctan(u) * 4 / np.pi
        t = np.arctan(v) * 4 / np.pi
        x = ((s * 0.5 + 0.5) * (n - 1)).round().astype(int) + (f % 3) * n
        y = ((t * 0.5 + 0.5) * (n - 1)).round().astype(int) + (f // 3) * n
        img[m] = atlas[y, x, :3]
    img = img * exposure
    img = img / (1 + img)  # simple Reinhard for preview
    img = np.clip(img, 0, 1) ** (1 / 2.2)
    rgb = (img * 255 + 0.5).astype(np.uint8)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                    "-s", f"{w}x{h}", "-i", "-", out], input=rgb.tobytes(), check=True)
    print("[sky_preview]", out)


if __name__ == "__main__":
    main()
