"""Numpy mirror of shaders/include/atmosphere_common.gdshaderinc (atmo_scatter: Rayleigh, Mie, ozone
profile, multiple scattering, low-sun tints, path scale/window) for fast sky colour tuning without a
render (~5 s). Rows = sun elevations (`elevs`), columns = toward the sun / 90 deg / away / 60 deg up
away. Exposure follows a simple day->night curve; tonemap = Godot's ACES; `sat` = saturation.
Not mirrored: halos, emission, night light, cloud shadows.

  python3 tools/dev/sky_sim.py out.png ozone_height=7000 ozone_density=2 ms_strength=1.4 \
      twilight=1.32,0.9,0.95 twm=2.1,0.9,0.25 sun_path_scale=2.6 pw=7 rayleigh_density=1.2 \
      mie_density=3 mie_color=1,0.9,0.75 mie_g=0.8 multi_scatter=0 elevs=12,3,0,-3,-7
(keys = the dict P below; Terra Nova's wave-4 values shown)
"""
import sys, math
import numpy as np
from PIL import Image

P = dict(
    radius=60000.0, height=24000.0, rayleigh_height=2600.0, mie_height=750.0,
    rayleigh_density=1.5, tint=(1, 1, 1), mie_density=0.8, mie_g=0.78, mie_absorb=0.1,
    ozone_density=1.0, ozone_height=0.0, intensity=math.pi, multi_scatter=0.35,
    sun_path_scale=2.8, ms_strength=0.0, ms_lift_deg=4.0, ms_path=0.55,
    twilight=(1, 1, 1), sky_gain=1.0, exposure=1.05, white=6.0, sun_e=1.6 * 1.0,
    shadow_soft=0.6, cam_h=2.0, steps=24, tonemap="aces", agx_white=16.29, agx_contrast=1.25,
    sat=1.0, elevs="12,3,0,-3,-7", res="200x112", fov=80.0, ground=0.12,
)
for a in sys.argv[2:]:
    k, v = a.split("=", 1)
    if "," in v and k not in ("elevs",):
        P[k] = tuple(float(x) for x in v.split(","))
    else:
        try:
            P[k] = float(v)
        except ValueError:
            P[k] = v

ER = np.array([5.802e-6, 13.558e-6, 33.1e-6])
EM = 3.996e-6
EO = np.array([0.650e-6, 1.881e-6, 0.085e-6])
R = P["radius"]; HR = P["rayleigh_height"]; HM = P["mie_height"]
HZ = P["ozone_height"] if P["ozone_height"] > 0 else HR
TOP = R + P["height"]
BR = ER * np.array(P["tint"]) * P["rayleigh_density"] * (8000.0 / HR)
BM = np.array(P.get("mie_color", (1.0, 1.0, 1.0))) * EM * P["mie_density"] * (1200.0 / HM)
BMA = BM * P["mie_absorb"]
BO = EO * 1.9 * P["ozone_density"] * (8000.0 / HZ)
TW = np.array(P["twilight"])


def chapman(r, mu, H):
    x = r / H; X = R / H
    c = np.sqrt(1.5707963 * x)
    pos = H * np.exp(X - x) / (mu + 1.0 / c)
    s = np.sqrt(np.maximum(1 - mu * mu, 0))
    x0 = x * s; c0 = np.sqrt(1.5707963 * x0)
    neg = H * (2 * c0 * np.exp(np.minimum(X - x0, 80)) - np.exp(X - x) / (-mu + 1.0 / c))
    return np.minimum(np.where(mu >= 0, pos, neg), 1e9)


def sun_od(r, mus):
    cr = chapman(r, mus, HR); cm = chapman(r, mus, HM)
    co = chapman(r, mus, HZ) if P["ozone_height"] > 0 else cr
    k = 1 + (P["sun_path_scale"] - 1) * (1 - np.clip(mus * P.get("pw", 3.0), 0, 1))
    return (BR * cr[..., None] + BO * co[..., None] + (BM + BMA) * cm[..., None]) * k[..., None]


def shadow(r, mus, extra=0.0, up=1.0):
    d = r * np.sqrt(np.maximum(1 - mus * mus, 0))
    w = HR * (P["shadow_soft"] + extra)
    sh = np.clip((d - (R - w)) / (w + w * up), 0, 1)
    sh = sh * sh * (3 - 2 * sh)
    return np.where(mus >= 0, 1.0, sh)


def ss(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def ms_source(r, mus):
    lift = math.radians(P["ms_lift_deg"])
    m2 = np.maximum(mus, mus * math.cos(lift) + np.sqrt(np.maximum(1 - mus * mus, 0)) * math.sin(lift))
    T = np.exp(-sun_od(r, m2) * P["ms_path"]) * shadow(r, m2, 1.2, 0.5)[..., None]
    tau = BR * HR + BM * HM
    sky = 1 - np.exp(-tau)
    return T * (sky * 2.0 + P["ground"] * np.maximum(m2, 0)[..., None])


def scatter(ro, rd, L):
    # ro: (3,), rd: (...,3)
    b = rd @ ro
    c = ro @ ro - TOP * TOP
    disc = b * b - c
    t1 = -b + np.sqrt(np.maximum(disc, 0))
    t0 = np.zeros_like(t1)
    # ground
    cg = ro @ ro - R * R
    dg = b * b - cg
    tg = -b - np.sqrt(np.maximum(dg, 0))
    hitg = (dg > 0) & (tg > 0)
    t1 = np.where(hitg, tg, t1)
    n = int(P["steps"]); length = t1 - t0
    od = np.zeros(rd.shape); sr = np.zeros(rd.shape); sm = np.zeros(rd.shape)
    msr = np.zeros(rd.shape); msm = np.zeros(rd.shape)
    for i in range(n):
        u0 = i / n; u1 = (i + 1) / n
        a = t0 + length * u0 ** 2; bb = t0 + length * u1 ** 2
        ds = bb - a; t = a + ds * 0.5
        p = ro + rd * t[..., None]
        r = np.linalg.norm(p, axis=-1)
        h = r - R
        dr = np.exp(-h / HR); dm = np.exp(-h / HM)
        dz = np.exp(-h / HZ) if P["ozone_height"] > 0 else dr
        ext = dr[..., None] * BR + dz[..., None] * BO + dm[..., None] * (BM + BMA)
        odh = od + ext * (ds * 0.5)[..., None]
        od = od + ext * ds[..., None]
        mus = (p @ L) / r
        wlow = ss(-0.02, 0.2, mus)[..., None]
        gain = TW + (1 - TW) * wlow
        TWM = np.array(P.get("twm", P["twilight"]))
        gainm = TWM + (1 - TWM) * wlow
        tv = np.exp(-odh) * gain
        tr0 = np.exp(-odh) * np.exp(-sun_od(r, mus)) * shadow(r, mus)[..., None]
        sr += tr0 * gain * (dr * ds)[..., None]; sm += tr0 * gainm * (dm * ds)[..., None]
        if P["ms_strength"] > 0:
            src = tv * ms_source(r, mus)
            msr += src * (dr * ds)[..., None]; msm += src * (dm * ds)[..., None]
    mu = rd @ L
    E = P["sun_e"] * P["intensity"] * P["sky_gain"]
    pr = 0.0596831 * (1 + mu * mu)
    g = P["mie_g"]; g2 = g * g
    pm = 0.1193662 * (1 - g2) * (1 + mu * mu) / ((2 + g2) * np.power(np.maximum(1 + g2 - 2 * g * mu, 1e-4), 1.5))
    srr = sr * BR; smm = sm * BM
    Lms = (msr * BR + msm * BM) * P["ms_strength"] / (4 * math.pi)
    col = E * (srr * pr[..., None] + smm * pm[..., None] + (srr + smm) * P["multi_scatter"] / (4 * math.pi) + Lms)
    T = np.exp(-od)
    # sun disc (transmitted) for orientation
    sund = (mu > math.cos(math.radians(0.9)))
    col = col + np.where(sund[..., None], 40.0 * T, 0)
    # ground: grey-green lambert, lit by transmitted sun
    gp = ro + rd * t1[..., None]
    gr = np.linalg.norm(gp, axis=-1)
    gn = gp / gr[..., None]
    gmus = gn @ L
    gl = np.exp(-sun_od(gr, gmus)) * shadow(gr, gmus)[..., None] * np.maximum(gmus, 0)[..., None] * P["sun_e"]
    gcol = np.array([0.10, 0.11, 0.08]) * gl
    col = np.where(hitg[..., None], col + gcol * T, col)
    return col


def aces(c, white):
    eb = 1.8
    A, B, C, D, E = 0.0245786, 0.000090537, 0.983729, 0.432951, 0.238081
    m1 = np.array([[0.59719, 0.35458, 0.04823], [0.07600, 0.90834, 0.01566], [0.02840, 0.13383, 0.83777]]) * eb
    m2 = np.array([[1.60475, -0.53108, -0.07367], [-0.10208, 1.10813, -0.00605], [-0.00327, -0.07276, 1.07602]])
    c = c @ m1.T
    t = (c * (c + A) - B) / (c * (C * c + D) + E)
    t = t @ m2.T
    w = white * eb
    wt = (w * (w + A) - B) / (w * (C * w + D) + E)
    return t / wt


def srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c < 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def view(L, yaw_deg, pitch_deg, W, H):
    up = np.array([0, 1.0, 0])
    yaw = math.radians(yaw_deg); pit = math.radians(pitch_deg)
    f = np.array([math.sin(yaw) * math.cos(pit), math.sin(pit), math.cos(yaw) * math.cos(pit)])
    rgt = np.cross(f, up); rgt /= np.linalg.norm(rgt)
    u = np.cross(rgt, f)
    tf = math.tan(math.radians(P["fov"]) / 2)
    xs = (np.arange(W) + 0.5) / W * 2 - 1
    ys = 1 - (np.arange(H) + 0.5) / H * 2
    X, Y = np.meshgrid(xs * tf, ys * tf * H / W)
    d = f + X[..., None] * rgt + Y[..., None] * u
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    ro = np.array([0, R + P["cam_h"], 0.0])
    return scatter(ro, d, L)


def main():
    W, H = (int(x) for x in str(P["res"]).split("x"))
    rows = []
    for e in str(P["elevs"]).split(","):
        e = float(e)
        L = np.array([0, math.sin(math.radians(e)), math.cos(math.radians(e))])
        tiles = []
        for yaw, pitch in [(0, 8), (90, 8), (180, 8), (180, 60)]:
            su = math.sin(math.radians(e))
            night = 1 - float(ss(P.get("n0", -0.18), P.get("n1", 0.06), su))
            expo = P["exposure"] + (P.get("night_exp", 2.6) - P["exposure"]) * night
            c = view(L, yaw, pitch, W, H) * expo
            if P["sat"] != 1.0:
                l = c @ np.array([0.2126, 0.7152, 0.0722])
                c = l[..., None] + (c - l[..., None]) * P["sat"]
            tm = aces(np.maximum(c, 0), P["white"])
            tiles.append((srgb(tm) * 255).astype(np.uint8))
        rows.append(np.concatenate(tiles, axis=1))
    img = np.concatenate(rows, axis=0)
    Image.fromarray(img).save(sys.argv[1])


main()
