"""ST-7 Tern landing gear: oleo legs (main / nose), gear-bay interior and bay doors.

Ship axes: +Y forward, +X starboard, +Z up, metres.
    build_gear()  - one deployed leg, origin on its attach point on the bay roof, pad soles on z = -height.
    build_bay()   - inside of the gear well, origin at the roof centre, open bottom at z = -depth.
    build_door()  - one bay door in the open (hanging) position, origin on the hinge line.
"""
import math

import bmesh
import bpy
from mathutils import Matrix

import kit
import mats
from kit import V

# plate planes: (u, v, n) - 2D outlines live in (u, v), thickness runs along n = u x v
YZ = (V((0, 1, 0)), V((0, 0, 1)), V((1, 0, 0)))
XZ = (V((1, 0, 0)), V((0, 0, 1)), V((0, -1, 0)))
XY = (V((1, 0, 0)), V((0, 1, 0)), V((0, 0, 1)))

X_AX, Y_AX, Z_AX = (1, 0, 0), (0, 1, 0), (0, 0, 1)


# ------------------------------------------------------------------------------------------
# geometry helpers (local to this module)
# ------------------------------------------------------------------------------------------
class _Groups:
    """Collects one bmesh per material key. Key 'mat|w' = bevel modifier of w millimetres on that group."""

    def __init__(self):
        self.d = {}

    def __getitem__(self, key):
        if key not in self.d:
            self.d[key] = bmesh.new()
        return self.d[key]

    def build(self, name, col, extra=()):
        objs = []
        for key, bm in self.d.items():
            if len(bm.verts) == 0:
                bm.free()
                continue
            mat, _, bw = key.partition("|")
            ob = kit.to_obj(name + "_" + key.replace("|", "_"), bm, col, [mats.get(mat)])
            if bw:
                kit.mod_bevel(ob, float(bw) * 1e-3, segs=2, angle=40.0)
                kit.apply_mods(ob)
            objs.append(ob)
        objs += list(extra)
        return kit.join(objs, name)


def _pmx(pl, off=0.0):
    u, v, n = pl
    m = Matrix((u, v, n)).transposed().to_4x4()
    m.translation = n * off
    return m


def _uv(pl, p):
    p = V(p)
    return (p.dot(pl[0]), p.dot(pl[1]))


def _off(pl, p):
    return V(p).dot(pl[2])


def _bone(a, b, ra, rb, n=8):
    """Stadium outline around 2D points a, b (end radii ra, rb), CCW, 2n+2 points."""
    a, b = V((a[0], a[1])), V((b[0], b[1]))
    d = b - a
    phi = math.atan2(d.y, d.x)
    pts = []
    for i in range(n + 1):
        t = phi - math.pi / 2 + math.pi * i / n
        pts.append((b.x + rb * math.cos(t), b.y + rb * math.sin(t)))
    for i in range(n + 1):
        t = phi + math.pi / 2 + math.pi * i / n
        pts.append((a.x + ra * math.cos(t), a.y + ra * math.sin(t)))
    return pts


def _bone_hole(a, b, ra, rb, k=0.42, n=8):
    """Lightening slot inside _bone(a, b, ra, rb) with matching vertex count."""
    a, b = V((a[0], a[1])), V((b[0], b[1]))
    d = (b - a).normalized()
    ha, hb = ra * k, rb * k
    return _bone(a + d * (ra * 1.05 + ha), b - d * (rb * 1.05 + hb), ha, hb, n)


def _lug(ba, bb, pin, r, n=10):
    """Lug outline: flat base from ba to bb, rounded around `pin` (radius r) on the far side. CCW."""
    ba, bb, p = V((ba[0], ba[1])), V((bb[0], bb[1])), V((pin[0], pin[1]))
    mid = (ba + bb) * 0.5
    d = (p - mid).normalized()
    phi = math.atan2(d.y, d.x)
    perp = V((-d.y, d.x))
    arc = [(p.x + r * math.cos(phi - math.pi / 2 + math.pi * i / n), p.y + r * math.sin(phi - math.pi / 2 + math.pi * i / n))
           for i in range(n + 1)]
    plus, minus = (ba, bb) if (ba - mid).dot(perp) > 0 else (bb, ba)
    return arc + [tuple(plus), tuple(minus)]


def _holed(bm, outer, inner, t, mx):
    """Plate with one hole: outer / inner CCW outlines with equal vertex counts."""
    n = len(outer)
    rings = [[bm.verts.new((x, y, z)) for x, y in poly] for poly, z in
             ((outer, -t / 2), (outer, t / 2), (inner, t / 2), (inner, -t / 2))]
    ob, ot, it, ib = rings
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((ot[i], ot[j], it[j], it[i]))
        bm.faces.new((ob[j], ob[i], ib[i], ib[j]))
        bm.faces.new((ob[i], ob[j], ot[j], ot[i]))
        bm.faces.new((it[i], it[j], ib[j], ib[i]))
    bmesh.ops.transform(bm, matrix=mx, verts=[v for r in rings for v in r])


def _plate(bm, pl, pts, t, off=0.0, hole=None):
    mx = _pmx(pl, off)
    if hole is None:
        kit.prism(pts, -t / 2, t / 2, bm=bm, mx=mx)
    else:
        _holed(bm, pts, hole, t, mx)


def _bone3(bm, pl, a, b, ra, rb, t, doff=0.0, holed=False, k=0.42):
    a2, b2 = _uv(pl, a), _uv(pl, b)
    hole = _bone_hole(a2, b2, ra, rb, k) if holed else None
    _plate(bm, pl, _bone(a2, b2, ra, rb), t, _off(pl, a) + doff, hole)


def _cyl(bm, p0, p1, r, segs=32, ch=0.0, caps=True):
    p0, p1 = V(p0), V(p1)
    d = p1 - p0
    kit.cylinder(r, 0.0, d.length, segs, chamfer=ch, bm=bm, mx=kit.frame(p0, d), caps=caps)


def _cyla(bm, c, axis, r, length, segs=24, ch=0.0):
    a, c = V(axis).normalized(), V(c)
    _cyl(bm, c - a * (length / 2), c + a * (length / 2), r, segs, ch)


def _ringa(bm, c, axis, ro, ri, length, segs=48, ch=0.0):
    kit.ring(ro, ri, -length / 2, length / 2, segs, chamfer=ch, bm=bm, mx=kit.frame(c, axis))


def _beam(bm, p0, p1, w, h, c, xhint=X_AX, taper=1.0):
    p0 = V(p0)
    d = V(p1) - p0
    kit.prism(kit.chamfer_rect2(w, h, c), 0.0, d.length, bm=bm, mx=kit.frame(p0, d, xhint), taper=taper)


def _hex(bm, pos, nrm, r, h):
    """Hex bolt head / nut. Tiny ones skip the chamfer (the Bevel shader rounds them anyway)."""
    ch = min(0.0015, h * 0.3) if r >= 0.0065 else 0.0
    kit.cylinder(r, 0.0, h, 6, chamfer=ch, bm=bm, mx=kit.frame(pos, nrm))


def _pin(G, c, axis, r, length):
    """Pin through a lug stack: `length` = distance between the outer faces; nut on +axis, head on -axis."""
    a, c = V(axis).normalized(), V(c)
    _cyla(G["metal_steel"], c, a, r, length + 2.4 * r, 16, r * 0.3)
    _hex(G["metal_dark"], c + a * (length / 2), a, r * 1.75, r * 0.85)
    kit.cylinder(r * 1.7, 0.0, r * 0.55, 16 if r > 0.011 else 12, chamfer=r * 0.18, bm=G["metal_dark"],
                 mx=kit.frame(c - a * (length / 2), -a))


def _clevis(G, key, pl, base, pin, gap, t, rb, rp, pin_r, base2=None):
    """Two lug plates (parallel to plane `pl`) straddling `gap`, from `base` to `pin`, plus the pin."""
    b2, p2 = _uv(pl, base), _uv(pl, pin)
    off = _off(pl, pin)
    for sgn in (-1, 1):
        if base2 is None:
            pts = _bone(b2, p2, rb, rp)
        else:
            pts = _lug(_uv(pl, base), _uv(pl, base2), p2, rp)
        _plate(G[key], pl, pts, t, off + sgn * (gap / 2 + t / 2))
    _pin(G, pin, pl[2], pin_r, gap + 2 * t)


def _helix(bm, p0, p1, R, wire, turns, spt=14):
    p0 = V(p0)
    d = V(p1) - p0
    L = d.length
    mx = kit.frame(p0, d)
    n = max(8, int(turns * spt))
    pts = [mx @ V((R * math.cos(math.tau * turns * i / n), R * math.sin(math.tau * turns * i / n), L * i / n))
           for i in range(n + 1)]
    kit.tube(pts, wire, 6, bm=bm)


def _ray_poly(poly, ang):
    dx, dy = math.cos(ang), math.sin(ang)
    best = 1e9
    n = len(poly)
    for i in range(n):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        den = dx * ey - dy * ex
        if abs(den) < 1e-12:
            continue
        t = (ax * ey - ay * ex) / den
        u = (dy * ax - dx * ay) / den
        if t > 0 and -1e-6 <= u <= 1 + 1e-6:
            best = min(best, t)
    return best


def _clip(poly, nx, ny, c):
    """Keep the part of a convex polygon where nx*x + ny*y <= c."""
    out = []
    n = len(poly)
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        fp = nx * p[0] + ny * p[1] - c
        fq = nx * q[0] + ny * q[1] - c
        if fp <= 0:
            out.append(p)
        if fp * fq < 0:
            t = fp / (fp - fq)
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def _area(poly):
    return 0.5 * abs(sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
                         for i in range(len(poly))))


def _scale2(poly, s):
    return [(x * s, y * s) for x, y in poly]


def _tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


# ------------------------------------------------------------------------------------------
# landing gear leg
# ------------------------------------------------------------------------------------------
GEAR_KINDS = {
    "main": dict(s=1.0, rc=0.085, rp=0.055, pad=(0.48, 0.64), expose=0.36, side_brace=True, light=False),
    "nose": dict(s=0.82, rc=0.070, rp=0.045, pad=(0.36, 0.46), expose=0.31, side_brace=False, light=True),
}


def build_gear(col=None, height=2.30, bay_depth=0.40, kind="main", name="Gear"):
    """Deployed landing leg (oleo strut, trunnion, drag brace, actuator, torque links, gimballed pad)."""
    k = GEAR_KINDS[kind]
    s, rc, rp = k["s"], k["rc"], k["rp"]
    H = height
    G = _Groups()

    # ---- vertical stations -------------------------------------------------------------
    z_sole = -H
    zp0 = z_sole + 0.024            # rubber -> pad plate
    zp1 = zp0 + 0.07                # pad top face
    z_gim = zp1 + 0.065 * s         # roll gimbal pin (along Y)
    z_ball = zp1 + 0.155 * s        # pitch pivot (along X) in the fork
    z_fh0 = z_ball + 0.055 * s      # fork head (axle fitting) bottom
    z_fh1 = z_fh0 + 0.085 * s       # fork head top = piston bottom
    z_g = z_fh1 + k["expose"]       # gland nut bottom
    zA = z_g + 0.04                 # outer cylinder bottom
    z_tr = -0.13 * s                # trunnion axis
    z_br = -0.36 * H                # drag-brace collar
    z_hn = -0.36 * s                # retraction-actuator horn
    z_jb = z_g + 0.40               # hydraulic junction box centre
    R1 = rc + 0.016                 # bearing housing radius

    _foot(G, k, s, rp, H, zp0, zp1, z_gim, z_ball, z_fh0, z_fh1)

    # ---- piston + gland ----------------------------------------------------------------
    _cyl(G["metal_chrome"], (0, 0, z_fh1 - 0.01), (0, 0, z_g + 0.30), rp, 48)
    kit.ring(rp + 0.006, rp - 0.002, z_g - 0.008, z_g + 0.001, 48, chamfer=0.002, bm=G["rubber"])   # wiper seal
    kit.ring(R1 - 0.003, rp + 0.001, z_g, zA + 0.002, 48, chamfer=0.004, bm=G["metal_steel"])        # gland nut
    for i in range(8):   # spanner lugs on the gland nut
        a = math.tau * (i + 0.5) / 8
        mx = kit.T(math.cos(a) * (R1 - 0.002), math.sin(a) * (R1 - 0.002), (z_g + zA) / 2) @ kit.R('Z', math.degrees(a))
        kit.box((0.012, 0.016, 0.026), bevel=0.002, bm=G["metal_steel"], mx=mx)

    # ---- outer cylinder (white casting) -------------------------------------------------
    rc2 = rc + 0.012                # upper barrel (above the drag-brace collar) is a little fatter

    def r_at(z):
        return rc2 if z > z_br else rc
    prof = [(0.0, zA), (R1 - 0.006, zA), (R1, zA + 0.006), (R1, zA + 0.13), (rc + 0.002, zA + 0.19),
            (rc, zA + 0.20), (rc, z_br - 0.03), (rc2, z_br), (rc2, z_tr - 0.11), (rc2 + 0.012, z_tr - 0.085),
            (rc2 + 0.012, z_tr), (0.0, z_tr)]
    kit.lathe(prof, 48, bm=G["paint_white"])
    # thin steel bands
    for zz in (zA + 0.215, z_tr - 0.13):
        rz = r_at(zz)
        kit.ring(rz + 0.006, rz - 0.004, zz - 0.009, zz + 0.009, 48, chamfer=0.002, bm=G["metal_steel"])
    # cast stiffening ribs on the upper barrel (diagonal quadrants, clear of lugs and hydraulic lines)
    zr0, zr1 = z_br + 0.07, z_tr - 0.12
    for q in (45, 135, 225, 315):
        a = math.radians(q)
        mx = kit.T(math.cos(a) * rc2, math.sin(a) * rc2, (zr0 + zr1) / 2) @ kit.R('Z', q)
        kit.box((0.014, 0.034 * s, zr1 - zr0), bevel=0.0045, bm=G["paint_white"], mx=mx)
    # nitrogen charging valve + data placard (starboard side, upper barrel)
    zv = z_tr - 0.21
    _cyl(G["metal_steel"], (rc2 - 0.006, 0, zv), (rc2 + 0.016, 0, zv), 0.017, 20, 0.003)
    _hex(G["metal_brass"], V((rc2 + 0.016, 0, zv)), V((1, 0, 0)), 0.009, 0.014)
    _cyl(G["metal_dark"], (rc2 + 0.029, 0, zv), (rc2 + 0.040, 0, zv), 0.0075, 12, 0.002)
    kit.box((0.004, 0.05, 0.075), center=(rc2 + 0.0012, 0, zv - 0.10), bevel=0.0012, bm=G["paint_dark"])
    for cy in (-0.019, 0.019):
        for cz in (-0.03, 0.03):
            _hex(G["metal_steel"], V((rc2 + 0.003, cy, zv - 0.10 + cz)), V((1, 0, 0)), 0.003, 0.002)

    # ---- trunnion / attach block -------------------------------------------------------
    xl = 0.20 * s
    lug_t = 0.04
    kit.box((0.60 * s, 0.30 * s, 0.035), center=(0, 0, -0.0175), bevel=0.008, bm=G["metal_dark"])   # roof plate
    for sx in (-1, 1):
        pts = _lug((-0.11 * s, -0.035), (0.11 * s, -0.035), (0.0, z_tr), 0.068 * s)
        _plate(G["metal_dark|3"], YZ, pts, lug_t, sx * xl)
        for sy in (-1, 1):   # gussets on the outside of each lug
            g = [(0.0, -0.035), (0.075 * s, -0.035), (0.0, -0.035 - 0.085 * s)]
            g = [(sx * (xl + lug_t / 2) + sx * x, z) for x, z in g]
            if sx < 0:
                g = list(reversed(g))
            _plate(G["metal_dark|2"], XZ, g, 0.012, -sy * 0.075 * s)
        # bolts on the roof plate
        for bx in (0.25 * s,):
            for by in (-0.11 * s, 0.11 * s):
                _hex(G["metal_steel"], V((sx * bx, by, -0.035)), V((0, 0, -1)), 0.011, 0.008)
    tube_len = 2 * xl + lug_t + 0.012
    _cyla(G["metal_steel"], (0, 0, z_tr), X_AX, 0.045 * s, tube_len, 40, 0.004)       # trunnion shaft
    for sx in (-1, 1):
        _hex(G["metal_dark"], V((sx * tube_len / 2, 0, z_tr)), V((sx, 0, 0)), 0.05 * s, 0.022)
        _cyla(G["metal_brass"], (sx * (tube_len / 2 + 0.03), 0, z_tr), X_AX, 0.007, 0.018, 12, 0.002)  # grease nipple
    # trunnion casting on top of the cylinder
    cw = 2 * (xl - lug_t / 2 - 0.004)
    kit.box((cw, 0.16 * s, 0.14 * s), center=(0, 0, z_tr + 0.005), bevel=0.012, bm=G["paint_white"])
    kit.box((cw - 0.03, 0.18 * s, 0.05 * s), center=(0, 0, z_tr - 0.045 * s), bevel=0.008, bm=G["paint_white"])

    # ---- collars on the cylinder ----------------------------------------------------------
    kit.ring(rc2 + 0.016, rc - 0.005, z_br - 0.05, z_br + 0.05, 48, chamfer=0.006, bm=G["metal_steel"])
    kit.ring(rc2 + 0.014, rc - 0.005, z_hn - 0.04, z_hn + 0.04, 48, chamfer=0.005, bm=G["metal_steel"])
    for zz in (z_br - 0.05, z_br + 0.05):   # collar bolt rows
        for i in range(10):
            a = math.tau * (i + 0.5) / 10
            if abs(math.cos(a)) > 0.93 or abs(math.sin(a)) > 0.93:
                continue
            n = V((math.cos(a), math.sin(a), 0))
            _hex(G["metal_dark"], n * (rc2 + 0.008) + V((0, 0, zz)), V((0, 0, 1 if zz > z_br else -1)), 0.006,
                 0.005)

    # ---- drag brace (two-piece, knee hinge) -------------------------------------------
    A = V((0, -(rc2 + 0.065), z_br))
    B = V((0, -0.60 * s, -0.075))
    d = (B - A)
    perp = V((0, d.z, -d.y)).normalized()     # in the YZ plane
    if perp.y > 0:
        perp = -perp                          # knee kinks aft/down
    K = (A + B) * 0.5 + perp * 0.035
    # collar clevis -> A
    _clevis(G, "metal_steel|2", YZ, V((0, -(rc - 0.01), z_br)), A, 0.046, 0.016, 0.045 * s, 0.032 * s, 0.015 * s)
    # lower member: tube with eyes
    rl = 0.026 * s + 0.004
    eye = 0.033 * s
    for P in (A, K):
        _cyla(G["metal_dark"], P, X_AX, eye, 0.044, 24, 0.004)
    dk = (K - A).normalized()
    _cyl(G["metal_dark"], A + dk * eye * 0.85, K - dk * eye * 0.85, rl, 24, 0.004)
    _cyla(G["metal_steel"], A.lerp(K, 0.5), dk, rl + 0.006, 0.05, 24, 0.003)
    # upper member: forked, two holed plates (white casting) + spacers
    for sx in (-1, 1):
        _bone3(G["paint_white|2"], YZ, K, B, 0.036 * s, 0.034 * s, 0.014, doff=sx * 0.030, holed=True, k=0.40)
    for f in (0.36, 0.64):
        _cyla(G["metal_dark"], K.lerp(B, f), X_AX, 0.012 * s, 0.074, 16, 0.002)
    _pin(G, K, X_AX, 0.014 * s, 0.074)
    _pin(G, A, X_AX, 0.015 * s, 0.046 + 0.032)
    # roof bracket at B
    _roof_bracket(G, B, gap=0.074, t=0.016, rp=0.036 * s, pin_r=0.016 * s, axis="x")
    # knee lock indicator (small accent flag)
    kit.box((0.02, 0.03, 0.012), center=K + V((0.046, 0, 0.0)), bevel=0.002, bm=G["paint_accent"])

    # ---- retraction actuator ---------------------------------------------------------------
    Rr = V((0, 0.52 * s, -0.075))
    Hn = V((0, rc2 + 0.062, z_hn))
    _clevis(G, "metal_steel|2", YZ, V((0, rc - 0.01, z_hn)), Hn, 0.038, 0.014, 0.036, 0.026, 0.012)
    _roof_bracket(G, Rr, gap=0.046, t=0.016, rp=0.032, pin_r=0.014, axis="x")
    _actuator(G, Rr, Hn, rb=0.034 * s + 0.004, rr=0.016 * s + 0.002, eye_r=0.026, eye_w=0.044, eye_w2=0.036)

    # ---- side brace (main gear) --------------------------------------------------------
    if k["side_brace"]:
        S0 = V((rc2 + 0.06, 0, z_br))
        S1 = V((0.30 * s, 0, -0.075))
        _clevis(G, "metal_steel|2", XZ, V((rc - 0.01, 0, z_br)), S0, 0.032, 0.014, 0.035, 0.026, 0.011)
        _roof_bracket(G, S1, gap=0.032, t=0.014, rp=0.03, pin_r=0.011, axis="y")
        ds = (S1 - S0).normalized()
        for P in (S0, S1):
            _cyla(G["metal_dark"], P, Y_AX, 0.024, 0.030, 20, 0.003)
        _cyl(G["metal_dark"], S0 + ds * 0.02, S1 - ds * 0.02, 0.018, 20, 0.003)
        _cyla(G["metal_steel"], S0.lerp(S1, 0.5), ds, 0.024, 0.07, 6, 0.003)   # turnbuckle

    # ---- hydraulic lines, clamps, junction box ---------------------------------------------
    xo = -(rc + 0.042)
    jb_h = 0.15 * s
    for yi in (-0.022, 0.022):
        pts = [(-0.14 * s, -0.11 * s + yi, -0.02), (-0.14 * s, -0.11 * s + yi, -0.24 * s),
               (xo, yi, -0.36 * s), (xo, yi, z_jb + jb_h / 2)]
        kit.tube(pts, 0.007, 10, bm=G["metal_steel"], fillet=0.05)
        _cyla(G["metal_brass"], (xo, yi, z_jb + jb_h / 2 + 0.006), Z_AX, 0.0115, 0.014, 6, 0.0015)
    zc_list = []
    span_top, span_bot = -0.46 * s, z_jb + jb_h / 2 + 0.06
    nclamp = max(2, int(round((span_top - span_bot) / 0.26)) + 1)
    for i in range(nclamp):
        zc = span_top + (span_bot - span_top) * i / (nclamp - 1)
        if abs(zc - z_br) < 0.08 or abs(zc - z_hn) < 0.07:
            continue
        zc_list.append(zc)
    for zc in zc_list:
        rz = r_at(zc)
        kit.ring(rz + 0.006, rz - 0.003, zc - 0.009, zc + 0.009, 48, chamfer=0.002, bm=G["metal_steel"])
        kit.box((-xo + 0.010 - rz, 0.075, 0.024), center=((xo - 0.010 - rz) / 2, 0, zc), bevel=0.004,
                bm=G["metal_dark"])
        for yi in (-0.022, 0.022):
            _hex(G["metal_steel"], V((xo - 0.010, yi * 1.9, zc)), V((-1, 0, 0)), 0.006, 0.005)
    # junction box
    kit.box((0.030, 0.13 * s, jb_h + 0.03), center=(-(rc + 0.011), 0, z_jb), bevel=0.004, bm=G["metal_dark"])
    kit.box((0.046, 0.11 * s, jb_h), center=(xo, 0, z_jb), bevel=0.007, bm=G["metal_dark"])
    kit.box((0.006, 0.08 * s, jb_h * 0.7), center=(xo - 0.024, 0, z_jb), bevel=0.002, bm=G["paint_grey"])
    for cy in (-0.03 * s, 0.03 * s):
        for cz in (-jb_h * 0.28, jb_h * 0.28):
            _hex(G["metal_steel"], V((xo - 0.027, cy, z_jb + cz)), V((-1, 0, 0)), 0.005, 0.004)
    _cyla(G["plastic_black"], (xo - 0.03, 0.0, z_jb - jb_h * 0.05), X_AX, 0.012, 0.02, 16, 0.002)  # sensor plug
    # flex hoses: junction box -> piston bottom collar (service loop)
    zfm = z_fh1 + 0.022
    for yi in (-0.022, 0.022):
        p0 = V((xo, yi, z_jb - jb_h / 2))
        _cyla(G["metal_brass"], p0 - V((0, 0, 0.006)), Z_AX, 0.0115, 0.014, 6, 0.0015)
        pts = [p0, p0 - V((0, 0, 0.06)), V((-(rc + 0.10), yi * 1.4, (z_jb + zfm) * 0.5 - 0.02)),
               V((-(rp + 0.075), yi, zfm + 0.06)), V((-(rp + 0.02), yi, zfm))]
        kit.tube(pts, 0.0095, 12, bm=G["plastic_black"], fillet=0.07)
        _cyla(G["metal_brass"], (-(rp + 0.026), yi, zfm), X_AX, 0.012, 0.016, 6, 0.0015)

    # ---- torque links (scissor) -----------------------------------------------------------
    U = V((0, rc + 0.05, zA + 0.10))
    yfh = 0.065 * s
    L = V((0, yfh + 0.045, (z_fh0 + z_fh1) * 0.5))
    Ap = V((0, max(U.y, L.y) + 0.17 * s, (U.z + L.z) * 0.5))
    _bone3(G["metal_steel|2"], YZ, V((0, R1 - 0.012, U.z)), U, 0.034 * s, 0.026 * s, 0.034)     # housing lug
    for sx in (-1, 1):
        _bone3(G["metal_dark|2"], YZ, U, Ap, 0.033 * s, 0.028 * s, 0.016, doff=sx * 0.027, holed=True)
        _bone3(G["metal_steel|2"], YZ, V((0, yfh - 0.03, L.z)), L, 0.03 * s, 0.026 * s, 0.018, doff=sx * 0.026)
    _bone3(G["metal_dark|2"], YZ, Ap, L, 0.026 * s, 0.030 * s, 0.032, holed=True)
    for P in (U, Ap, L):
        _pin(G, P, X_AX, 0.012 * s, 0.070)

    # ---- nose: landing / taxi light ----------------------------------------------------------
    if k["light"]:
        _nose_light(G, rc, z_g + 0.47)

    ob = G.build(name, col)
    zs = [v.co.z for v in ob.data.vertices]
    print("GEAR", name, kind, "tris", _tris(ob), "z range", round(min(zs), 4), round(max(zs), 4))
    return ob


def _roof_bracket(G, P, gap, t, rp, pin_r, axis="x"):
    """Clevis hanging from the bay roof (z = 0) down to pin P; pin along X or Y."""
    P = V(P)
    if axis == "x":
        pl, ax = YZ, X_AX
        base_size = (gap + 2 * t + 0.03, 0.14, 0.03)
        ba, bb = (P.y - 0.065, -0.03), (P.y + 0.065, -0.03)
    else:
        pl, ax = XZ, Y_AX
        base_size = (0.13, gap + 2 * t + 0.03, 0.03)
        ba, bb = (P.x - 0.06, -0.03), (P.x + 0.06, -0.03)
    kit.box(base_size, center=(P.x, P.y, -0.015), bevel=0.006, bm=G["metal_dark"])
    for sgn in (-1, 1):
        pts = _lug(ba, bb, _uv(pl, P), rp)
        _plate(G["metal_dark|2"], pl, pts, t, _off(pl, P) + sgn * (gap / 2 + t / 2))
    _pin(G, P, ax, pin_r, gap + 2 * t)
    # base bolts
    for i in range(4):
        sx, sy = (-1, 1)[i % 2], (-1, 1)[i // 2]
        _hex(G["metal_steel"], V((P.x + sx * (base_size[0] / 2 - 0.012), P.y + sy * (base_size[1] / 2 - 0.012), -0.03)),
             V((0, 0, -1)), 0.007, 0.006)


def _actuator(G, P0, P1, rb, rr, eye_r, eye_w, eye_w2):
    """Hydraulic jack: barrel at P0 (eye along X), chrome rod to P1 (eye along X)."""
    P0, P1 = V(P0), V(P1)
    d = P1 - P0
    Ln = d.length
    dn = d.normalized()
    mx = kit.frame(P0, d)
    t0, t1 = eye_r * 0.8, eye_r * 0.8 + 0.62 * (Ln - 2 * eye_r)
    prof = [(0.0, t0), (rb * 0.75, t0), (rb, t0 + 0.012), (rb, t1 - 0.035), (rb + 0.006, t1 - 0.03),
            (rb + 0.006, t1 - 0.004), (rr + 0.006, t1), (0.0, t1)]
    kit.lathe(prof, 32, bm=G["paint_grey"], mx=mx)
    for tt in (t0 + 0.03, (t0 + t1) * 0.5):
        kit.ring(rb + 0.004, rb - 0.003, tt - 0.007, tt + 0.007, 32, chamfer=0.0015, bm=G["metal_steel"], mx=mx)
    _cyl(G["metal_chrome"], P0 + dn * (t1 - 0.01), P1 - dn * eye_r * 0.7, rr, 24)
    _cyla(G["metal_dark"], P0, X_AX, eye_r, eye_w, 24, 0.004)
    _cyla(G["metal_steel"], P1, X_AX, eye_r * 0.85, eye_w2, 24, 0.003)
    _cyl(G["metal_steel"], P1 - dn * (eye_r * 1.9), P1 - dn * (eye_r * 0.5), rr + 0.005, 16, 0.002)   # rod end
    # hydraulic ports + short lines up to the roof
    side = V((1, 0, 0))
    for tt in (t0 + 0.05, t1 - 0.05):
        p = P0 + dn * tt + side * rb
        _cyla(G["metal_brass"], p + side * 0.008, side, 0.009, 0.018, 6, 0.0015)
        q = p + side * 0.018
        kit.tube([q, q + side * 0.02, V((q.x + 0.03, q.y, -0.10)), V((q.x + 0.03, q.y, 0.0))], 0.0055, 8,
                 bm=G["metal_steel"], fillet=0.025)


def _foot(G, k, s, rp, H, zp0, zp1, z_gim, z_ball, z_fh0, z_fh1):
    px, py = k["pad"]
    octo = kit.chamfer_rect2(px, py, 0.25 * px)
    top_s = 0.94
    # pad plate
    kit.prism(octo, zp0, zp1, bm=G["metal_dark|8"], taper=top_s)
    # hazard band on the pad rim
    f0, f1 = 0.22, 0.52
    s0, s1 = 1 - (1 - top_s) * f0, 1 - (1 - top_s) * f1
    eps = 1 + 0.004 / (px / 2)
    kit.prism(_scale2(octo, s0 * eps), zp0 + 0.07 * f0, zp0 + 0.07 * f1, bm=G["paint_hazard"], taper=s1 / s0)
    # doubler plate
    dbl = _scale2(octo, 0.60)
    kit.prism(dbl, zp1 - 0.002, zp1 + 0.014, bm=G["metal_steel|3"], taper=0.97)
    # rubber sole blocks
    sole = kit.offset_convex2(octo, -0.014)
    xs = [-1.0, -px / 6, px / 6, 1.0]
    ys = [-1.0, -py / 4, 0.0, py / 4, 1.0]
    gw = 0.008
    for i in range(3):
        for j in range(4):
            p = sole
            x0, x1 = xs[i] + (gw if i else 0), xs[i + 1] - (gw if i < 2 else 0)
            y0, y1 = ys[j] + (gw if j else 0), ys[j + 1] - (gw if j < 3 else 0)
            p = _clip(p, -1, 0, -x0)
            p = _clip(p, 1, 0, x1)
            p = _clip(p, 0, -1, -y0)
            p = _clip(p, 0, 1, y1)
            if len(p) >= 3 and _area(p) > 1e-3:
                kit.prism(p, -H, zp0 + 0.004, bm=G["rubber|3"])
    # radial ribs on the top face
    top = _scale2(octo, top_s)
    r0 = 0.10 * s
    diag = math.atan2(py / 2 - 0.125 * px, px / 2 - 0.125 * px)
    rib_angles = [0.0, math.pi / 2, math.pi, 1.5 * math.pi, diag, math.pi - diag, math.pi + diag, -diag]
    for ang in rib_angles:
        r1 = _ray_poly(top, ang) - 0.045
        pl = (V((math.cos(ang), math.sin(ang), 0)), V((0, 0, 1)), V((math.sin(ang), -math.cos(ang), 0)))
        h0, h1 = 0.06 * s, 0.014
        pts = [(r0, zp1), (r1, zp1), (r1, zp1 + h1), (r0 + 0.03, zp1 + h0), (r0, zp1 + h0)]
        _plate(G["metal_dark|2"], pl, pts, 0.016, 0.0)
    # bolt rows (skip where a rib crosses)
    def clear_of_ribs(x, y, w):
        rr = math.hypot(x, y)
        a = math.atan2(y, x)
        for ang in rib_angles:
            da = (a - ang + math.pi) % math.tau - math.pi
            if abs(da) < math.pi / 2 and rr * abs(math.sin(da)) < w:
                return False
        return True
    for (x, y) in kit.outline_points(top, 0.075, inset=0.024):
        if clear_of_ribs(x, y, 0.022):
            _hex(G["metal_steel"], V((x, y, zp1 - 0.001)), V((0, 0, 1)), 0.0105, 0.009)
    for (x, y) in kit.outline_points(_scale2(dbl, 0.97), 0.06, inset=0.016):
        if clear_of_ribs(x, y, 0.02):
            _hex(G["metal_steel"], V((x, y, zp1 + 0.013)), V((0, 0, 1)), 0.008, 0.007)
    # pedestal
    kit.cylinder(0.105 * s, zp1 + 0.008, zp1 + 0.034, 40, chamfer=0.006, bm=G["metal_steel"])
    kit.cylinder(0.075 * s, zp1 + 0.030, zp1 + 0.042, 32, chamfer=0.004, bm=G["metal_dark"])
    # roll gimbal: lugs in the XZ plane, pin along Y
    gy = 0.046 * s
    for sy in (-1, 1):
        pts = _lug((-0.065 * s, zp1 + 0.03), (0.065 * s, zp1 + 0.03), (0.0, z_gim), 0.036 * s)
        _plate(G["metal_dark|2"], XZ, pts, 0.018, -sy * (gy + 0.009))
    kit.box((0.08 * s, 2 * gy - 0.004, 0.072 * s), center=(0, 0, z_gim), bevel=0.007, bm=G["metal_steel"])
    _pin(G, V((0, 0, z_gim)), Y_AX, 0.015 * s, 2 * (gy + 0.018))
    # pitch tongue (YZ plane) up into the fork
    tw = 0.05 * s
    _bone3(G["metal_steel|2"], YZ, V((0, 0, z_gim + 0.01)), V((0, 0, z_ball)), 0.036 * s, 0.042 * s, tw)
    # fork cheeks + fork head
    xc = tw / 2 + 0.014
    for sx in (-1, 1):
        _bone3(G["paint_white|2"], YZ, V((0, 0, z_ball)), V((0, 0, z_fh0 + 0.02)), 0.05 * s, 0.058 * s, 0.022,
               doff=sx * xc)
    _pin(G, V((0, 0, z_ball)), X_AX, 0.017 * s, 2 * (xc + 0.011))
    xh = xc + 0.011 + 0.006
    kit.box((2 * xh, 0.13 * s, z_fh1 - z_fh0), center=(0, 0, (z_fh0 + z_fh1) / 2), bevel=0.009, bm=G["paint_white"])
    kit.cylinder(rp + 0.018, z_fh1 - 0.012, z_fh1 + 0.038, 48, chamfer=0.005, bm=G["metal_steel"])
    for i in range(6):   # collar bolts
        a = math.tau * (i + 0.5) / 6
        _hex(G["metal_dark"], V((math.cos(a) * (rp + 0.009), math.sin(a) * (rp + 0.009), z_fh1 + 0.038)),
             V((0, 0, 1)), 0.0065, 0.006)
    # pad centring dampers with springs (both sides, along X)
    for sx in (-1, 1):
        top_eye = V((sx * (xh + 0.024), 0, z_fh0 + 0.024))
        bot_eye = V((sx * (0.17 * s + 0.02), 0, zp1 + 0.048 * s))
        kit.box((0.03, 0.04, 0.034), center=(sx * (xh + 0.006), 0, z_fh0 + 0.024), bevel=0.004, bm=G["paint_white"])
        kit.box((0.04 * s, 0.036, zp1 + 0.048 * s - zp1), center=(bot_eye.x, 0, zp1 + 0.024 * s), bevel=0.004,
                bm=G["metal_dark"])
        for P in (top_eye, bot_eye):
            _cyla(G["metal_steel"], P, Y_AX, 0.014, 0.034, 16, 0.002)
            _cyla(G["metal_steel"], P, Y_AX, 0.0055, 0.046, 12, 0.001)
        dd = (bot_eye - top_eye)
        dn = dd.normalized()
        Ld = dd.length
        _cyl(G["metal_dark"], top_eye + dn * 0.012, top_eye + dn * (0.55 * Ld), 0.012, 16, 0.002)
        _cyl(G["metal_chrome"], top_eye + dn * (0.5 * Ld), bot_eye - dn * 0.01, 0.0065, 12)
        _helix(G["paint_accent"], top_eye + dn * (0.2 * Ld), bot_eye - dn * (0.16 * Ld), 0.019, 0.0028, 5.5)
        for f in (0.2, 0.84):
            _ringa(G["metal_steel"], top_eye + dn * (f * Ld), dn, 0.023, 0.006, 0.006, 20, 0.001)


def _nose_light(G, rc, z_l):
    """Landing / taxi light unit clamped to the front of the nose strut."""
    kit.ring(rc + 0.011, rc - 0.004, z_l - 0.03, z_l + 0.03, 48, chamfer=0.003, bm=G["metal_steel"])
    kit.box((0.05, 0.06, 0.045), center=(0, rc + 0.03, z_l), bevel=0.006, bm=G["metal_dark"])
    base = V((0, rc + 0.045, z_l - 0.004))
    mx = kit.frame(base, (0, 1, -0.06))
    prof = [(0.0, 0.0), (0.030, 0.0), (0.042, 0.012), (0.048, 0.05), (0.052, 0.088), (0.046, 0.090), (0.041, 0.082),
            (0.0, 0.082)]
    kit.lathe(prof, 40, bm=G["metal_dark"], mx=mx)
    kit.ring(0.054, 0.043, 0.080, 0.092, 40, chamfer=0.002, bm=G["metal_steel"], mx=mx)
    kit.cylinder(0.041, 0.078, 0.084, 40, bm=G["emit_white"], mx=mx)
    for tt in (0.016, 0.028, 0.040):   # cooling fins
        kit.ring(0.052, 0.040, tt - 0.003, tt + 0.003, 40, chamfer=0.001, bm=G["metal_steel"], mx=mx)
    # small amber taxi marker on top
    kit.cylinder(0.012, 0.0, 0.01, 16, chamfer=0.002, bm=G["emit_amber"],
                 mx=kit.frame(base + V((0, 0.06, 0.05)), (0, 0, 1)))


# ------------------------------------------------------------------------------------------
# gear bay interior
# ------------------------------------------------------------------------------------------
def build_bay(col=None, length=1.5, width=0.8, depth=0.45, name="GearBay"):
    """Gear well interior: roof at z = 0, open bottom at z = -depth, faces looking into the cavity."""
    hw, hl, D = width / 2, length / 2, depth
    G = _Groups()

    # shell (open box, faces inward, solidified outward)
    bm = bmesh.new()
    c = [bm.verts.new(p) for p in ((-hw, -hl, 0), (hw, -hl, 0), (hw, hl, 0), (-hw, hl, 0))]
    b = [bm.verts.new(p) for p in ((-hw, -hl, -D), (hw, -hl, -D), (hw, hl, -D), (-hw, hl, -D))]
    faces = [bm.faces.new(c)]
    for i in range(4):
        j = (i + 1) % 4
        faces.append(bm.faces.new((c[i], c[j], b[j], b[i])))
    centre = V((0, 0, -D / 2))
    for f in faces:
        f.normal_update()
        if f.normal.dot(centre - f.calc_center_median()) < 0:
            f.normal_flip()
    shell = kit.to_obj(name + "_shell", bm, col, [mats.get("inner_dark")], recalc=False)
    kit.mod_solidify(shell, 0.02, offset=-1.0)
    kit.mod_bevel(shell, 0.008, segs=2, angle=40.0)
    kit.apply_mods(shell)

    # frames: roof knees + wall stiffeners (T-section), along both side walls
    nfr = max(2, int(round(length / 0.36)))
    ys = [-hl + (i + 0.5) * length / nfr for i in range(nfr)]
    kd = 0.075
    for y in ys:
        for sx in (-1, 1):
            # roof knee gusset with lightening hole (XZ plane)
            u0, u1 = hw - 0.13, hw
            cx, cz = (u0 + u1) / 2, -kd / 2
            n = 16
            outer, inner = [], []
            for i in range(n):
                a = math.tau * (i + 0.5) / n
                ca, sa = math.cos(a), math.sin(a)
                t = min((u1 - u0) / 2 / max(abs(ca), 1e-6), kd / 2 / max(abs(sa), 1e-6))
                outer.append((cx + ca * t, cz + sa * t))
                inner.append((cx + ca * 0.022, cz + sa * 0.022))
            if sx < 0:
                outer = [(-x, z) for x, z in reversed(outer)]
                inner = [(-x, z) for x, z in reversed(inner)]
            _plate(G["metal_dark|1.5"], XZ, outer, 0.012, -y, hole=inner)
            # flange along the knee's lower edge
            kit.box((0.13, 0.034, 0.008), center=(sx * (hw - 0.065), y, -kd + 0.004), bevel=0.002, bm=G["metal_dark"])
            # wall stiffener web + flange
            kit.box((0.03, 0.012, D - 0.02), center=(sx * (hw - 0.015), y, -(D - 0.02) / 2), bevel=0.002,
                    bm=G["metal_dark"])
            kit.box((0.008, 0.034, D - kd - 0.02), center=(sx * (hw - 0.032), y, -kd - (D - kd - 0.02) / 2),
                    bevel=0.002, bm=G["metal_dark"])
    # roof waffle: two shallow longitudinal beams + transverse frames (shallow enough to hide inside the
    # leg's roof plate / bracket bases wherever they cross them)
    rd = 0.026
    xb = width * 0.25
    for sx in (-1, 1):
        kit.box((0.05, length - 0.01, rd), center=(sx * xb, 0, -rd / 2), bevel=0.004, bm=G["metal_dark"])
        kit.box((0.012, length - 0.01, 0.012), center=(sx * xb, 0, -rd - 0.004), bevel=0.003, bm=G["metal_dark"])
        for y in [(-hl + 0.06) + (length - 0.12) * i / 7 for i in range(8)]:
            for dx in (-0.016, 0.016):
                _hex(G["metal_steel"], V((sx * xb + dx, y, -rd)), V((0, 0, -1)), 0.005, 0.004)
    for y in ys:
        kit.box((width - 0.24, 0.03, rd * 0.8), center=(0, y, -rd * 0.4), bevel=0.004, bm=G["metal_dark"])
    # recessed roof access panels between the frames (slightly proud plates with fastener rows)
    edges = [-hl] + ys + [hl]
    for i in range(len(edges) - 1):
        y0, y1 = edges[i] + 0.03, edges[i + 1] - 0.03
        if y1 - y0 < 0.08:
            continue
        x0, x1 = -(xb - 0.04), xb - 0.04
        kit.box((x1 - x0, y1 - y0, 0.006), center=(0, (y0 + y1) / 2, -0.003), bevel=0.002, bm=G["metal_dark"])
        for (px_, py_) in kit.outline_points(kit.rect2(x1 - x0, y1 - y0, 0, (y0 + y1) / 2), 0.07, inset=0.012):
            _hex(G["metal_steel"], V((px_, py_, -0.006)), V((0, 0, -1)), 0.0035, 0.0025)
    # longitudinal stringers on the side walls
    for sx in (-1, 1):
        for zz in (-D * 0.40, -D * 0.72):
            kit.box((0.02, length - 0.004, 0.012), center=(sx * (hw - 0.010), 0, zz), bevel=0.003, bm=G["metal_dark"])
    # end-wall stiffeners
    for sy in (-1, 1):
        for x in (-width * 0.22, width * 0.22):
            kit.box((0.012, 0.028, D - 0.02), center=(x, sy * (hl - 0.014), -(D - 0.02) / 2), bevel=0.002,
                    bm=G["metal_dark"])
        kit.box((width - 0.004, 0.018, 0.012), center=(0, sy * (hl - 0.009), -D * 0.5), bevel=0.003,
                bm=G["metal_dark"])
    # door-stop lip around the opening
    for sx in (-1, 1):
        kit.box((0.022, length - 0.01, 0.026), center=(sx * (hw - 0.011), 0, -D + 0.013), bevel=0.004,
                bm=G["metal_dark"])
    for sy in (-1, 1):
        kit.box((width - 0.01, 0.022, 0.026), center=(0, sy * (hl - 0.011), -D + 0.013), bevel=0.004,
                bm=G["metal_dark"])
    # pipes along the port wall, turning down the aft end wall into a junction box
    jbx, jbz = -hw * 0.45, -D * 0.55
    for i, (zz, rr) in enumerate(((-0.105, 0.009), (-0.13, 0.007), (-0.152, 0.007))):
        xw = -hw + 0.052 + 0.0 * i
        xe = jbx - 0.04 + 0.035 * i
        pts = [(xw, hl - 0.004, zz), (xw, -hl + 0.06 + 0.012 * i, zz), (xe, -hl + 0.045, zz),
               (xe, -hl + 0.045, jbz + 0.07)]
        kit.tube(pts, rr, 12, bm=G["metal_steel" if i else "metal_brass"], fillet=0.05)
    for y in ys:
        kit.box((0.016, 0.03, 0.07), center=(-hw + 0.045, y + 0.03, -0.13), bevel=0.003, bm=G["metal_dark"])
    kit.box((0.18, 0.06, 0.13), center=(jbx + 0.015, -hl + 0.03, jbz), bevel=0.008, bm=G["metal_dark"])
    kit.box((0.14, 0.008, 0.09), center=(jbx + 0.015, -hl + 0.062, jbz), bevel=0.002, bm=G["paint_grey"])
    for cx in (-0.05, 0.05):
        for cz in (-0.035, 0.035):
            _hex(G["metal_steel"], V((jbx + 0.015 + cx, -hl + 0.066, jbz + cz)), V((0, 1, 0)), 0.005, 0.004)
    # cable harness along the starboard wall
    for i in range(3):
        zz = -0.10 - 0.012 * i
        kit.tube([(hw - 0.042, -hl + 0.004, zz), (hw - 0.042, hl - 0.004, zz)], 0.005, 8, bm=G["plastic_black"])
    for y in ys:
        kit.box((0.02, 0.022, 0.05), center=(hw - 0.040, y - 0.035, -0.112), bevel=0.003, bm=G["metal_dark"])
    # hazard placard on the forward end wall
    kit.box((0.14, 0.006, 0.06), center=(width * 0.08, hl - 0.004, -D * 0.30), bevel=0.0015, bm=G["paint_hazard"])

    ob = G.build(name, col, extra=[shell])
    print("BAY", name, "tris", _tris(ob))
    return ob


# ------------------------------------------------------------------------------------------
# bay door (open)
# ------------------------------------------------------------------------------------------
def build_door(col=None, length=1.5, width=0.42, thickness=0.035, side=1, name="GearDoor"):
    """One gear door hanging open: hinge line on the origin along Y, door from z = 0 to -width.
    side = +1: outer painted face looks towards +X (bay on the -X side); -1 mirrored."""
    hl, W, t = length / 2, width, thickness
    G = _Groups()
    skin_t = 0.010
    # outer skin plate (YZ outline, free edge corners chamfered)
    outline = kit.chamfer_rect2(length, W, 0.05, 0.0, -W / 2, corners=(1, 1, 0, 0))
    _plate(G["paint_white|3"], YZ, outline, skin_t, -skin_t / 2)
    # inner structure: perimeter frame + recessed pan + stiffeners
    fr_o = kit.offset_convex2(outline, -0.006)
    fr_i = kit.offset_convex2(outline, -0.05)
    st = t - skin_t
    _plate(G["paint_grey|2"], YZ, fr_o, st, -skin_t - st / 2 + 0.001, hole=fr_i)
    _plate(G["paint_grey|1"], YZ, fr_i, 0.006, -skin_t - 0.002)
    # cross stiffeners (hat sections) and a longitudinal one
    ncell = max(2, int(round(length / 0.30)))
    yc = [-hl + 0.05 + (length - 0.1) * i / ncell for i in range(1, ncell)]
    zin0, zin1 = -W + 0.05, -0.05
    xr = -(skin_t + 0.011)
    for y in yc:
        _beam(G["paint_grey|1.5"], (xr, y, zin0), (xr, y, zin1), 0.03, 0.022, 0.007, xhint=(0, 1, 0))
    zm = -W / 2
    _beam(G["paint_grey|1.5"], (xr, -hl + 0.05, zm), (xr, hl - 0.05, zm), 0.026, 0.022, 0.007, xhint=(0, 0, 1))
    # pressed lightening flanges in each cell
    ys_all = [-hl + 0.05] + yc + [hl - 0.05]
    for i in range(len(ys_all) - 1):
        ym = (ys_all[i] + ys_all[i + 1]) / 2
        for zz in ((zin1 + zm) / 2, (zm + zin0) / 2):
            rr = min(0.045, (ys_all[i + 1] - ys_all[i]) * 0.25, (zin1 - zm) * 0.32)
            # pressed lightening dimple: flanged lip around a recessed dish (one lathe, faces up = -X)
            prof = [(0.0, -0.003), (rr * 1.05, -0.003), (rr, 0.004), (rr * 0.84, 0.009), (rr * 0.70, 0.007),
                    (rr * 0.62, 0.0015), (0.0, 0.0015)]
            kit.lathe(prof, 16, bm=G["paint_grey"], mx=kit.frame((-skin_t - 0.005, ym, zz), (-1, 0, 0)))
    # gooseneck hinge arms (XZ plane), reaching up and inward into the bay
    narm = 3 if length > 1.0 else 2
    yarms = [-(hl - 0.14) + (2 * (hl - 0.14)) * i / (narm - 1) for i in range(narm)]
    piv = V((-0.075, 0, 0.10))
    path = [V((-t + 0.004, 0, -0.17)), V((-t - 0.04, 0, -0.12)), V((-0.10, 0, -0.03)), V((-0.10, 0, 0.05)), piv]
    path = kit.fillet_path(path, 0.05, 5)
    outline_l, outline_r = [], []
    for i, p in enumerate(path):
        a = path[max(i - 1, 0)]
        b_ = path[min(i + 1, len(path) - 1)]
        tg = (b_ - a).normalized()
        nr = V((-tg.z, 0, tg.x))
        w = 0.05 + (0.032 - 0.05) * i / (len(path) - 1)
        outline_l.append((p + nr * w / 2))
        outline_r.append((p - nr * w / 2))
    arm2d = [(p.x, p.z) for p in outline_l] + [(p.x, p.z) for p in reversed(outline_r)]
    for y in yarms:
        _plate(G["metal_dark|2"], XZ, arm2d, 0.02, -y)
        kit.box((0.012, 0.06, 0.11), center=(-t - 0.004, y, -0.17), bevel=0.003, bm=G["metal_dark"])
        _cyla(G["metal_dark"], (piv.x, y, piv.z), Y_AX, 0.022, 0.034, 16, 0.003)
        _pin(G, V((piv.x, y, piv.z)), Y_AX, 0.009, 0.034)
        for zz in (-0.14, -0.20):
            _hex(G["metal_steel"], V((-t - 0.010, y + 0.018, zz)), V((-1, 0, 0)), 0.005, 0.004)
            _hex(G["metal_steel"], V((-t - 0.010, y - 0.018, zz)), V((-1, 0, 0)), 0.005, 0.004)
    # door actuator: small jack from a door lug up into the bay
    ya = (yarms[0] + yarms[1]) * 0.5
    a0 = V((-t - 0.022, ya, -0.24))
    a1 = V((-0.20, ya, 0.14))
    kit.box((0.012, 0.05, 0.06), center=(-t - 0.004, ya, -0.24), bevel=0.003, bm=G["metal_dark"])
    _cyla(G["metal_dark"], a0, Y_AX, 0.014, 0.03, 12, 0.002)
    da = (a1 - a0).normalized()
    _cyl(G["metal_chrome"], a0 + da * 0.01, a0 + da * 0.17, 0.007, 12)
    _cyl(G["metal_dark"], a0 + da * 0.15, a1, 0.016, 16, 0.003)
    kit.ring(0.019, 0.010, 0.0, 0.01, 16, chamfer=0.002, bm=G["metal_steel"], mx=kit.frame(a0 + da * 0.15, da))

    ob = G.build(name, col)
    if side < 0:
        ob.data.transform(kit.S(-1, 1, 1))
        ob.data.flip_normals()
    print("DOOR", name, "tris", _tris(ob))
    return ob


# ------------------------------------------------------------------------------------------
# demos
# ------------------------------------------------------------------------------------------
def _slab(col, x0, x1, y0, y1, z_bot, z_top, holes, name="HullDummy"):
    """Flat white slab with rectangular openings (holes = [(hx0, hx1, hy0, hy1)])."""
    xs = sorted({x0, x1} | {h[0] for h in holes} | {h[1] for h in holes})
    ys = sorted({y0, y1} | {h[2] for h in holes} | {h[3] for h in holes})
    bm = bmesh.new()
    vmap = {}

    def vert(i, j):
        if (i, j) not in vmap:
            vmap[(i, j)] = bm.verts.new((xs[i], ys[j], z_top))
        return vmap[(i, j)]
    faces = []
    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
            if any(h[0] < cx < h[1] and h[2] < cy < h[3] for h in holes):
                continue
            faces.append(bm.faces.new((vert(i, j), vert(i + 1, j), vert(i + 1, j + 1), vert(i, j + 1))))
    ret = bmesh.ops.extrude_face_region(bm, geom=faces, use_keep_orig=True)
    nv = [g for g in ret["geom"] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=nv, vec=(0, 0, z_bot - z_top))
    ob = kit.to_obj(name, bm, col, [mats.get("paint_white")], smooth=30.0)
    kit.mod_bevel(ob, 0.008, segs=2, angle=30.0)
    kit.apply_mods(ob)
    return ob


def _assembly(col, kind, height, bay_depth, bay_len, bay_w, loc):
    x, y, z = loc
    g = build_gear(col, height=height, bay_depth=bay_depth, kind=kind, name="Gear_" + kind)
    bay = build_bay(col, length=bay_len, width=bay_w, depth=bay_depth, name="Bay_" + kind)
    dw = bay_w / 2 + 0.02
    dr = build_door(col, length=bay_len, width=dw, side=1, name="DoorR_" + kind)
    dl = build_door(col, length=bay_len, width=dw, side=-1, name="DoorL_" + kind)
    for ob, off in ((g, (0, 0, 0)), (bay, (0, 0, 0)), (dr, (bay_w / 2, 0, -bay_depth)), (dl, (-bay_w / 2, 0, -bay_depth))):
        ob.location = (x + off[0], y + off[1], z + off[2])
    m = 0.40
    slab = _slab(col, x - bay_w / 2 - m, x + bay_w / 2 + m, y - bay_len / 2 - m, y + bay_len / 2 + m, z - bay_depth,
                 z + 0.03, [(x - bay_w / 2, x + bay_w / 2, y - bay_len / 2, y + bay_len / 2)], "Hull_" + kind)
    lid = kit.to_obj("HullLid_" + kind, kit.box((bay_w + 0.04, bay_len + 0.04, 0.02), center=(x, y, z + 0.032),
                                                 bevel=0.006), col, [mats.get("paint_white")])
    slab = kit.join([slab, lid], "Hull_" + kind)
    return [g, bay, dr, dl, slab]


def demo():
    col = kit.collection("Gear")
    objs = _assembly(col, "main", 2.30, 0.40, 1.5, 0.8, (0, 0, 0))
    objs += _assembly(col, "nose", 1.90, 0.40, 1.25, 0.62, (2.5, 0, -0.40))
    return objs


def demo_legs():
    """Legs only (no hull, bay, doors)."""
    col = kit.collection("Gear")
    a = build_gear(col, 2.30, 0.40, "main", "Gear_main")
    b = build_gear(col, 1.90, 0.40, "nose", "Gear_nose")
    b.location = (1.2, 0, -0.40)
    return [a, b]


def demo_main():
    return [build_gear(kit.collection("Gear"), 2.30, 0.40, "main", "Gear_main")]


def demo_nose():
    return [build_gear(kit.collection("Gear"), 1.90, 0.40, "nose", "Gear_nose")]


def _zoom(lo, hi):
    c = [(lo[i] + hi[i]) / 2 for i in range(3)]
    ob = kit.to_obj("zoom_box", kit.box(tuple(hi[i] - lo[i] for i in range(3)), center=c))
    ob.hide_render = True
    return [ob]


def demo_foot():
    col = kit.collection("Gear")
    build_gear(col, 2.30, 0.40, "main", "Gear_main")
    return _zoom((-0.36, -0.40, -2.30), (0.36, 0.40, -1.45))


def demo_top():
    col = kit.collection("Gear")
    build_gear(col, 2.30, 0.40, "main", "Gear_main")
    return _zoom((-0.40, -0.70, -1.0), (0.40, 0.62, 0.05))


def demo_bay():
    col = kit.collection("Gear")
    bay = build_bay(col, 1.5, 0.8, 0.40)
    dr = build_door(col, 1.5, 0.42, side=1, name="DoorR")
    dl = build_door(col, 1.5, 0.42, side=-1, name="DoorL")
    dr.location = (0.4, 0, -0.40)
    dl.location = (-0.4, 0, -0.40)
    return [bay, dr, dl]


def demo_bayonly():
    return demo_bayflip(with_leg=False)


def demo_bayflip(with_leg=True):
    """Main bay + doors + leg turned upside down, so the standard (from-above) views look into the well."""
    col = kit.collection("Gear")
    objs = _assembly(col, "main", 2.30, 0.40, 1.5, 0.8, (0, 0, 0))
    if not with_leg:
        bpy.data.objects.remove(objs.pop(0))
    flip = kit.R('Y', 180.0)
    for ob in objs:
        ob.matrix_world = flip @ ob.matrix_world
    box = _zoom((-0.75, -1.05, -0.05), (0.75, 1.05, 1.05))
    return box


def demo_door():
    col = kit.collection("Gear")
    return [build_door(col, 1.5, 0.42, side=1)]
