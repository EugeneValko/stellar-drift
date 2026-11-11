"""ST-7 Tern - main engine nozzle (variable-geometry convergent/divergent fusion-plasma nozzle)
and the flush ventral VTOL lift nozzle.

    build_nozzle(col, radius=0.70, length=1.35, glow=1.0)  -> one joined mesh object
    build_vtol_nozzle(col, radius=0.22, glow=1.0)           -> one joined mesh object

Local space: +Z = exhaust direction (out of the hull for the VTOL nozzle), z = 0 = mount plane
(pod skin end / hull surface), origin on the axis. Materials are object-space procedural; the heat
tint of the petals runs along local Z, so keep the object transform (do not bake it) when mounting.
"""
import math

import bmesh
from mathutils import Matrix

import kit
import mats
from kit import TAU, V


# ------------------------------------------------------------------------------------------
# small helpers
# ------------------------------------------------------------------------------------------
def _lerp(a, b, t):
    return a + (b - a) * t


def _sstep(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def _rad(th):
    return V((math.cos(th), math.sin(th), 0.0))


def _tan(th):
    return V((-math.sin(th), math.cos(th), 0.0))


def _cp(th, rho, z, t=0.0):
    """Cylindrical point: angle th, radius rho, height z, tangential offset t."""
    return _rad(th) * rho + _tan(th) * t + V((0.0, 0.0, z))


def _rframe(th, rho=0.0, z=0.0, t=0.0):
    """Frame at a cylindrical point: local X = tangent, Y = axis (+Z), Z = radial (outwards)."""
    m = Matrix((_tan(th), V((0.0, 0.0, 1.0)), _rad(th))).transposed().to_4x4()
    m.translation = _cp(th, rho, z, t)
    return m


def _mark(bm, n0, mi):
    bm.faces.ensure_lookup_table()
    for i in range(n0, len(bm.faces)):
        bm.faces[i].material_index = mi


def _lathe_m(bm, prof, segs, close=True, mx=None, arc=TAU, start=0.0):
    """kit.lathe with a material index per profile segment: prof = [(r, z, mat), ...]; the mat of a
    point applies to the segment that starts there."""
    n0 = len(bm.faces)
    kit.lathe([(r, z) for r, z, _ in prof], segs, bm, mx, close=close, arc=arc, start=start)
    bm.faces.ensure_lookup_table()
    nseg = len(prof) if close else len(prof) - 1
    for k in range(nseg):
        for i in range(n0 + k * segs, min(n0 + (k + 1) * segs, len(bm.faces))):
            bm.faces[i].material_index = prof[k][2]


def _bolt(bm, mx, r=0.009, h=0.007, washer=True, segs=16):
    """Hex bolt head (+washer) standing on the XY plane of `mx`, pointing along its +Z."""
    z = 0.0
    if washer:
        kit.cylinder(r * 1.5, -0.001, 0.0022, segs, chamfer=0.0007, bm=bm, mx=mx)
        z = 0.0022
    kit.cylinder(r, z - 0.0005, z + h, 6, chamfer=r * 0.22, bm=bm, mx=mx @ kit.R("Z", 30.0))


def _screw(bm, mx, r=0.006, h=0.0025, segs=12):
    """Flat socket screw head (countersunk look)."""
    kit.cylinder(r, -0.001, h, segs, chamfer=h * 0.45, bm=bm, mx=mx)


def _tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


class _Groups:
    """Sub-meshes keyed by role: each gets its material list and optional bevel modifier."""

    def __init__(self, col):
        self.col = col
        self.g = {}
        self.stats = {}

    def bm(self, key, mat_list=None, bevel=0.0, segs=2, angle=30.0, smooth=35.0):
        if key not in self.g:
            self.g[key] = dict(bm=bmesh.new(), mats=mat_list, bevel=bevel, segs=segs, angle=angle, smooth=smooth)
        return self.g[key]["bm"]

    def build(self, name):
        objs = []
        for key, d in self.g.items():
            if not d["bm"].faces:
                d["bm"].free()
                continue
            ob = kit.to_obj(name + "_" + key, d["bm"], self.col, d["mats"], smooth=d["smooth"])
            if d["bevel"] > 0:
                kit.mod_bevel(ob, d["bevel"], d["segs"], d["angle"])
                kit.apply_mods(ob)
                kit.shade(ob, d["smooth"])
            self.stats[key] = _tris(ob)
            objs.append(ob)
        return kit.join(objs, name)


# ------------------------------------------------------------------------------------------
# curved plates on a cone (petals, seals, doublers)
# ------------------------------------------------------------------------------------------
class _Plate:
    """A plate lying on the surface of revolution r_fn(z), centred on angle `phi`.
    u in [-1, 1] runs across (half-angle half0 at the root -> half1 at the tip), s in [0, 1] runs
    from z0 to z1 (+ tip(u), which shapes the trailing edge), h is the height above the base surface."""

    def __init__(self, phi, half0, half1, z0, z1, r_fn, th0, th1, h0=0.0, tip=None, inward=False):
        self.sgn = -1.0 if inward else 1.0   # inward: the plate grows towards the axis (inner flaps)
        self.phi, self.half0, self.half1 = phi, half0, half1
        self.z0, self.z1, self.r_fn = z0, z1, r_fn
        self.th0, self.th1, self.h0 = th0, th1, h0
        self.tip = tip or (lambda u: 0.0)

    def th(self, s):
        return _lerp(self.th0, self.th1, s)

    def width(self, s):
        """Half width (m) at s."""
        zc = _lerp(self.z0, self.z1, s)
        return _lerp(self.half0, self.half1, s) * self.r_fn(zc)

    def at(self, u, s, h):
        zc = _lerp(self.z0, self.z1, s)
        rc = self.r_fn(zc)
        x = u * _lerp(self.half0, self.half1, s) * rc
        z = self.z0 + (self.z1 + self.tip(u) - self.z0) * s
        rr = self.r_fn(z) + self.sgn * (self.h0 + h)
        a = self.phi + x / rc
        return V((rr * math.cos(a), rr * math.sin(a), z))

    def on_top(self, u, s, lift=0.0):
        """Frame on the outer face (local +Z ~ radial out, +Y ~ along the plate)."""
        p = self.at(u, s, self.th(s) + lift)
        a = self.at(u, min(1.0, s + 0.01), self.th(s) + lift)
        b = self.at(u, max(0.0, s - 0.01), self.th(s) + lift)
        along = (a - b).normalized()
        out = V((p.x, p.y, 0.0)).normalized() * self.sgn
        out = (out - along * out.dot(along)).normalized()
        return kit.frame(p, out, along.cross(out))

    def build(self, bm, rib=None, chamfer=0.010, edge=0.35, n_s=26, rib_fade=(0.14, 0.20, 0.84, 0.96)):
        """rib = (half width, height, slope width) of a raised central spine (None = flat)."""
        rings = []
        for k in range(n_s):
            s = k / (n_s - 1)
            w = self.width(s)
            th = self.th(s)
            c = min(chamfer, w * 0.3)
            he = th * edge
            out = [(-w, he), (-w + c, th), (-0.72 * w, th), (-0.46 * w, th)]
            if rib:
                rw, rh, rc = rib
                rh *= _sstep(rib_fade[0], rib_fade[1], s) * (1.0 - _sstep(rib_fade[2], rib_fade[3], s))
                out += [(-(rw + rc), th), (-rw, th + rh), (0.0, th + rh), (rw, th + rh), (rw + rc, th)]
            else:
                out += [(-0.22 * w, th), (0.0, th), (0.22 * w, th)]
            out += [(0.46 * w, th), (0.72 * w, th), (w - c, th), (w, he)]
            inn = [(w, 0.0), (0.72 * w, 0.0), (0.46 * w, 0.0), (0.22 * w, 0.0), (0.0, 0.0), (-0.22 * w, 0.0),
                   (-0.46 * w, 0.0), (-0.72 * w, 0.0), (-w, 0.0)]
            prof = out + inn
            rings.append([self.at(x / w, s, h) for x, h in prof])
        io = len(out) // 2
        ii = len(out) + 4
        _bm, vr = kit.loft(rings, bm, cap_start=True, cap_end=False)
        last = vr[-1]
        n = len(last)
        left = [last[i] for i in list(range(ii, n)) + list(range(0, io + 1))]
        right = [last[i] for i in range(io, ii + 1)]
        bm.faces.new(left)
        bm.faces.new(right)
        return bm


# ------------------------------------------------------------------------------------------
# main nozzle
# ------------------------------------------------------------------------------------------
def build_nozzle(col=None, radius=0.70, length=1.35, glow=1.0, name="Nozzle", n_master=9, n_act=3, segs=144,
                 phase=math.pi / 2):
    """Variable-geometry C-D nozzle. +Z = exhaust, z = 0 = mount plane (pod end, r = radius*1.05).
    n_master master petals (+ as many seal petals), n_act external actuators (on every n_master/n_act-th master)."""
    R = radius
    L = length
    pitch = TAU / n_master
    zp0 = 0.15                     # master petal hinge line
    zs0 = 0.36                     # seal petals start (windows onto the actuator ring between master roots)
    chev = 0.075                   # master trailing-edge chevron depth
    r_root, r_tip = 0.985 * R, 0.79 * R
    th_m0, th_m1, th_s = 0.024, 0.015, 0.010

    def r_m(z):  # inner surface of the master petals (slight boat-tail curve)
        f = min(1.2, max(-0.2, (z - zp0) / (L - zp0)))
        return r_root + (r_tip - r_root) * f * (1.0 - 0.18 * (1.0 - f))

    def r_s(z):  # inner surface of the seal petals (tucked under the masters)
        return r_m(z) - 0.002 - th_s

    # materials
    m_heat = mats.heat_metal("nozzle_heat_%.2f" % L, axis=2, start=zp0, length=(L - zp0) * 1.12)
    m_dark = mats.get("metal_dark")
    m_steel = mats.get("metal_steel")
    m_chrome = mats.get("metal_chrome")
    m_soot = mats.get("metal_soot")
    m_inner = mats.get("inner_dark")
    m_throat = mats.heat_metal("nozzle_throat_heat", axis=2, start=-0.45, length=0.62)
    m_core = mats.emissive("nozzle_core_%.2f" % glow, (0.42, 0.72, 1.0), 12.0 * glow)
    m_blue = mats.emissive("nozzle_blue_%.2f" % glow, (0.20, 0.55, 1.0), 10.0 * glow)
    m_dim = mats.emissive("nozzle_blue_dim_%.2f" % glow, (0.08, 0.32, 1.0), 4.0 * glow)
    m_coil = mats.emissive("nozzle_coil_%.2f" % glow, (0.12, 0.45, 1.0), 36.0 * glow)
    # chamber wall: lighter, glossier refractory metal so the plasma light bounces out through the throat
    m_flap = mats.surface("nozzle_flap_soot", (0.062, 0.060, 0.058), 0.52, 0.9, 0.0, 0.1, 1.0, micro=0.6)
    m_cham = mats.surface("nozzle_chamber", (0.20, 0.21, 0.23), 0.36, 1.0, 0.0, 0.0, 0.5, micro=0.5)

    G = _Groups(col)
    petal = G.bm("petals", [m_heat], bevel=0.0025, angle=30.0)
    rivet = G.bm("rivets", [m_heat])
    cast = G.bm("cast", [m_dark, m_steel], bevel=0.004, angle=30.0)
    mech = G.bm("mech", [m_dark, m_steel, m_chrome, m_cham])
    liner = G.bm("liner", [m_soot, m_inner, m_throat, m_cham, m_flap], bevel=0.002, angle=40.0)
    emit = G.bm("emit", [m_core, m_blue, m_dim, m_coil], smooth=None)

    phis = [phase + i * pitch for i in range(n_master)]
    act_idx = [round(k * n_master / n_act) % n_master for k in range(n_act)]

    # ---------------- mount collar -----------------------------------------------------------
    c = 0.006
    ri = 0.66 * R
    prof = [
        (ri, -0.12, 0), (1.055 * R - c, -0.12, 0), (1.055 * R, -0.12 + c, 0), (1.055 * R, -0.082, 0),
        (1.046 * R, -0.077, 0), (1.046 * R, -0.066, 0), (1.055 * R, -0.061, 0), (1.055 * R, 0.040, 0),
        (1.07 * R, 0.046, 0), (1.07 * R, 0.12 - c, 0), (1.07 * R - c, 0.12, 0), (1.005 * R, 0.12, 0),
        (1.0 * R, 0.112, 0), (0.975 * R, 0.112, 0), (0.968 * R, 0.12, 0),
        (0.965 * R, 0.17 - 0.004, 0), (0.961 * R, 0.17, 0), (0.90 * R, 0.17, 0), (0.90 * R, 0.12, 0),
    ]
    _lathe_m(cast, prof, segs)
    # V-band clamp
    vb = [(1.05 * R, -0.036, 1), (1.082 * R, -0.028, 1), (1.098 * R, -0.016, 1), (1.098 * R, 0.016, 1),
          (1.082 * R, 0.028, 1), (1.05 * R, 0.036, 1)]
    _lathe_m(cast, vb, segs)
    th_latch = phase + math.pi          # V-band latch at the opposite side of the first actuator
    for sgn in (-1, 1):
        kit.box((0.028, 0.05, 0.034), (sgn * 0.026, 0.0, 0.0), bevel=0.003, segs=1, bm=cast,
                mx=_rframe(th_latch, 1.09 * R, 0.0))
    n0 = len(mech.faces)
    mxb = _rframe(th_latch, 1.09 * R + 0.006, 0.0) @ kit.R("Y", 90.0)
    kit.cylinder(0.0065, -0.065, 0.065, 12, chamfer=0.001, bm=mech, mx=mxb)
    for sgn in (-1, 1):
        kit.cylinder(0.011, sgn * 0.040 - 0.006, sgn * 0.040 + 0.006, 6, chamfer=0.002, bm=mech,
                     mx=mxb @ kit.R("Z", 30))
    _mark(mech, n0, 1)

    # bolt circle on the aft flange face + screw ring on the forward band
    n_bolts = 27
    hous_half = 0.075 / (1.04 * R)
    for k in range(n_bolts):
        th = phase + (k + 0.5) * TAU / n_bolts
        if any(abs(math.remainder(th - phis[i], TAU)) < hous_half + 0.02 for i in act_idx):
            continue
        n0 = len(mech.faces)
        _bolt(mech, kit.T(*_cp(th, 1.037 * R, 0.12)) @ kit.R("Z", math.degrees(th)), r=0.0085, h=0.0065)
        _mark(mech, n0, 1)
    for k in range(n_bolts * 2):
        th = phase + (k + 0.25) * TAU / (n_bolts * 2)
        if any(abs(math.remainder(th - phis[i], TAU)) < hous_half + 0.01 for i in act_idx):
            continue
        n0 = len(mech.faces)
        _screw(mech, _rframe(th, 1.055 * R, -0.10), r=0.0055, h=0.0022)
        _mark(mech, n0, 1)

    # ---------------- master + seal petals -----------------------------------------------------
    masters = []
    for i, phi in enumerate(phis):
        pl = _Plate(phi, 0.5 * 0.70 * pitch, 0.5 * 0.62 * pitch, zp0, L, r_m, th_m0, th_m1,
                    tip=lambda u: -chev * abs(u))
        pl.build(petal, rib=(0.014, 0.007, 0.008), chamfer=0.011, edge=0.35)
        masters.append(pl)
        # root doubler plate with bolts
        dbl = _Plate(phi, 0.5 * 0.70 * pitch * 0.74, 0.5 * 0.70 * pitch * 0.70, zp0 + 0.012, 0.32, r_m, 0.006, 0.006,
                     h0=th_m0 - 0.0015)
        dbl.build(petal, None, chamfer=0.004, edge=0.4, n_s=6)
        for u in (-0.5, 0.0, 0.5):
            for s in (0.25, 0.75):
                n0 = len(mech.faces)
                _bolt(mech, dbl.on_top(u, s, -0.0005), r=0.0065, h=0.005, washer=False)
                _mark(mech, n0, 1)
        # rivet rows along both edges
        for u in (-0.80, 0.80):
            for k in range(13):
                s = 0.22 + 0.70 * k / 12
                kit.lathe([(0.0, -0.0008), (0.0042, -0.0008), (0.0040, 0.0010), (0.0024, 0.0027),
                           (0.0, 0.0032)], 8, rivet, pl.on_top(u, s, -0.0004))
        # hinge knuckle + lugs at the root
        w0 = pl.width(0.0)
        kit.cylinder(0.016, -w0 * 0.55, w0 * 0.55, 16, chamfer=0.003, bm=cast,
                     mx=_rframe(phi, r_m(zp0) - 0.002, zp0 + 0.012) @ kit.R("Y", 90.0))
        n0 = len(mech.faces)
        kit.cylinder(0.0075, -w0 * 0.62, w0 * 0.62, 12, chamfer=0.0015, bm=mech,
                     mx=_rframe(phi, r_m(zp0) - 0.002, zp0 + 0.012) @ kit.R("Y", 90.0))
        _mark(mech, n0, 1)
        for sgn in (-1, 1):
            kit.box((0.014, 0.05, 0.05), (sgn * w0 * 0.60, 0.0, 0.0), bevel=0.003, segs=1, bm=cast,
                    mx=_rframe(phi, 0.945 * R + 0.02, zp0 + 0.0))

    for i, phi in enumerate(phis):
        ph = phi + 0.5 * pitch
        sl = _Plate(ph, 0.5 * 0.50 * pitch, 0.5 * 0.50 * pitch, zs0, L - chev - 0.012, r_s, th_s, th_s * 0.8,
                    tip=lambda u: -0.035 * max(0.0, abs(u) - 0.55) / 0.45)
        sl.build(petal, rib=(0.020, 0.013, 0.007), chamfer=0.004, edge=0.5, rib_fade=(0.0, 0.06, 0.90, 1.0))

    # ---------------- actuation: unison ring, links, root hydraulics, external actuators -----------
    _lathe_m(cast, [(0.78 * R, 0.12, 0), (0.80 * R, 0.12, 0), (0.80 * R, 0.43, 0), (0.78 * R, 0.43, 0)], segs)
    kit.ring(0.905 * R, 0.80 * R, 0.29, 0.34, segs, chamfer=0.006, bm=cast)
    for i, phi in enumerate(phis):
        # master link: unison ring -> petal underside
        a = _cp(phi, 0.895 * R, 0.315)
        zb = 0.62
        b = _cp(phi, r_m(zb) - 0.012, zb)
        n0 = len(mech.faces)
        kit.tube([a, b], 0.010, 10, bm=mech)
        _mark(mech, n0, 0)
        kit.box((0.03, 0.05, 0.02), (0, 0, 0), bevel=0.003, segs=1, bm=cast, mx=_rframe(phi, r_m(zb) - 0.010, zb))
        # root hydraulic cylinder in the window between two master roots
        ph = phi + 0.5 * pitch
        a = _cp(ph, 0.935 * R, 0.165)
        b = _cp(ph, 0.875 * R, 0.30)
        d = b - a
        mx = kit.frame(a, d, _tan(ph))
        ln = d.length
        n0 = len(mech.faces)
        kit.cylinder(0.019, 0.0, ln * 0.58, 16, chamfer=0.003, bm=mech, mx=mx)
        _mark(mech, n0, 0)
        n0 = len(mech.faces)
        kit.cylinder(0.021, ln * 0.52, ln * 0.58, 16, chamfer=0.002, bm=mech, mx=mx)
        _mark(mech, n0, 1)
        n0 = len(mech.faces)
        kit.cylinder(0.0085, ln * 0.56, ln, 12, chamfer=0.001, bm=mech, mx=mx)
        _mark(mech, n0, 2)
        # seal hanger links (pair) from the unison ring to the seal root
        for sgn in (-1, 1):
            a = _cp(ph, 0.90 * R, 0.33, sgn * 0.045)
            b = _cp(ph, r_s(0.42) - 0.006, 0.42, sgn * 0.045)
            n0 = len(mech.faces)
            kit.tube([a, b], 0.006, 8, bm=mech)
            _mark(mech, n0, 1)

    # external actuators with housings on the collar
    for i in act_idx:
        phi = phis[i]
        rb = 1.04 * R
        secs = [(-0.118, 0.040, 0.010), (-0.092, 0.056, 0.048), (-0.055, 0.062, 0.068), (0.165, 0.062, 0.072),
                (0.205, 0.056, 0.064), (0.218, 0.048, 0.050)]
        rings = []
        for z, hw, hh in secs:
            cc = min(0.022, hh * 0.4)
            loc2 = [(-hw, -0.01), (hw, -0.01), (hw, hh - cc), (hw - cc, hh), (-hw + cc, hh), (-hw, hh - cc)]
            rings.append([_cp(phi, rb + rr, z, t) for t, rr in loc2])
        kit.loft(rings, cast)
        # cover plate + screws on the housing
        kit.box((0.088, 0.17, 0.008), (0, 0, 0), bevel=0.002, segs=1, bm=cast, mx=_rframe(phi, rb + 0.072, 0.055))
        for t in (-0.034, 0.034):
            for z in (-0.02, 0.055, 0.13):
                n0 = len(mech.faces)
                _screw(mech, _rframe(phi, rb + 0.076, z, t), r=0.0045, h=0.002)
                _mark(mech, n0, 1)
        # actuator: from inside the housing to a clevis on the master petal
        pl = masters[i]
        s_att = (0.70 - zp0) / (L - zp0)
        top = pl.on_top(0.0, s_att)
        b = top @ V((0.0, 0.0, 0.026))
        a = _cp(phi, rb + 0.036, 0.10)
        d = b - a
        ln = d.length
        mx = kit.frame(a, d, _tan(phi))
        n0 = len(mech.faces)
        kit.cylinder(0.027, 0.0, ln * 0.50, 24, chamfer=0.004, bm=mech, mx=mx)
        kit.cylinder(0.024, ln * 0.50, ln * 0.56, 24, chamfer=0.003, bm=mech, mx=mx)
        _mark(mech, n0, 0)
        n0 = len(mech.faces)
        kit.cylinder(0.030, ln * 0.40, ln * 0.43, 24, chamfer=0.003, bm=mech, mx=mx)
        kit.cylinder(0.030, ln * 0.12, ln * 0.15, 24, chamfer=0.003, bm=mech, mx=mx)
        _mark(mech, n0, 1)
        n0 = len(mech.faces)
        kit.cylinder(0.0125, ln * 0.54, ln - 0.018, 16, chamfer=0.002, bm=mech, mx=mx)
        _mark(mech, n0, 2)
        # rod-end eye + clevis
        n0 = len(mech.faces)
        kit.cylinder(0.018, -0.008, 0.008, 16, chamfer=0.002, bm=mech, mx=kit.frame(b, _tan(phi), d))
        _mark(mech, n0, 0)
        n0 = len(mech.faces)
        kit.cylinder(0.0075, -0.030, 0.030, 12, chamfer=0.0015, bm=mech, mx=kit.frame(b, _tan(phi), d))
        _mark(mech, n0, 1)
        for sgn in (-1, 1):
            kit.box((0.010, 0.07, 0.046), (sgn * 0.017, 0.0, 0.021), bevel=0.002, segs=1, bm=cast, mx=top)
        kit.box((0.05, 0.10, 0.008), (0.0, 0.0, 0.002), bevel=0.002, segs=1, bm=cast, mx=top)

    # ---------------- inner flow path: chamber casing, throat ring, divergent liner ----------------
    rc = 0.60 * R
    zb = -0.92
    prof = [(0.0, zb, 3), (rc - 0.02, zb, 3), (rc, zb + 0.02, 3), (rc, -0.69, 3), (rc + 0.024, -0.69, 3),
            (rc + 0.024, -0.55, 3), (rc, -0.55, 3), (rc, -0.32, 3)]
    for k in range(1, 7):
        t = k / 6
        prof.append((_lerp(rc, 0.505 * R, 0.5 - 0.5 * math.cos(math.pi * t)), _lerp(-0.32, 0.02, t), 3 if k < 4 else 0))
    prof += [(0.505 * R, 0.03, 1), (0.68 * R, 0.03, 1), (0.68 * R, -0.98, 1), (0.0, -0.98, 1)]
    _lathe_m(liner, prof, 96)       # chamber casing (deep inside: fewer segments)
    # throat ring
    _lathe_m(liner, [(0.56 * R, 0.0, 2), (0.505 * R, 0.0, 2), (0.488 * R, 0.03, 2), (0.48 * R, 0.058, 2),
                     (0.492 * R, 0.062, 2), (0.492 * R, 0.082, 2), (0.48 * R, 0.086, 2), (0.48 * R, 0.10, 2),
                     (0.487 * R, 0.135, 2), (0.497 * R, 0.16, 2), (0.56 * R, 0.16, 2)], segs)
    # glowing magnetic throat coil in the groove of the throat ring (lights the divergent flaps)
    n0 = len(emit.faces)
    kit.ring(0.494 * R, 0.484 * R, 0.0625, 0.0815, segs, bm=emit)
    _mark(emit, n0, 3)
    # divergent liner (smooth base cone + rolled trailing-edge ring)
    zl0, zl1 = 0.14, L - 0.045

    def r_l(z):
        return R * (0.50 + 0.21 * (z - zl0) / (zl1 - zl0))

    wall = 0.022
    re = r_l(zl1)
    ro = r_s(zl1) - 0.003          # rolled trailing-edge ring fills the gap up to the seal petals
    _lathe_m(liner, [(r_l(zl0), zl0, 0), (re, zl1, 2), (re + 0.005, zl1 + 0.009, 2), (re + 0.015, zl1 + 0.014, 2),
                     (ro - 0.009, zl1 + 0.013, 2), (ro - 0.001, zl1 + 0.005, 2), (ro, zl1 - 0.004, 2),
                     (ro, zl1 - 0.035, 1), (re + wall, zl1 - 0.06, 1), (r_l(zl0) + wall, zl0, 1)], segs)
    # divergent flaps (inner layer, same rhythm as the master petals) over narrow divergent seals
    th_f, th_ds = 0.010, 0.006
    zf0, zf1 = zl0 + 0.025, zl1 - 0.004
    for i, phi in enumerate(phis):
        ds = _Plate(phi + 0.5 * pitch, 0.5 * 0.30 * pitch, 0.5 * 0.30 * pitch, zf0 + 0.01, zf1 - 0.006, r_l,
                    th_ds, th_ds, inward=True)
        ds.build(liner, rib=(0.007, 0.005, 0.004), chamfer=0.003, edge=0.5, n_s=14, rib_fade=(0.0, 0.04, 0.96, 1.0))
        fl = _Plate(phi, 0.5 * 0.82 * pitch, 0.5 * 0.82 * pitch, zf0, zf1, r_l, th_f, th_f, h0=th_ds + 0.0015,
                    inward=True)
        n0 = len(liner.faces)
        fl.build(liner, None, chamfer=0.006, edge=0.4, n_s=14)
        _mark(liner, n0, 4)
        # rows of film-cooling slots
        for s_ in (0.10, 0.36, 0.62, 0.86):
            for u in (-0.62, -0.21, 0.21, 0.62):
                n0 = len(liner.faces)
                kit.box((0.034 * fl.width(s_) / 0.12, 0.009, 0.003), (0.0, 0.0, -0.0012), bm=liner,
                        mx=fl.on_top(u, s_))
                _mark(liner, n0, 1)
    # closure ring between liner exit and petals (hides the cavity, sits deep in the gap)
    _lathe_m(liner, [(r_l(L - 0.17) + wall - 0.003, L - 0.17, 1), (r_s(L - 0.17) - 0.001, L - 0.17, 1),
                     (r_s(L - 0.15) - 0.001, L - 0.15, 1), (r_l(L - 0.17) + wall - 0.003, L - 0.15, 1)], segs)

    # ---------------- combustion / plasma chamber -------------------------------------------------
    # centre body
    n0 = len(mech.faces)
    kit.lathe([(0.0, -0.93), (0.13, -0.93), (0.13, -0.62), (0.125, -0.54), (0.104, -0.42), (0.07, -0.27),
               (0.036, -0.14), (0.014, -0.075), (0.0, -0.062)], 48, mech)
    _mark(mech, n0, 3)
    n0 = len(emit.faces)
    kit.ring(0.1305, 0.12, -0.60, -0.575, 48, bm=emit)        # emissive band on the centre body
    _mark(emit, n0, 0)
    # flame-holder vanes (V-gutters, open aft)
    n_vane = 6
    vpoly = [(0.0, -0.455), (0.022, -0.37), (0.015, -0.366), (0.0, -0.434), (-0.015, -0.366), (-0.022, -0.37)]
    for k in range(n_vane):
        th = phase + (k + 0.5) * TAU / n_vane
        n0 = len(mech.faces)
        kit.prism(vpoly, 0.09, rc + 0.012, bm=mech, mx=Matrix((_tan(th), V((0, 0, 1)), _rad(th))).transposed().to_4x4())
        _mark(mech, n0, 3)
    # injector ring + glowing injector tips
    n0 = len(mech.faces)
    kit.torus(0.29, 0.018, 64, 10, bm=mech, mx=kit.T(0, 0, -0.47))
    _mark(mech, n0, 1)
    for k in range(32):
        th = (k + 0.5) * TAU / 32
        p0 = _cp(th, 0.29, -0.47)
        n0 = len(mech.faces)
        kit.cylinder(0.0075, 0.0, 0.032, 10, chamfer=0.001, bm=mech, mx=kit.T(*p0))
        _mark(mech, n0, 1)
        n0 = len(emit.faces)
        kit.cylinder(0.0048, 0.030, 0.036, 8, bm=emit, mx=kit.T(*p0))
        _mark(emit, n0, 1)
    # plasma core: confinement torus deep inside (lights the walls) + dim back plate
    n0 = len(emit.faces)
    kit.torus(0.25, 0.045, 64, 12, bm=emit, mx=kit.T(0, 0, -0.84))
    _mark(emit, n0, 0)
    # injector back plate: radial ribs (lit by the torus) with dim glowing ports between them
    for k in range(12):
        th = phase + k * TAU / 12
        n0 = len(liner.faces)
        kit.box((0.016, 0.03, 0.27), (0.0, 0.0, 0.0), bevel=0.003, segs=1, bm=liner,
                mx=_rframe(th, 0.27, zb))
        _mark(liner, n0, 3)
        n0 = len(emit.faces)
        kit.cylinder(0.018, zb - 0.01, zb + 0.004, 12, bm=emit, mx=kit.T(*_cp(th + TAU / 24, 0.33, 0.0)))
        _mark(emit, n0, 2)
    # emissive ring segments in the chamber wall groove
    n_seg = 16
    for k in range(n_seg):
        a0 = phase + k * TAU / n_seg
        n0 = len(emit.faces)
        kit.lathe([(rc + 0.006, -0.684), (rc + 0.026, -0.684), (rc + 0.026, -0.556), (rc + 0.006, -0.556)], 6, emit,
                  close=True, arc=TAU / n_seg * 0.82, start=a0)
        _mark(emit, n0, 1)
        n0 = len(mech.faces)
        kit.box((0.022, 0.14, 0.03), (0, 0, 0), bm=mech, mx=_rframe(a0 - TAU / n_seg * 0.09, rc + 0.012, -0.62))
        _mark(mech, n0, 0)

    ob = G.build(name)
    print("NOZZLE", name, "tris", _tris(ob), G.stats)
    return ob


# ------------------------------------------------------------------------------------------
# VTOL lift nozzle
# ------------------------------------------------------------------------------------------
def build_vtol_nozzle(col=None, radius=0.22, depth=0.25, n_vanes=4, vane_angle=22.0, glow=1.0, name="VtolNozzle",
                      segs=48):
    """Flush ventral lift thruster. +Z out of the hull, z = 0 = hull surface; bezel outer radius = radius*1.26."""
    r = radius
    m_dark = mats.get("metal_dark")
    m_steel = mats.get("metal_steel")
    m_soot = mats.get("metal_soot")
    m_inner = mats.get("inner_dark")
    m_glow = mats.emissive("vtol_glow_%.2f" % glow, (0.22, 0.55, 1.0), 2.5 * glow)
    G = _Groups(col)
    cast = G.bm("cast", [m_dark, m_steel], bevel=0.0015, angle=30.0)
    bell = G.bm("bell", [m_soot, m_inner], bevel=0.0015, angle=40.0)
    small = G.bm("small", [m_steel, m_dark])
    emit = G.bm("emit", [m_glow], smooth=None)

    # bezel ring (top face 3 mm proud, chamfered into the surface)
    _lathe_m(cast, [(0.95 * r, -0.03, 0), (1.26 * r, -0.03, 0), (1.26 * r, -0.001, 0), (1.245 * r, 0.003, 0),
                    (0.985 * r, 0.003, 0), (0.965 * r, -0.002, 0), (0.95 * r, -0.012, 0)], segs)
    for k in range(12):
        th = (k + 0.5) * TAU / 12
        _screw(small, kit.T(*_cp(th, 1.12 * r, 0.0025)), r=0.0062, h=0.0022)
    # bell
    d = depth
    prof = [(0.955 * r, -0.010, 0), (0.935 * r, -0.05, 0), (0.88 * r, -0.11, 0), (0.79 * r, -0.17, 0),
            (0.70 * r, -0.215, 0), (0.655 * r, -d + 0.01, 0), (0.645 * r, -d, 1), (0.645 * r, -d - 0.02, 1),
            (1.02 * r, -d - 0.02, 1), (1.02 * r, -0.03, 1)]
    _lathe_m(bell, prof, segs)
    # centre plug with a domed nose
    _lathe_m(bell, [(0.0, -d - 0.02, 1), (0.355 * r, -d - 0.02, 1), (0.355 * r, -0.205, 0), (0.33 * r, -0.178, 0),
                    (0.26 * r, -0.158, 0), (0.14 * r, -0.148, 0), (0.0, -0.145, 0)], 32)
    # struts across the annular slot
    for k in range(4):
        th = math.pi / 4 + k * math.pi / 2
        n0 = len(bell.faces)
        kit.box((0.010, 0.06, 0.36 * r), (0, 0, 0), bevel=0.002, segs=1, bm=bell, mx=_rframe(th, 0.50 * r, -d + 0.005))
        _mark(bell, n0, 0)
    # glowing annulus at the bottom of the slot
    kit.ring(0.65 * r, 0.35 * r, -d - 0.018, -d - 0.008, segs, bm=emit)
    # louvre vanes (span along X, pivot about X)
    pitch = 1.72 * r / n_vanes
    chord, thick = pitch * 0.92, 0.011
    zv = -0.06
    rw = 0.925 * r
    sec = [(-chord / 2, 0.0), (-chord / 2 + 0.010, -thick / 2), (chord / 2 - 0.014, -thick * 0.32), (chord / 2, 0.0),
           (chord / 2 - 0.014, thick * 0.32), (-chord / 2 + 0.010, thick / 2)]
    for k in range(n_vanes):
        y = (k - (n_vanes - 1) / 2) * pitch
        half = math.sqrt(max(rw * rw - y * y, 0.0)) + 0.004
        mx = (kit.T(0.0, y, zv) @ Matrix(((0, 0, 1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
              @ kit.R("Z", vane_angle))
        n0 = len(cast.faces)
        kit.prism(sec, -half, half, bm=cast, mx=mx)
        _mark(cast, n0, 0)
        for sgn in (-1, 1):
            n0 = len(small.faces)
            kit.cylinder(0.0075, -0.012, 0.012, 12, chamfer=0.0015, bm=small,
                         mx=kit.T(sgn * (half - 0.004), y, zv) @ kit.R("Y", 90))
            _mark(small, n0, 0)
        # crank lug under each vane
        n0 = len(small.faces)
        kit.box((0.012, 0.012, 0.03), (0.30 * r, y + 0.006, zv - 0.022), bevel=0.002, segs=1, bm=small)
        _mark(small, n0, 1)
    # drive rod linking the cranks
    n0 = len(small.faces)
    kit.box((0.010, (n_vanes - 1) * pitch + 0.03, 0.010), (0.30 * r, 0.006, zv - 0.04), bevel=0.002, segs=1, bm=small)
    _mark(small, n0, 1)
    ob = G.build(name)
    print("VTOL", name, "tris", _tris(ob), G.stats)
    return ob


# ------------------------------------------------------------------------------------------
# demos
# ------------------------------------------------------------------------------------------
def _pod_stub(col, r=0.735, ln=1.2):
    """Context: open-ended engine-pod tail stub in nozzle space (z from -ln to 0)."""
    bm = kit.lathe([(0.0, -ln), (r - 0.02, -ln), (r, -ln + 0.02), (r, 0.0), (r - 0.03, 0.0), (r - 0.03, -ln + 0.03),
                    (0.0, -ln + 0.03)], 96)
    return kit.to_obj("PodStub", bm, col, [mats.get("paint_white")])


def _slab(col, half, hole, z0, z1, segs=48):
    """Square slab with a round hole (for the flush VTOL nozzle)."""
    bm = bmesh.new()
    rings = []
    for z in (z0, z1):
        inner, outer = [], []
        for j in range(segs):
            a = TAU * j / segs
            ca, sa = math.cos(a), math.sin(a)
            sc = half / max(abs(ca), abs(sa))
            inner.append(bm.verts.new((hole * ca, hole * sa, z)))
            outer.append(bm.verts.new((sc * ca, sc * sa, z)))
        rings.append((inner, outer))
    (i0, o0), (i1, o1) = rings
    for j in range(segs):
        k = (j + 1) % segs
        bm.faces.new((i1[j], o1[j], o1[k], i1[k]))
        bm.faces.new((i0[k], o0[k], o0[j], i0[j]))
        bm.faces.new((o0[j], o0[k], o1[k], o1[j]))
        bm.faces.new((i0[j], i1[j], i1[k], i0[k]))
    ob = kit.to_obj("Slab", bm, col, [mats.get("paint_dark")])
    kit.mod_bevel(ob, 0.004, 2, 40.0)
    kit.apply_mods(ob)
    return ob


def demo(glow=1.0):
    col = kit.collection("Nozzle")
    noz = build_nozzle(col, glow=glow)
    kit.place(noz, rot=(90, 0, 0))
    pod = _pod_stub(col)
    kit.place(pod, rot=(90, 0, 0))
    lo, hi = kit.bbox_world([noz, pod])
    vt = build_vtol_nozzle(col, glow=glow)
    th = 0.30
    x = hi.x + 0.75
    y = (lo.y + hi.y) / 2
    vt.location = (x, y, lo.z + th)
    slab = _slab(col, 0.42, 1.25 * 0.22, 0.0, th)
    slab.location = (x, y, lo.z)
    return [noz, pod, vt, slab]


def _focus(lo, hi):
    ob = kit.to_obj("focus", kit.box(tuple(h - l for l, h in zip(lo, hi)), tuple((l + h) / 2 for l, h in zip(lo, hi))))
    ob.hide_render = True
    return [ob]


def _nozzle_only():
    col = kit.collection("Nozzle")
    noz = build_nozzle(col)
    kit.place(noz, rot=(90, 0, 0))
    pod = _pod_stub(col)
    kit.place(pod, rot=(90, 0, 0))
    lo, _hi = kit.bbox_world([noz, pod])
    return lo.z


def demo_close():
    """Close-up of the trailing edge + lower starboard actuator (the studio floor sits at the box bottom,
    so close-up boxes always start at the lowest point of the part)."""
    z = _nozzle_only()
    return _focus((0.05, -1.45, z), (0.85, -0.35, 0.15))


def demo_root():
    """Close-up of the collar, petal roots, windows and the lower starboard actuator."""
    z = _nozzle_only()
    return _focus((0.3, -0.62, z), (0.86, -0.02, 0.0))


def demo_inside():
    """Looking into the nozzle exit (use --views=rear or rear34)."""
    z = _nozzle_only()
    return _focus((-0.6, -1.4, z), (0.6, -1.3, 0.6))


def demo_vtol():
    col = kit.collection("Nozzle")
    vt = build_vtol_nozzle(col)
    slab = _slab(col, 0.42, 1.25 * 0.22, -0.30, 0.0)
    return [vt, slab]
