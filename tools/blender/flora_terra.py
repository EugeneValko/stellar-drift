"""Terra Nova flora: trees, bushes, ferns, grass clumps and flowers (scatter assets).

Run:
    blender -b -P tools/blender/flora_terra.py -- assets/models/flora_terra.glb

Objects (one glTF node each, pivot at the ground contact point, Blender Z = Godot Y):
  spirepine_lod0/1/2   alien conifer (~20 m): tiered drooping whorls whose tips flick upward
  parasol_lod0/1/2     umbrella broadleaf (~11 m): forked limbs carrying flattened leaf domes
  fernpalm_lod0/1/2    tall fern-palm (~8 m): ringed curved trunk with arching pinnate fronds
  bush_round_lod0/1    leafy dome shrub (~1.4 m)
  bush_quill_lod0      radial quill shrub (~1.2 m)
  fern_lod0            ground fern (~0.8 m)
  grass_lod0/1         grass clump (0.35-0.75 m blades)
  grass_tall_lod0      tall meadow tuft with seed stalks (~1.1 m)
  flower_a_lod0        three-stem "star" flower clump
  flower_b_lod0        arching stem with hanging glow bulbs
LOD2 tree meshes are solid hulls for distant forests (material far_foliage).

Material slots (replaced by name in Godot, see src/planets/scatter/scatter_assets.gd):
  bark, bark_palm, needles, leaves, frond, grass, flower, glow, far_foliage
Vertex colour layout: see flora_common.py.
"""
import math
import os
import random
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from flora_common import (MeshBuilder, Vector, bezier, card, export_glb, lerp, out_path, reset_scene,
                          rot_z, smoothstep, strip, tube)

MAT_ORDER = ["bark", "bark_palm", "needles", "leaves", "frond", "grass", "flower", "glow", "far_foliage"]
UP = Vector((0, 0, 1))


def horiz_perp(d):
    s = d.cross(UP)
    if s.length < 1e-4:
        s = Vector((1, 0, 0))
    return s.normalized()


def rotate_about(v, axis, ang):
    from mathutils import Matrix
    return Matrix.Rotation(ang, 3, axis.normalized()) @ v


# ==========================================================================================
# Spirepine (conifer)
# ==========================================================================================

def spirepine_skeleton(seed=11, H=20.0):
    rnd = random.Random(seed)
    bend = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0)).normalized()

    def axis(z):
        t = z / H
        return bend * math.sin(t * math.pi * 1.2) * 0.35 * t + UP * z

    def trunk_r(z):
        t = min(z / H, 1.0)
        r = 0.4 * (1 - t) ** 1.15 + 0.025
        return r * (1.0 + 0.9 * math.exp(-z / 0.5))

    branches = []
    tiers = 13
    z0, z1 = 3.0, H - 1.1
    for k in range(tiers):
        f = k / (tiers - 1)
        zt = z0 + (z1 - z0) * (f ** 0.92)
        rel = (zt - z0) / (z1 - z0)
        L = 5.4 * (1 - rel) ** 0.85 + 0.75
        nb = 7 if rel < 0.45 else (6 if rel < 0.7 else (5 if rel < 0.88 else 4))
        az0 = k * 2.39996 + rnd.uniform(-0.3, 0.3)
        for b in range(nb):
            az = az0 + 2 * math.pi * b / nb + rnd.uniform(-0.25, 0.25)
            dh = Vector((math.cos(az), math.sin(az), 0))
            Lb = L * rnd.uniform(0.85, 1.12)
            zb = zt + rnd.uniform(-0.25, 0.25)
            p0 = axis(zb) + dh * trunk_r(zb) * 0.8
            droop = 0.22 + 0.1 * (1 - rel)
            p1 = p0 + dh * Lb * 0.35 + UP * (Lb * 0.02)
            p2 = p0 + dh * Lb * 0.72 - UP * (Lb * droop)
            p3 = p0 + dh * Lb * 1.0 - UP * (Lb * droop * 0.45)   # tip flicks back up
            branches.append({"p": [p0, p1, p2, p3], "L": Lb, "phase": rnd.random(), "rel": rel})
    return {"H": H, "axis": axis, "trunk_r": trunk_r, "branches": branches}


def spirepine(lod, sk):
    H = sk["H"]
    axis, trunk_r = sk["axis"], sk["trunk_r"]
    mb = MeshBuilder()
    sway = lambda z: max(0.0, min(1.0, z / H)) ** 1.6

    if lod == 2:
        # far hull: three stacked cones + trunk prism, single material
        tiers = [(2.6, 9.5, 4.9), (7.5, 15.0, 3.4), (12.5, H + 0.6, 2.0)]
        sides = 7
        for (za, zb, r) in tiers:
            ring = []
            for s in range(sides):
                a = 2 * math.pi * (s + 0.5 * (za > 5)) / sides
                d = Vector((math.cos(a), math.sin(a), 0))
                ring.append((mb.vert(axis(za) + d * r), d))
            tip = mb.vert(axis(zb))
            ctip = (sway(zb), 1.0, 1.0, 1.0)
            cb = (sway(za), 1.0, 0.55, 1.0)
            for s in range(sides):
                a0, a1 = ring[s], ring[(s + 1) % sides]
                n0 = (a0[1] * 0.75 + UP * 0.55)
                n1 = (a1[1] * 0.75 + UP * 0.55)
                mb.face([a0[0], a1[0], tip], [(0, 0), (1, 0), (0.5, 1)], [cb, cb, ctip],
                        [n0, n1, UP], "far_foliage")
            # underside (seen from below / low angles)
            c = mb.vert(axis(za + (zb - za) * 0.25))
            cu = (sway(za), 1.0, 0.3, 1.0)
            for s in range(sides):
                a0, a1 = ring[s], ring[(s + 1) % sides]
                mb.face([a1[0], a0[0], c], [(0, 0), (1, 0), (0.5, 1)], [cu] * 3,
                        [a1[1] - UP * 0.3, a0[1] - UP * 0.3, -UP], "far_foliage")
        tube(mb, [axis(0), axis(4.0)], [0.55, 0.3], 3, "far_foliage",
             lambda t, p: (sway(p.z), 0.0, 0.5, 0.0))
        return mb

    # --- trunk ---
    nring = 16 if lod == 0 else 7
    sides = 9 if lod == 0 else 6
    pts, radii = [], []
    for i in range(nring + 1):
        t = (i / nring) ** 1.25
        z = t * (H + 0.3)
        pts.append(axis(z))
        radii.append(trunk_r(z))
    tube(mb, pts, radii, sides, "bark",
         lambda t, p: (sway(p.z), 0.0, 0.55 + 0.45 * smoothstep(0, 4, p.z), 0.0), uv_v_scale=1.6)

    crown_r = 6.2

    def vol_normal(p):
        c = axis(p.z)
        d = p - c
        d.z = 0
        dl = d.length
        out = d / dl if dl > 1e-3 else Vector((1, 0, 0))
        return (out * 0.8 + UP * 0.55).normalized()

    def ao_at(p):
        c = axis(p.z)
        d = Vector((p.x - c.x, p.y - c.y, 0)).length
        rel_h = p.z / H
        reach = max(0.6, 5.4 * (1 - rel_h) + 0.6)
        return min(1.0, 0.32 + 0.6 * smoothstep(0.0, 1.0, d / reach) + 0.25 * rel_h)

    for br in sk["branches"]:
        P = br["p"]
        L = br["L"]
        ph = br["phase"]
        spine = bezier(P[0], P[1], P[2], P[3], 4 if lod == 0 else 2)
        if lod == 0:
            tube(mb, spine[:4], [0.08 * min(1, L / 4) + 0.02, 0.05, 0.03, 0.015], 3, "bark",
                 lambda t, p, ph=ph: (sway(p.z), t * 0.6, ao_at(p) * 0.8, ph), uv_v_scale=1.0)
            spots = [(0.14, 0.6), (0.45, 0.52), (0.74, 0.4)]
        else:
            spots = [(0.06, 1.0)]
        for (t0, frac) in spots:
            # point & tangent on the bezier
            u = t0
            base = bezier(P[0], P[1], P[2], P[3], 20)[int(u * 20)]
            nxt = bezier(P[0], P[1], P[2], P[3], 20)[min(int(u * 20) + 2, 20)]
            along = (nxt - base).normalized()
            along = (along + UP * 0.08).normalized()
            length = L * frac * (1.0 if lod == 0 else 0.98)
            width = min(L * (0.62 if lod == 0 else 0.58) * (1.0 - 0.35 * t0), 2.6)
            side = horiz_perp(along)
            for sgn in (-1, 1):
                sv = rotate_about(side, along, sgn * math.radians(36))
                tip_p = base + along * length
                cb = (sway(base.z), 0.25, ao_at(base), ph)
                ct = (sway(tip_p.z), 1.0, ao_at(tip_p), ph)
                card(mb, base, along, sv, length, width, "needles", cb, ct, vol_normal, taper=0.55)
    # leader at the top
    top = axis(H - 2.6)
    for k in range(3 if lod == 0 else 2):
        a = k * math.pi / (3 if lod == 0 else 2)
        side = Vector((math.cos(a), math.sin(a), 0))
        card(mb, top, UP, side, 3.3, 1.25, "needles", (sway(top.z), 0.3, 0.9, 0.5),
             (1.0, 1.0, 1.0, 0.5), lambda p: (Vector((p.x, p.y, 0)).normalized() * 0.7 + UP * 0.7)
             if Vector((p.x, p.y, 0)).length > 1e-3 else UP, taper=0.5)
    return mb


# ==========================================================================================
# Parasol (umbrella broadleaf)
# ==========================================================================================

def parasol_skeleton(seed=23):
    rnd = random.Random(seed)
    trunk_top = Vector((rnd.uniform(-0.2, 0.2), rnd.uniform(-0.2, 0.2), 2.7))
    limbs, twigs, clusters = [], [], []
    nl = 5
    for i in range(nl):
        az = 2 * math.pi * i / nl + rnd.uniform(-0.35, 0.35)
        d = Vector((math.cos(az), math.sin(az), 0))
        reach = rnd.uniform(2.6, 3.8)
        rise = rnd.uniform(4.6, 6.0)
        p0 = trunk_top
        p1 = p0 + d * 0.5 + UP * 1.6
        p2 = p0 + d * reach * 0.55 + UP * rise * 0.8
        p3 = p0 + d * reach + UP * rise
        limbs.append({"p": [p0, p1, p2, p3], "phase": rnd.random()})
        nt = 2 if i % 2 else 3
        for j in range(nt):
            a2 = az + (j - (nt - 1) / 2) * 0.75 + rnd.uniform(-0.15, 0.15)
            d2 = Vector((math.cos(a2), math.sin(a2), 0))
            l2 = rnd.uniform(1.3, 2.4)
            q0 = p3
            q3 = q0 + d2 * l2 + UP * rnd.uniform(0.5, 1.4)
            q1 = q0 + (q3 - q0) * 0.33 + UP * 0.4
            q2 = q0 + (q3 - q0) * 0.66 + UP * 0.3
            twigs.append({"p": [q0, q1, q2, q3], "phase": rnd.random()})
            clusters.append({"c": q3 + UP * 0.35, "r": rnd.uniform(1.7, 2.3), "phase": rnd.random(),
                             "seed": rnd.randint(0, 99999)})
    # one crowning cluster in the middle
    clusters.append({"c": trunk_top + UP * 7.4, "r": 2.2, "phase": rnd.random(), "seed": 7})
    top = max(c["c"].z for c in clusters) + 1.0
    return {"trunk_top": trunk_top, "limbs": limbs, "twigs": twigs, "clusters": clusters, "H": top}


def parasol(lod, sk):
    H = sk["H"]
    mb = MeshBuilder()
    sway = lambda z: max(0.0, min(1.0, z / H)) ** 1.6
    clusters = sk["clusters"]
    cz = sum(c["c"].z for c in clusters) / len(clusters)
    ccen = Vector((0, 0, cz))

    if lod == 2:
        # flattened dome canopy + trunk prism
        rad = max(Vector((c["c"].x, c["c"].y, 0)).length + c["r"] for c in clusters)
        sides = 9
        rings = [(-0.55, 0.85), (0.0, 1.0), (0.55, 0.78), (0.95, 0.35)]
        verts = []
        for (zf, rf) in rings:
            ring = []
            for s in range(sides):
                a = 2 * math.pi * s / sides
                d = Vector((math.cos(a), math.sin(a), 0))
                p = ccen + d * rad * rf + UP * zf * 1.7
                n = (d * 0.6 + UP * (zf + 0.15)).normalized()
                ring.append((mb.vert(p), n, p))
            verts.append(ring)
        for i in range(len(rings) - 1):
            for s in range(sides):
                a, b = verts[i][s], verts[i][(s + 1) % sides]
                c, d = verts[i + 1][(s + 1) % sides], verts[i + 1][s]
                col = lambda v: (sway(v[2].z), 1.0, 0.45 + 0.55 * (i + 1) / 3, 1.0)
                mb.face([a[0], b[0], c[0], d[0]], [(0, 0), (1, 0), (1, 1), (0, 1)],
                        [col(a), col(b), col(c), col(d)], [a[1], b[1], c[1], d[1]], "far_foliage")
        top = mb.vert(ccen + UP * 1.9)
        for s in range(sides):
            a, b = verts[-1][s], verts[-1][(s + 1) % sides]
            mb.face([a[0], b[0], top], [(0, 0), (1, 0), (0.5, 1)], [(1, 1, 1, 1)] * 3,
                    [a[1], b[1], UP], "far_foliage")
        bot = mb.vert(ccen - UP * 1.2)
        for s in range(sides):
            a, b = verts[0][s], verts[0][(s + 1) % sides]
            mb.face([b[0], a[0], bot], [(0, 0), (1, 0), (0.5, 1)], [(sway(cz), 1, 0.3, 1)] * 3,
                    [-UP, -UP, -UP], "far_foliage")
        tube(mb, [Vector((0, 0, 0)), Vector((0, 0, cz - 1.0))], [0.5, 0.3], 3, "far_foliage",
             lambda t, p: (sway(p.z), 0.0, 0.5, 0.0))
        return mb

    # --- trunk: slight lean, flared base ---
    tt = sk["trunk_top"]
    n = 7 if lod == 0 else 3
    pts = [Vector((tt.x * (i / n) ** 2, tt.y * (i / n) ** 2, tt.z * i / n)) for i in range(n + 1)]
    radii = [0.36 * (1 + 0.8 * math.exp(-p.z / 0.4)) * (1 - 0.15 * p.z / tt.z) for p in pts]
    tube(mb, pts, radii, 8 if lod == 0 else 5, "bark",
         lambda t, p: (sway(p.z), 0.0, 0.5 + 0.5 * smoothstep(0, 2.5, p.z), 0.0), uv_v_scale=1.4)
    for lb in sk["limbs"]:
        P = lb["p"]
        sp = bezier(*P, 5 if lod == 0 else 3)
        rr = [0.24, 0.2, 0.16, 0.13, 0.11, 0.09][:len(sp)] if lod == 0 else [0.24, 0.17, 0.12, 0.09]
        tube(mb, sp, rr, 6 if lod == 0 else 4, "bark",
             lambda t, p, ph=lb["phase"]: (sway(p.z), 0.15 * t, 0.65 + 0.3 * t, ph), uv_v_scale=1.2)
    for tw in sk["twigs"]:
        P = tw["p"]
        if lod == 0:
            tube(mb, bezier(*P, 3), [0.09, 0.07, 0.05, 0.03], 4, "bark",
                 lambda t, p, ph=tw["phase"]: (sway(p.z), 0.2 + 0.4 * t, 0.8, ph), uv_v_scale=1.0)
        else:
            tube(mb, [P[0], P[3]], [0.09, 0.04], 3, "bark",
                 lambda t, p, ph=tw["phase"]: (sway(p.z), 0.2 + 0.4 * t, 0.8, ph))

    # --- leaf domes ---
    for cl in clusters:
        rnd = random.Random(cl["seed"])
        c = cl["c"]
        r = cl["r"]
        ncards = 15 if lod == 0 else 6
        for k in range(ncards):
            if k == 0:
                d = UP
            else:
                # golden-spiral points on the upper part of a flattened dome
                f = (k - 0.5) / ncards
                z = 1.0 - f * 1.35
                rr = math.sqrt(max(0.0, 1 - min(z, 1) ** 2))
                a = k * 2.39996 + rnd.uniform(-0.3, 0.3)
                d = Vector((math.cos(a) * rr, math.sin(a) * rr, z)).normalized()
            dd = Vector((d.x, d.y, d.z * 0.45))
            base = c + dd * r * 0.25
            along = (dd + Vector((rnd.uniform(-0.2, 0.2), rnd.uniform(-0.2, 0.2), 0.12))).normalized()
            if k == 0:
                along = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0.25)).normalized()
                base = c - along * r * 0.45 + UP * 0.35
            side = horiz_perp(along) if abs(along.z) < 0.95 else Vector((1, 0, 0))
            side = rotate_about(side, along, rnd.uniform(-0.6, 0.6))
            ln = r * (0.95 if lod == 0 else 1.25) * rnd.uniform(0.85, 1.1)
            wd = r * (0.95 if lod == 0 else 1.3)

            def nf(p, c=c):
                q = p - c
                q.z *= 2.2
                return (q.normalized() * 0.75 + UP * 0.45).normalized()
            hb = (base.z - cz)
            ao_b = 0.45 + 0.3 * smoothstep(-1.5, 1.5, hb)
            tip = base + along * ln
            ao_t = 0.6 + 0.4 * smoothstep(-1.5, 1.5, tip.z - cz)
            card(mb, base, along, side, ln, wd, "leaves", (sway(base.z), 0.3, ao_b, cl["phase"]),
                 (sway(tip.z), 1.0, ao_t, cl["phase"]), nf, taper=0.6)
    return mb


# ==========================================================================================
# Fern-palm
# ==========================================================================================

def fernpalm_skeleton(seed=37):
    rnd = random.Random(seed)
    H = 8.4
    lean = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0)).normalized()
    P = [Vector((0, 0, 0)), UP * H * 0.4, lean * 0.7 + UP * H * 0.75, lean * 1.25 + UP * H]
    fronds = []
    nf = 12
    for i in range(nf + 3):
        young = i >= nf
        az = (i * 2.39996) + rnd.uniform(-0.2, 0.2)
        elev = math.radians(rnd.uniform(70, 82) if young else rnd.uniform(28, 52))
        L = rnd.uniform(2.2, 3.0) if young else rnd.uniform(4.0, 5.4)
        fronds.append({"az": az, "elev": elev, "L": L, "young": young, "phase": rnd.random(),
                       "twist": rnd.uniform(-0.3, 0.3)})
    return {"H": H, "P": P, "fronds": fronds}


def fernpalm(lod, sk):
    H = sk["H"]
    P = sk["P"]
    mb = MeshBuilder()
    Htot = H + 2.5
    sway = lambda z: max(0.0, min(1.0, z / Htot)) ** 1.5
    top = P[3]

    def frond_spine(fr, segs):
        d = Vector((math.cos(fr["az"]), math.sin(fr["az"]), 0))
        L = fr["L"]
        e = fr["elev"]
        k = 0.95 / L if not fr["young"] else 0.15 / L
        pts = []
        for i in range(segs + 1):
            s = L * (i / segs)
            pts.append(top + d * math.cos(e) * s + UP * (math.sin(e) * s - k * s * s))
        return pts, d

    if lod == 2:
        tube(mb, bezier(*P, 2), [0.3, 0.22, 0.16], 3, "far_foliage", lambda t, p: (sway(p.z), 0.0, 0.45, 0.0))
        for fr in sk["fronds"][:9]:
            pts, d = frond_spine(fr, 2)
            side = horiz_perp(d)
            w = 0.9
            spine = pts
            strip(mb, spine, [side] * 3, [0.25, w * 1.3, 0.2], "far_foliage",
                  lambda t: (sway(top.z), 1.0, 0.7 + 0.3 * t, 1.0),
                  lambda t, p, s: (UP * 0.8 + (p - top).normalized() * 0.5).normalized())
        return mb

    segs = 14 if lod == 0 else 5
    sp = bezier(*P, segs)
    radii = [0.25 * (1 + 0.7 * math.exp(-p.z / 0.35)) * (1 - 0.35 * p.z / H) for p in sp]
    tube(mb, sp, radii, 7 if lod == 0 else 5, "bark_palm",
         lambda t, p: (sway(p.z), 0.0, 0.55 + 0.45 * smoothstep(0, 3, p.z), 0.0), uv_v_scale=1.0)
    # crown bulb
    tube(mb, [top - UP * 0.35, top + UP * 0.05, top + UP * 0.35], [0.2, 0.26, 0.08], 6 if lod == 0 else 4,
         "bark_palm", lambda t, p: (sway(p.z), 0.0, 0.6, 0.0), cap=True)

    for fr in sk["fronds"]:
        if lod == 1 and fr["young"]:
            continue
        segs = 6 if lod == 0 else 3
        pts, d = frond_spine(fr, segs)
        side0 = rotate_about(horiz_perp(d), d, fr["twist"])
        W = (1.25 if not fr["young"] else 0.7) * (1.0 if lod == 0 else 1.15)
        widths = [W * (0.18 + 0.82 * math.sin(math.pi * min(1.0, (i / segs) ** 0.75 * 0.95 + 0.02)))
                  for i in range(segs + 1)]
        widths[-1] *= 0.35
        ph = fr["phase"]
        col = lambda t, ph=ph: (sway(top.z) + 0.25 * t, t, 0.62 + 0.38 * t, ph)

        def nf(t, p, s):
            o = (p - top)
            o.z = 0
            o = o.normalized() if o.length > 1e-3 else d
            return (UP * 0.85 + o * 0.45).normalized()
        if lod == 0:
            # V-folded frond: two half strips meeting at a raised rachis
            fold = 0.22
            sides_l = []
            sides_r = []
            for i, p in enumerate(pts):
                sv = side0
                sides_l.append(sv)
            for half in (-1, 1):
                outer = [p + side0 * half * widths[i] * 0.5 - UP * widths[i] * fold for i, p in enumerate(pts)]
                mid = [(p + o) * 0.5 for p, o in zip(pts, outer)]
                # strip from rachis (u=0.5) to outer edge (u=0 or 1)
                L = [0.0]
                for i in range(1, len(pts)):
                    L.append(L[-1] + (pts[i] - pts[i - 1]).length)
                tot = L[-1]
                rows = []
                for i in range(len(pts)):
                    t = L[i] / tot
                    a = mb.vert(pts[i])
                    b = mb.vert(outer[i])
                    rows.append((a, b, t, pts[i], outer[i]))
                for i in range(len(pts) - 1):
                    a0, b0, t0, pa0, pb0 = rows[i]
                    a1, b1, t1, pa1, pb1 = rows[i + 1]
                    uo = 0.0 if half < 0 else 1.0
                    idx = [a0, b0, b1, a1] if half > 0 else [b0, a0, a1, b1]
                    uvs = [(0.5, t0), (uo, t0), (uo, t1), (0.5, t1)] if half > 0 else \
                        [(uo, t0), (0.5, t0), (0.5, t1), (uo, t1)]
                    ps = [pa0, pb0, pb1, pa1] if half > 0 else [pb0, pa0, pa1, pb1]
                    ts = [t0, t0, t1, t1]
                    mb.face(idx, uvs, [col(t) for t in ts], [nf(t, p, 0) for t, p in zip(ts, ps)], "frond")
        else:
            strip(mb, pts, [side0] * len(pts), widths, "frond", col, nf)
    return mb


# ==========================================================================================
# Bushes, ferns, grass, flowers
# ==========================================================================================

def bush_round(lod, seed=51):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    H = 1.5
    c = Vector((0, 0, 0.62))
    rad = Vector((0.95, 0.95, 0.68))
    sway = lambda z: max(0.0, min(1.0, z / H))
    if lod == 0:
        for k in range(4):
            a = k * 1.7
            d = Vector((math.cos(a), math.sin(a), 0))
            tube(mb, [d * 0.05, d * 0.25 + UP * 0.45, d * 0.45 + UP * 0.8], [0.035, 0.025, 0.012], 3, "bark",
                 lambda t, p: (sway(p.z), t * 0.5, 0.35 + 0.3 * t, 0.3))
    n = 30 if lod == 0 else 12
    for k in range(n):
        f = (k + 0.5) / n
        z = 1.0 - f * 1.45
        rr = math.sqrt(max(0.0, 1 - min(z, 1) ** 2))
        a = k * 2.39996 + rnd.uniform(-0.25, 0.25)
        d = Vector((math.cos(a) * rr, math.sin(a) * rr, z)).normalized()
        base = c + Vector((d.x * rad.x, d.y * rad.y, d.z * rad.z)) * 0.3
        along = (d + Vector((0, 0, 0.35))).normalized()
        side = horiz_perp(along) if abs(along.z) < 0.97 else Vector((1, 0, 0))
        side = rotate_about(side, along, rnd.uniform(-0.8, 0.8))
        s = (0.78 if lod == 0 else 1.05) * rnd.uniform(0.85, 1.1)
        ph = rnd.random()
        ao0 = 0.35 + 0.3 * (d.z * 0.5 + 0.5)
        tip = base + along * s
        card(mb, base, along, side, s, s * 0.95, "leaves", (sway(base.z), 0.35, ao0, ph),
             (sway(tip.z), 1.0, min(1.0, ao0 + 0.4), ph),
             lambda p: ((p - c).normalized() * 0.8 + UP * 0.35).normalized(), taper=0.6)
    return mb


def quill_like(name_mat, n, Lr, elev_r, width, seed, segs=3, base_r=0.08, H=1.3, fold=0.0):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    sway = lambda z: max(0.0, min(1.0, z / H))
    for i in range(n):
        az = i * 2.39996 + rnd.uniform(-0.2, 0.2)
        d = Vector((math.cos(az), math.sin(az), 0))
        e = math.radians(rnd.uniform(*elev_r))
        L = rnd.uniform(*Lr)
        k = 0.55 / L
        base = d * base_r * rnd.random()
        pts = []
        for j in range(segs + 1):
            s = L * j / segs
            pts.append(base + d * math.cos(e) * s + UP * (math.sin(e) * s - k * s * s))
        side = rotate_about(horiz_perp(d), d, rnd.uniform(-0.4, 0.4))
        widths = [width * (0.3 + 0.7 * math.sin(math.pi * min(0.97, (j / segs) ** 0.8 + 0.05)))
                  for j in range(segs + 1)]
        ph = rnd.random()
        strip(mb, pts, [side] * len(pts), widths, name_mat,
              lambda t, ph=ph: (sway(0.2 + t * H * 0.6), t, 0.4 + 0.6 * t, ph),
              lambda t, p, s, d=d: (UP * 0.8 + d * 0.5).normalized())
    return mb


def grass(lod, seed=61, tall=False):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    if tall:
        nb, hr, segs, w0 = 13, (0.65, 1.15), 4, 0.03
    elif lod == 0:
        nb, hr, segs, w0 = 20, (0.32, 0.72), 3, 0.028
    else:
        nb, hr, segs, w0 = 8, (0.35, 0.65), 1, 0.06
    Hm = hr[1]
    for b in range(nb):
        r = 0.24 * math.sqrt(rnd.random())
        a = rnd.random() * 2 * math.pi
        base = Vector((math.cos(a) * r, math.sin(a) * r, -0.03))
        lean_dir = Vector((math.cos(a), math.sin(a), 0)) if r > 0.03 else Vector((1, 0, 0))
        lean_dir = rotate_about(lean_dir, UP, rnd.uniform(-0.6, 0.6))
        h = rnd.uniform(*hr)
        lean = math.radians(rnd.uniform(6, 30))
        curl = math.radians(rnd.uniform(10, 45))
        side = rotate_about(horiz_perp(lean_dir), UP, rnd.uniform(-0.5, 0.5))
        rb = rnd.random()
        pts = [base]
        ang = lean
        p = base.copy()
        seg_len = h / segs * 1.04
        for s in range(segs):
            ang += curl / segs
            p = p + (lean_dir * math.sin(ang) + UP * math.cos(ang)) * seg_len
            pts.append(p.copy())
        tip = pts[-1] + (lean_dir * math.sin(ang + curl / segs) + UP * math.cos(ang + curl / segs)) * seg_len * 0.6
        # blade faces
        fn = (side.cross(pts[1] - pts[0])).normalized()
        if fn.z < 0:
            fn = -fn
        nrm = (fn * 0.35 + UP * 0.8).normalized()
        rows = []
        for s, q in enumerate(pts):
            t = s / (segs + 0.6)
            w = w0 * (1 - 0.65 * t) * rnd.uniform(0.85, 1.15) if s == 0 else w0 * (1 - 0.75 * t)
            a_ = mb.vert(q - side * w * 0.5)
            b_ = mb.vert(q + side * w * 0.5)
            hgt = (q.z + 0.03) / Hm
            rows.append((a_, b_, t, hgt))
        col = lambda t, hgt: (max(0.0, min(1.0, hgt)), t, 0.3 + 0.7 * t, rb)
        for s in range(segs):
            a0, b0, t0, h0 = rows[s]
            a1, b1, t1, h1 = rows[s + 1]
            mb.face([a0, b0, b1, a1], [(0, t0), (1, t0), (1, t1), (0, t1)],
                    [col(t0, h0), col(t0, h0), col(t1, h1), col(t1, h1)], [nrm] * 4, "grass")
        ti = mb.vert(tip)
        a0, b0, t0, h0 = rows[-1]
        ht = (tip.z + 0.03) / Hm
        mb.face([a0, b0, ti], [(0, t0), (1, t0), (0.5, 1)], [col(t0, h0), col(t0, h0), col(1.0, ht)],
                [nrm] * 3, "grass")
        if tall and b < 3 and False:   # seed heads read as floating leaves; disabled
            # seed head: a narrow strip continuing past the blade tip
            hd = (tip - pts[-1]).normalized()
            hs = [tip + hd * 0.035 * i for i in range(4)]
            strip(mb, hs, [side] * 4, [0.006, 0.016, 0.012, 0.003], "grass",
                  lambda t: (1.0, 1.0, 0.8, 0.99), lambda t, p, s: UP)
    return mb


def flower_a(seed=71):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    H = 0.55
    for k in range(3):
        a = k * 2.2 + rnd.uniform(-0.3, 0.3)
        d = Vector((math.cos(a), math.sin(a), 0))
        h = rnd.uniform(0.28, 0.5)
        base = d * rnd.uniform(0.02, 0.08)
        tipd = d * rnd.uniform(0.04, 0.12)
        sp = bezier(base, base + UP * h * 0.4, tipd + UP * h * 0.8, tipd + UP * h, 3)
        tube(mb, sp, [0.006, 0.005, 0.004, 0.004], 3, "grass",
             lambda t, p: (p.z / H, t, 0.4 + 0.6 * t, 0.5))
        top = sp[-1]
        # leaves at the base
        for j in range(2):
            la = a + (j - 0.5) * 2.2
            ld = Vector((math.cos(la), math.sin(la), 0))
            lp = [base + UP * 0.02, base + ld * 0.06 + UP * 0.07, base + ld * 0.12 + UP * 0.06]
            strip(mb, lp, [horiz_perp(ld)] * 3, [0.01, 0.035, 0.0], "grass",
                  lambda t: (0.15 * t, t, 0.5 + 0.4 * t, 0.3), lambda t, p, s: UP)
        # head: disc + petals facing up/outward
        face_dir = (UP * 0.8 + d * 0.5).normalized()
        u = horiz_perp(face_dir) if abs(face_dir.z) < 0.99 else Vector((1, 0, 0))
        v = face_dir.cross(u)
        npt = 7
        center = mb.vert(top + face_dir * 0.006)
        ring = []
        for i in range(npt):
            ang = 2 * math.pi * i / npt
            ring.append(mb.vert(top + (u * math.cos(ang) + v * math.sin(ang)) * 0.014))
        cc = (top.z / H, 0.0, 0.8, 0.0)
        cr = (top.z / H, 0.2, 0.8, 0.0)
        for i in range(npt):
            mb.face([center, ring[i], ring[(i + 1) % npt]], [(0.5, 0.5), (0, 0), (1, 0)], [cc, cr, cr],
                    [face_dir] * 3, "flower")
        for i in range(npt):
            ang = 2 * math.pi * (i + 0.5) / npt
            pd = (u * math.cos(ang) + v * math.sin(ang))
            p0 = top + pd * 0.01
            p1 = top + pd * 0.06 - face_dir * 0.012
            sv = face_dir.cross(pd).normalized()
            a_ = mb.vert(p0 - sv * 0.008)
            b_ = mb.vert(p0 + sv * 0.008)
            c_ = mb.vert(p1 + sv * 0.014)
            d_ = mb.vert(p1 - sv * 0.014)
            c0 = (top.z / H, 0.25, 0.85, 1.0)
            c1 = (top.z / H, 1.0, 1.0, 1.0)
            mb.face([a_, b_, c_, d_], [(0, 0), (1, 0), (1, 1), (0, 1)], [c0, c0, c1, c1], [face_dir] * 4, "flower")
    return mb


def flower_b(seed=81):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    H = 0.75
    a = rnd.random() * 6.28
    d = Vector((math.cos(a), math.sin(a), 0))
    sp = bezier(Vector((0, 0, 0)), UP * 0.45, d * 0.15 + UP * 0.75, d * 0.38 + UP * 0.62, 5)
    tube(mb, sp, [0.009, 0.008, 0.007, 0.006, 0.005, 0.004], 3, "grass",
         lambda t, p: (p.z / H, t, 0.4 + 0.6 * t, 0.6))
    # leaves
    for j in range(3):
        la = a + 2.1 * j
        ld = Vector((math.cos(la), math.sin(la), 0))
        lp = [UP * 0.01, ld * 0.08 + UP * 0.1, ld * 0.2 + UP * 0.12, ld * 0.28 + UP * 0.07]
        strip(mb, lp, [horiz_perp(ld)] * 4, [0.01, 0.05, 0.045, 0.0], "grass",
              lambda t: (0.2 * t, t, 0.5 + 0.4 * t, 0.4), lambda t, p, s: UP)
    # hanging bulbs along the arch
    for k, t in enumerate([0.62, 0.8, 1.0]):
        idx = min(int(t * 5), 5)
        hang = sp[idx]
        L = 0.05 + 0.03 * k
        c = hang - UP * (L + 0.035)
        tube(mb, [hang, c + UP * 0.03], [0.003, 0.003], 3, "grass", lambda tt, p: (p.z / H, 1.0, 0.8, 0.6))
        r = 0.028 + 0.006 * k
        prof = [(0.03, 0.3), (0.0, 0.85), (-0.02, 1.0), (-0.035, 0.7), (-0.042, 0.0)]
        rings = []
        sides = 6
        for (dz, rf) in prof:
            ring = []
            for s in range(sides):
                an = 2 * math.pi * s / sides
                dd = Vector((math.cos(an), math.sin(an), 0))
                p = c + UP * dz * (r / 0.03) + dd * r * rf
                ring.append((mb.vert(p), (dd * rf + UP * (dz * 20)).normalized()))
            rings.append(ring)
        for i in range(len(prof) - 1):
            for s in range(sides):
                s2 = (s + 1) % sides
                q = [rings[i][s], rings[i][s2], rings[i + 1][s2], rings[i + 1][s]]
                gv = 1.0 - i / (len(prof) - 1)
                cols = [(c.z / H, 1.0 - (i + (j >= 2)) / 4, 1.0, 1.0) for j in range(4)]
                mb.face([x[0] for x in q][::-1], [(0, 0), (1, 0), (1, 1), (0, 1)][::-1], cols[::-1],
                        [x[1] for x in q][::-1], "glow")
    return mb


# ==========================================================================================

def main():
    out = out_path("assets/models/flora_terra.glb")
    reset_scene()
    sk = spirepine_skeleton()
    for lod in range(3):
        spirepine(lod, sk).build("spirepine_lod%d" % lod, MAT_ORDER)
    sk = parasol_skeleton()
    for lod in range(3):
        parasol(lod, sk).build("parasol_lod%d" % lod, MAT_ORDER)
    sk = fernpalm_skeleton()
    for lod in range(3):
        fernpalm(lod, sk).build("fernpalm_lod%d" % lod, MAT_ORDER)
    bush_round(0).build("bush_round_lod0", MAT_ORDER)
    bush_round(1).build("bush_round_lod1", MAT_ORDER)
    quill_like("frond", 14, (0.8, 1.35), (38, 72), 0.2, 91, segs=3, H=1.3).build("bush_quill_lod0", MAT_ORDER)
    quill_like("frond", 8, (0.6, 0.95), (25, 50), 0.34, 93, segs=3, H=0.8).build("fern_lod0", MAT_ORDER)
    grass(0).build("grass_lod0", MAT_ORDER)
    grass(1).build("grass_lod1", MAT_ORDER)
    grass(0, seed=63, tall=True).build("grass_tall_lod0", MAT_ORDER)
    flower_a().build("flower_a_lod0", MAT_ORDER)
    flower_b().build("flower_b_lod0", MAT_ORDER)
    export_glb(os.path.abspath(out))


main()
