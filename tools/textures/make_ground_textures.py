"""Seamless near-ground detail textures for shaders/planet_terrain.gdshader (and rock_scatter).

Run (any Python 3 with numpy + Pillow):
    python3 tools/textures/make_ground_textures.py assets/textures

Outputs (1024x1024, tile seamlessly, sampled at power-of-two tile sizes in metres):
  ground_detail.png  RGBA8
      r  stone / pebble height (0 = soil, domed cobbles up to 1; mixed sizes, ~45 % cover)
      g  per-stone random id (colour variation); soil = 0.5
      b  crack network (1 on the crack: mud cracks, basalt joints, ice crevasses, ~7 cells per tile)
      a  grit (fine fbm, 0.5 mean)
  ground_normal.png  RGB8 tangent-space normal map (+Z up) of stones + grit - cracks
  ripples.png        RGBA8
      r  wind ripples / sastrugi height (stretched along +x, wavy), g  dune-scale ripples,
      b  fbm (broad), a  sparkle seeds (sparse bright texels, for snow / sand glints)
  ripples_normal.png RGB8 normal map of fine ripples (+ a little broad fbm)
  dunes_normal.png   RGB8 normal map of asymmetric dune / sastrugi crests + broad fbm (no fine ripples)
"""
import os
import sys

import numpy as np
from PIL import Image

N = 1024
rng = np.random.default_rng(20261101)


def fft_noise(beta, fmin=1, fmax=None, seed=0):
    """Periodic coloured noise via FFT (perfectly seamless), normalised to 0..1."""
    r = np.random.default_rng(seed)
    fx = np.fft.fftfreq(N) * N
    fy = np.fft.rfftfreq(N) * N
    f = np.sqrt(fx[:, None] ** 2 + fy[None, :] ** 2)
    amp = np.zeros_like(f)
    m = f >= fmin
    if fmax:
        m &= f <= fmax
    amp[m] = 1.0 / f[m] ** beta
    ph = r.standard_normal(f.shape) + 1j * r.standard_normal(f.shape)
    img = np.fft.irfft2(amp * ph, s=(N, N))
    img -= img.min()
    return img / img.max()


def voronoi(cells, seed, jitter=0.9, warp=None, want_offset=False):
    """Periodic Voronoi on a cells x cells grid. Returns F1, F2 (in cell units) and cell value."""
    r = np.random.default_rng(seed)
    pts = r.random((cells, cells, 2)) * jitter + (1 - jitter) * 0.5
    val = r.random((cells, cells))
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)
    u = xx / N * cells
    v = yy / N * cells
    if warp is not None:
        u = u + warp[0]
        v = v + warp[1]
    iu = np.floor(u).astype(int)
    iv = np.floor(v).astype(int)
    fu = u - iu
    fv = v - iv
    f1 = np.full((N, N), 9.0)
    f2 = np.full((N, N), 9.0)
    cv = np.zeros((N, N))
    ox = np.zeros((N, N))
    oy = np.zeros((N, N))
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cx = (iu + dx) % cells
            cy = (iv + dy) % cells
            p = pts[cy, cx]
            ex = dx + p[..., 0] - fu
            ey = dy + p[..., 1] - fv
            d = np.sqrt(ex * ex + ey * ey)
            closer = d < f1
            ox = np.where(closer, ex, ox)
            oy = np.where(closer, ey, oy)
            f2 = np.where(closer, f1, np.minimum(f2, d))
            cv = np.where(closer, val[cy, cx], cv)
            f1 = np.where(closer, d, f1)
    if want_offset:
        return f1, f2, cv, ox, oy
    return f1, f2, cv


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def normal_map(h, strength):
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5 * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5 * strength
    nz = 1.0 / np.sqrt(dx * dx + dy * dy + 1.0)
    # image rows go down; the shader uses uv.y = row / N, so +v = +row
    nx = -dx * nz
    ny = -dy * nz
    return np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5], axis=-1)


def stones_layer(cells, seed, cover, flat, warp_amp):
    """Rounded, slightly irregular stones on soil: dome on the warped F1 distance, clipped by the
    cell border (neighbouring stones may touch but never overlap)."""
    w1 = (fft_noise(2.4, 2, 96, seed + 1) - 0.5) * warp_amp
    w2 = (fft_noise(2.4, 2, 96, seed + 2) - 0.5) * warp_amp
    f1, f2, cv, ox, oy = voronoi(cells, seed, 0.85, (w1, w2), True)
    present = cv < cover
    rad = 0.22 + 0.22 * ((cv * 7.13) % 1.0)
    # elliptical, lobed outline: random orientation / aspect / 3-lobe wobble per stone
    ang = (cv * 17.31) % 1.0 * np.pi
    asp = 1.0 + 0.9 * ((cv * 5.77) % 1.0)
    ca, sa = np.cos(ang), np.sin(ang)
    ea = ox * ca + oy * sa
    eb = (-ox * sa + oy * ca) * asp
    de = np.sqrt(ea * ea + eb * eb)
    theta = np.arctan2(eb, ea)
    lobe = 1.0 + 0.09 * np.sin(3.0 * theta + cv * 40.0) + 0.05 * np.sin(5.0 * theta + cv * 77.0)
    t = np.clip(de / (rad * lobe), 0.0, 1.0)
    dome = np.sqrt(np.clip(1.0 - t ** (2.0 + flat * 4.0), 0.0, 1.0))
    dome *= smoothstep(0.0, 0.08, f2 - f1)          # never across a cell border
    dome *= 0.45 + 0.55 * ((cv * 3.7) % 1.0)         # per-stone height
    h = np.where(present, dome, 0.0)
    ident = np.where(present, (cv * 11.3) % 1.0, -1.0)
    return h, ident


def main():
    out = sys.argv[-1] if len(sys.argv) > 1 else "assets/textures"
    os.makedirs(out, exist_ok=True)

    grit = fft_noise(1.1, 24, None, 7)
    grit = (grit - grit.mean()) / (grit.std() * 6.0) + 0.5
    grit = np.clip(grit, 0.0, 1.0)
    soil = fft_noise(1.8, 4, None, 8)

    hb, ib = stones_layer(16, 101, 0.30, 0.6, 0.55)   # cobbles (~22 cm at a 4 m tile)
    hs, is_ = stones_layer(48, 202, 0.30, 0.4, 0.5)  # pebbles (~7 cm)
    ht, it = stones_layer(128, 303, 0.35, 0.2, 0.4)     # grit stones (~3 cm)
    stones = np.maximum(hb, np.maximum(hs * 0.6, ht * 0.32))
    ident = np.where(hb >= np.maximum(hs * 0.6, ht * 0.32), ib, np.where(hs * 0.6 >= ht * 0.32, is_, it))
    ident = np.where(stones > 0.01, np.clip(ident, 0, 1), 0.5)

    # crack network (mud cracks / joints): coarse warped voronoi borders
    w1 = (fft_noise(2.0, 2, 48, 11) - 0.5) * 0.5
    w2 = (fft_noise(2.0, 2, 48, 12) - 0.5) * 0.5
    f1, f2, _ = voronoi(7, 404, 0.9, (w1, w2))
    crack = 1.0 - smoothstep(0.0, 0.05, f2 - f1)
    f1b, f2b, _ = voronoi(19, 405, 0.9, (w1 * 1.5, w2 * 1.5))
    crack = np.maximum(crack, (1.0 - smoothstep(0.0, 0.06, f2b - f1b)) * 0.6 * smoothstep(0.35, 0.65, soil))

    det = np.stack([stones, ident, crack, grit], axis=-1)
    Image.fromarray((np.clip(det, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(
        os.path.join(out, "ground_detail.png"))

    h = stones * 1.0 + (grit - 0.5) * 0.22 + (soil - 0.5) * 0.3 - crack * 0.25
    nm = normal_map(h, 26.0)
    Image.fromarray((np.clip(nm, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(
        os.path.join(out, "ground_normal.png"))

    # --- ripples / sastrugi: stretched along x, wavy crests ---
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float64) / N
    warp = fft_noise(2.0, 1, 16, 21)
    warp2 = fft_noise(2.0, 2, 32, 22)
    rip = np.sin(2 * np.pi * (yy * 48 + (warp - 0.5) * 6.0 + (warp2 - 0.5) * 1.5 + xx * 0))
    rip = 0.5 + 0.5 * np.sign(rip) * np.abs(rip) ** 0.7
    rip = rip * (0.6 + 0.4 * fft_noise(1.5, 2, 64, 23))
    dune = np.sin(2 * np.pi * (yy * 6 + (fft_noise(2.2, 1, 8, 24) - 0.5) * 2.5))
    dune = 0.5 + 0.5 * dune
    broad = fft_noise(1.6, 1, None, 25)
    sp = rng.random((N, N))
    sparkle = smoothstep(0.9965, 0.9995, sp)
    rp = np.stack([rip, dune, broad, sparkle], axis=-1)
    Image.fromarray((np.clip(rp, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(
        os.path.join(out, "ripples.png"))
    rn = normal_map(rip * 1.0 + broad * 0.6, 14.0)
    Image.fromarray((np.clip(rn, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(
        os.path.join(out, "ripples_normal.png"))
    # dunes / sastrugi fields: asymmetric crests (gentle windward, steep lee), no fine ripples
    # (fine ripples alias into moire at the scales this is sampled at)
    ph = yy * 6 + (fft_noise(2.2, 1, 8, 24) - 0.5) * 2.5 + (fft_noise(2.0, 2, 24, 26) - 0.5) * 0.4
    f = ph - np.floor(ph)
    prof = np.where(f < 0.78, f / 0.78, (1.0 - f) / 0.22)
    prof = prof * prof * (3 - 2 * prof)
    dn = normal_map(prof * (0.6 + 0.4 * fft_noise(1.5, 1, 16, 27)) + broad * 1.2, 9.0)
    Image.fromarray((np.clip(dn, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(
        os.path.join(out, "dunes_normal.png"))
    print("[textures] written to", out)


if __name__ == "__main__":
    main()
