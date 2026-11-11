"""ST-7 "Tern" light expedition craft - master dimensions and smooth body surfaces.

Ship space: +X starboard, +Y nose, +Z up, metres. Origin on the hull axis near the centre of mass.
Every body is built as a subdivision cage (Catmull-Clark with creases) and returned as a dense bmesh.
"""
import math

import bmesh
import bpy

import kit
from kit import V

GROUND_Z = -2.60          # landing pad contact plane (gear down)
NOSE_Y = 7.9
TAIL_Y = -7.0

# fuselage stations: y, chine half-width, chine z, top z, deck half-width, belly z, belly half-width,
#                    upper-side bulge, lower-side bulge
FUSE = [
    (7.90, 0.30, -0.36, -0.24, 0.16, -0.50, 0.16, 0.10, 0.05),
    (7.50, 0.58, -0.35, -0.10, 0.26, -0.62, 0.32, 0.14, 0.06),
    (6.60, 1.02, -0.32, 0.16, 0.38, -0.84, 0.60, 0.20, 0.07),
    (5.60, 1.38, -0.27, 0.56, 0.46, -1.02, 0.86, 0.26, 0.08),
    (4.60, 1.66, -0.22, 1.04, 0.52, -1.12, 1.06, 0.30, 0.08),
    (3.50, 1.86, -0.17, 1.32, 0.58, -1.18, 1.20, 0.30, 0.08),
    (2.20, 1.98, -0.13, 1.38, 0.68, -1.20, 1.28, 0.26, 0.08),
    (0.60, 2.04, -0.10, 1.30, 0.80, -1.20, 1.32, 0.22, 0.08),
    (-1.60, 2.04, -0.10, 1.18, 0.88, -1.18, 1.32, 0.20, 0.08),
    (-3.80, 1.94, -0.08, 1.06, 0.86, -1.08, 1.22, 0.18, 0.08),
    (-5.60, 1.68, -0.04, 0.90, 0.76, -0.88, 1.00, 0.16, 0.07),
    (-6.60, 1.42, 0.00, 0.76, 0.64, -0.66, 0.80, 0.15, 0.06),
    (-7.00, 1.32, 0.02, 0.70, 0.60, -0.58, 0.74, 0.15, 0.06),
]

# engine pods (starboard): circular, on the wing "wrist"
NAC_X = 3.55
NAC_Z = 0.28
NAC_R = 0.98
NAC_LIP_Y = 1.00
NAC_END_Y = -6.20
NOZZLE_R = 0.70  # nozzle mount radius at NAC_END_Y
NAC_ROWS = [  # y, radius, rake factor: runs from deep inside the intake duct, around the lip, to the tail
    (-0.90, 0.34, 0.0), (-0.10, 0.48, 0.3), (0.65, 0.63, 1.0), (NAC_LIP_Y - 0.06, 0.70, 1.0),
    (NAC_LIP_Y, 0.74, 1.0), (NAC_LIP_Y - 0.11, 0.78, 1.0), (0.25, 0.88, 0.7), (-1.30, NAC_R, 0.1),
    (-3.60, 0.96, 0.0), (-5.20, 0.85, 0.0), (NAC_END_Y, NOZZLE_R * 1.05, 0.0),
]
NAC_RAKE = 0.24
SPIKE_ROWS = [(1.75, 0.015), (1.50, 0.10), (0.80, 0.31), (0.20, 0.38), (-0.60, 0.29), (-0.95, 0.23)]

# gull wing (starboard): rises from the body to the engine pod, outer panel droops to the tip pod
WING = [  # x, leading-edge y, trailing-edge y, z, thickness
    (1.60, 2.00, -5.00, -0.08, 0.46),
    (2.60, 1.10, -5.00, 0.12, 0.42),
    (3.55, 0.30, -4.95, 0.28, 0.40),
    (4.53, -0.55, -4.80, 0.02, 0.32),
    (5.60, -1.75, -4.40, -0.36, 0.22),
    (6.55, -2.80, -4.05, -0.70, 0.14),
]
POD_X, POD_Z = 6.60, -0.72
POD_Y0, POD_Y1 = -2.10, -4.50

# canted fins (starboard): on top of the engine pods
FIN_CANT = 20.0
FIN = [  # distance along the fin, leading-edge y, trailing-edge y, thickness
    (-0.30, -2.60, -5.90, 0.20),
    (0.60, -3.60, -6.00, 0.15),
    (1.55, -4.85, -6.35, 0.08),
]
FIN_ROOT = (NAC_X + 0.30, NAC_Z + 0.80)   # x, z of the fin root line

GEAR_NOSE = (0.0, 4.40)
GEAR_MAIN = (NAC_X, -2.40)

CANOPY = [(6.22, 0.31), (2.30, 0.56), (1.50, 1.65), (6.22, 1.65)]   # side-view outline (y, z) of the glazing


def _subdivide(bm, levels, name="tmp"):
    ob = kit.to_obj(name, bm, None, smooth=None)
    kit.mod_subsurf(ob, levels)
    kit.apply_mods(ob)
    out = kit.bm_from_obj(ob)
    bpy.data.objects.remove(ob)
    out.normal_update()
    return out


# ------------------------------------------------------------------------------------------
def fuselage(levels=3):
    rings = []
    for (y, w, zc, zt, wt, zb, wb, bu, bl) in FUSE:
        B = V((wt, zt - 0.04 * min(1.0, wt)))
        D = V((w, zc))
        F = V((wb, zb))
        # side mid points pushed outwards along the side normal
        du = D - B
        C = B.lerp(D, 0.5) + V((-du.y, du.x)).normalized() * (-bu) * du.length
        dl = F - D
        E = D.lerp(F, 0.5) + V((-dl.y, dl.x)).normalized() * (-bl) * dl.length
        half = [V((0.0, zt)), B, C, D, E, F, V((0.0, zb))]
        ring = [V((p.x, y, p.y)) for p in half] + [V((-p.x, y, p.y)) for p in reversed(half[1:-1])]
        rings.append(ring)
    bm, vr = kit.loft(rings)
    n = len(vr)
    for idx, val in ((1, 0.25), (11, 0.25), (3, 0.78), (9, 0.78), (5, 0.55), (7, 0.55)):
        kit.crease_path(bm, [vr[i][idx] for i in range(n)], val)
    kit.crease_path(bm, vr[-1], 0.85, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "fuselage")


def _superellipse(a, b, e, n=16, rot=0.0):
    pts = []
    for j in range(n):
        t = math.tau * j / n + rot
        c, s = math.cos(t), math.sin(t)
        pts.append((a * math.copysign(abs(c) ** (2.0 / e), c), b * math.copysign(abs(s) ** (2.0 / e), s)))
    return pts


def nacelle(levels=3, side=1):
    """Engine pod with a real intake lip + duct. side=+1 starboard, -1 port."""
    rings = []
    for (y, r, rk) in NAC_ROWS:
        pts = _superellipse(r, r, 2.0, 16, rot=math.tau / 32)
        rings.append([V((side * (NAC_X + px), y + NAC_RAKE * rk * (pz / NAC_R), NAC_Z + pz)) for px, pz in pts])
    bm, vr = kit.loft(rings, cap_start=True, cap_end=True)
    kit.crease_path(bm, vr[3], 0.3, closed=True)
    kit.crease_path(bm, vr[5], 0.3, closed=True)
    kit.crease_path(bm, vr[-1], 0.9, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "nacelle")


def spike(levels=2, side=1):
    """Intake centre body."""
    rings = []
    for y, r in SPIKE_ROWS:
        pts = _superellipse(r, r, 2.0, 12)
        rings.append([V((side * (NAC_X + px), y + NAC_RAKE * 0.2 * (pz / NAC_R), NAC_Z + pz)) for px, pz in pts])
    bm, vr = kit.loft(rings)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "spike")


def _airfoil(origin, chord_dir, thick_dir, chord, t, blunt=0.035):
    o, c, k = V(origin), V(chord_dir), V(thick_dir)
    prof = [(0.0, 0.0), (0.10, 0.40), (0.38, 0.50), (0.74, 0.34), (1.0, blunt / max(t, 1e-6)),
            (1.0, -blunt / max(t, 1e-6)), (0.74, -0.30), (0.38, -0.46), (0.10, -0.38)]
    return [o + c * (u * chord) + k * (v * t) for u, v in prof]


def wing(levels=3, side=1):
    rings = []
    for (x, le, te, z, t) in WING:
        rings.append(_airfoil((side * x, le, z), (0, -1, 0), (0, 0, 1), le - te, t))
    bm, vr = kit.loft(rings)
    n = len(vr)
    kit.crease_path(bm, [vr[i][0] for i in range(n)], 0.45)
    kit.crease_path(bm, [vr[i][4] for i in range(n)], 0.8)
    kit.crease_path(bm, [vr[i][5] for i in range(n)], 0.8)
    kit.crease_path(bm, vr[-1], 0.7, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "wing")


def fin(levels=3, side=1):
    ca, sa = math.cos(math.radians(FIN_CANT)), math.sin(math.radians(FIN_CANT))
    up = V((side * sa, 0.0, ca))
    th = V((side * ca, 0.0, -sa))
    rings = []
    for (d, le, te, t) in FIN:
        o = V((side * FIN_ROOT[0], le, FIN_ROOT[1])) + up * d
        rings.append(_airfoil(o, (0, -1, 0), th, le - te, t, blunt=0.02))
    bm, vr = kit.loft(rings)
    n = len(vr)
    kit.crease_path(bm, [vr[i][0] for i in range(n)], 0.5)
    kit.crease_path(bm, [vr[i][4] for i in range(n)], 0.8)
    kit.crease_path(bm, [vr[i][5] for i in range(n)], 0.8)
    kit.crease_path(bm, vr[-1], 0.8, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "fin")


def tip_pod(levels=3, side=1):
    rows = [(POD_Y0 + 0.9, 0.04), (POD_Y0 + 0.70, 0.12), (POD_Y0 + 0.2, 0.21), (POD_Y0 - 0.6, 0.25),
            (POD_Y1 + 0.5, 0.25), (POD_Y1, 0.20)]
    rings = []
    for y, r in rows:
        pts = _superellipse(r * 1.05, r, 2.6, 8, rot=math.tau / 16)
        rings.append([V((side * (POD_X + px), y, POD_Z + pz)) for px, pz in pts])
    bm, vr = kit.loft(rings)
    kit.crease_path(bm, vr[-1], 0.9, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "pod")


CHEEK_X, CHEEK_Z = 1.50, -0.66
CHEEK_ROWS = [(1.85, 0.05), (2.12, 0.55), (2.60, 0.90), (3.05, 1.00), (3.46, 0.97)]   # y, scale
CANNON_Y = 2.55


def cheek(levels=3, side=1):
    """Cannon fairing blister on the lower flank."""
    rings = []
    for y, sc in CHEEK_ROWS:
        pts = _superellipse(0.25 * sc, 0.27 * sc, 2.7, 8, rot=math.tau / 16)
        rings.append([V((side * (CHEEK_X + px), y, CHEEK_Z + pz)) for px, pz in pts])
    bm, vr = kit.loft(rings)
    kit.crease_path(bm, vr[-1], 0.85, closed=True)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _subdivide(bm, levels, "cheek")


def bodies(levels=3):
    """name -> dense bmesh of every smooth body (both sides)."""
    out = {"fuselage": fuselage(levels)}
    for s, tag in ((1, "R"), (-1, "L")):
        out["nacelle_" + tag] = nacelle(levels, s)
        out["spike_" + tag] = spike(2, s)
        out["wing_" + tag] = wing(levels, s)
        out["fin_" + tag] = fin(levels, s)
        out["pod_" + tag] = tip_pod(levels, s)
        out["cheek_" + tag] = cheek(levels, s)
    return out
