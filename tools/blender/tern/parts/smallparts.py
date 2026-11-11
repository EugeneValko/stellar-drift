"""ST-7 Tern - kit of small hull fittings (RCS, vents, lights, antennas, fasteners, ...).

Every public part function takes `col=None` first and returns ONE mesh object at the origin with identity
transform. Local axes: +Z out of the hull, z = 0 is the hull surface, +Y forward (directional parts).
Raised parts let their base extend ~10 mm below z = 0. Recessed parts have the bezel at z = 0..+4 mm and the
cavity below z = 0; the hole to cut into the hull panel is stored on the object as custom properties
`cutout` (flat [x0, y0, x1, y1, ...] CCW outline in local XY, ~5-10 mm inside the bezel edge) and `cut_depth`.

Local materials (not in mats.py, created on first use):
  sp_lens_glass        clear transmissive lens (library 'lens_clear' is opaque and would hide the emitters)
  sp_rcs_heat          mats.heat_metal tinted along local -Z (RCS bells; object space, so keep parts instanced)
  sp_metal_steel_fine  metal_steel with a 0.8 mm Bevel-shader radius (4 mm rounds off sub-cm hardware)
  sp_paint_dark_thin   graphite paint with little edge wear (thin blades chip all over with the library paint)
Demo / previews: demo() lays out the whole kit; demo_a..f are subsets; demo_one frames SP_PART=<names>
(env vars SP_FRAME=part, SP_ROW=<row width>, SP_ZMAX=<frame height>).
"""
import math
import os

import bmesh
import bpy

import kit
import mats
from kit import R, T, V

LENS = "sp_lens_glass"
RCS_HEAT = "sp_rcs_heat"
THIN_PAINT = "sp_paint_dark_thin"
FINE_STEEL = "sp_metal_steel_fine"
EMIT = {"red": "emit_red", "green": "emit_green", "white": "emit_white", "amber": "emit_amber"}


# ------------------------------------------------------------------------------------------
# materials
# ------------------------------------------------------------------------------------------
def _lens_glass():
    m = bpy.data.materials.get(LENS)
    if m is not None:
        return m
    m = bpy.data.materials.new(LENS)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    p = nt.nodes.new("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = (0.94, 0.96, 1.0, 1.0)
    p.inputs["Roughness"].default_value = 0.015
    p.inputs["IOR"].default_value = 1.49
    p.inputs["Transmission Weight"].default_value = 1.0
    nt.links.new(p.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (0.85, 0.9, 0.95, 0.35)
    return m


def _mat(name):
    if name == LENS:
        return _lens_glass()
    if name == FINE_STEEL:
        # metal_steel with a 0.8 mm (instead of 4 mm) Bevel-shader radius, for sub-centimetre hardware
        return mats.surface(FINE_STEEL, (0.420, 0.415, 0.405), 0.30, 1.0, 0.0, 0.10, 0.6, bevel=0.0008)
    if name == THIN_PAINT:
        # graphite paint for thin blades: the library paints chip everywhere on parts thinner than the
        # 13 mm edge-detection radius, so this variant has almost no edge wear
        return mats.surface(THIN_PAINT, mats.PAINTS[1][1], 0.40, 0.0, 0.2, wear=0.06, grime=0.35)
    if name == RCS_HEAT:
        # cold (straw) at the nozzle exits near z = -0.015, fully tinted towards the throats at z ~ -0.085
        return mats.heat_metal(RCS_HEAT, axis=2, start=-0.012, length=-0.075)
    return mats.get(name)


# ------------------------------------------------------------------------------------------
# part builder: one bmesh, material slot per primitive, custom sharp-edge thresholds
# ------------------------------------------------------------------------------------------
class _Part:
    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.mats = []
        self.props = {}
        self.ang = self.bm.faces.layers.float.new("sp_smooth")
        # "old face" marker; a layer, not BMFace.tag, because bmesh operators (bevel) clear the tags
        self.old = self.bm.faces.layers.int.new("sp_old")

    def mi(self, m):
        if m not in self.mats:
            self.mats.append(m)
        return self.mats.index(m)

    def add(self, mat, fn, *a, recalc=True, pick=None, smooth=35.0, **kw):
        """Run a kit-style primitive (`fn(..., bm=)`) into the part; returns its new faces.
        `pick(face) -> material name or None` overrides the material per face."""
        bm = self.bm
        for f in bm.faces:
            f[self.old] = 1
        fn(*a, bm=bm, **kw)
        new = [f for f in bm.faces if f[self.old] == 0]
        if recalc:
            bmesh.ops.recalc_face_normals(bm, faces=new)
        idx = self.mi(mat)
        for f in new:
            f.normal_update()
            f.material_index = idx
            f[self.ang] = smooth
            if pick is not None:
                m2 = pick(f)
                if m2:
                    f.material_index = self.mi(m2)
        return new

    def done(self, col=None):
        bm = self.bm
        bm.normal_update()
        for f in bm.faces:
            f.smooth = True
            f.tag = False
        for e in bm.edges:
            if len(e.link_faces) != 2:
                continue
            f0, f1 = e.link_faces
            lim = math.radians(min(f0[self.ang], f1[self.ang]))
            e.smooth = e.calc_face_angle(0.0) <= lim and f0.material_index == f1.material_index
        bm.faces.layers.float.remove(self.ang)
        bm.faces.layers.int.remove(self.old)
        ob = kit.to_obj(self.name, bm, col, [_mat(m) for m in self.mats], smooth=None, recalc=False)
        for k, v in self.props.items():
            ob[k] = v
        return ob


def tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


# ------------------------------------------------------------------------------------------
# outlines (functions d -> CCW 2D polygon offset by d; d < 0 = inwards) and lofts
# ------------------------------------------------------------------------------------------
def _ol_rr(w, h, r, n=4, cx=0.0, cy=0.0):
    """Rounded rectangle (n = 1 gives a 45-degree chamfered rectangle)."""
    return lambda d: kit.rrect2(w + 2 * d, h + 2 * d, max(r + d, 0.0006), n, cx, cy)


def _ol_circle(r, segs, rot=0.0):
    return lambda d: kit.ngon2(segs, r + d, rot)


def _ol_cap(r1, r2, y1, y2, n1=10, n2=6, cx=0.0):
    """Convex hull of two circles on the Y axis (front circle r1 at y1, rear r2 at y2): teardrop / capsule."""
    def f(d):
        a, b = r1 + d, max(r2 + d, 0.0006)
        g = math.asin(max(-0.99, min(0.99, (a - b) / (y1 - y2))))
        pts = [(cx + a * math.cos(t), y1 + a * math.sin(t))
               for t in (-g + (math.pi + 2 * g) * i / n1 for i in range(n1 + 1))]
        pts += [(cx + b * math.cos(t), y2 + b * math.sin(t))
                for t in (math.pi + g + (math.pi - 2 * g) * i / n2 for i in range(n2 + 1))]
        return pts
    return f


def _oloft(outline, prof, mx=None, bm=None, cap0=True, cap1=True):
    """Loft an outline through a profile [(offset d, z), ...] (like a lathe for arbitrary outlines)."""
    rings = [[(x, y, z) for x, y in outline(d)] for d, z in prof]
    kit.loft(rings, bm, cap_start=cap0, cap_end=cap1, mx=mx)
    return bm


def _airfoil(chord, thick, le_y, n=7, te=0.0006):
    """Symmetric NACA-style section in the XY plane, chord along -Y from the leading edge at y = le_y."""
    up = []
    for i in range(n + 1):
        s = (1 - math.cos(math.pi * i / n)) / 2
        yt = 5 * thick * (0.2969 * math.sqrt(s) - 0.1260 * s - 0.3516 * s ** 2 + 0.2843 * s ** 3 - 0.1015 * s ** 4)
        up.append((max(yt, te * s), le_y - s * chord))
    return [(x, y) for x, y in reversed(up)] + [(-x, y) for x, y in up[1:]]


def _ring_pts(pts, z, s=1.0, cy=0.0):
    return [(x * s, cy + (y - cy) * s, z) for x, y in pts]


# ------------------------------------------------------------------------------------------
# shared sub-parts
# ------------------------------------------------------------------------------------------
def _hex_screw(r, mx=None, bm=None):
    """Flush button-head cap screw with a hex socket, open underneath: 58 tris. z = 0 is the seat."""
    bm = bm or bmesh.new()
    k = r / 0.011
    A = [bm.verts.new((r * math.cos(math.pi * j / 6), r * math.sin(math.pi * j / 6), -0.0015 * k)) for j in range(12)]
    B = [bm.verts.new((0.80 * r * math.cos(math.pi * j / 6), 0.80 * r * math.sin(math.pi * j / 6), 0.0011 * k))
         for j in range(12)]
    rh = 0.32 * r
    H = [bm.verts.new((rh * math.cos(math.pi * i / 3), rh * math.sin(math.pi * i / 3), 0.0015 * k)) for i in range(6)]
    D = [bm.verts.new((rh * math.cos(math.pi * i / 3), rh * math.sin(math.pi * i / 3), -0.0006 * k)) for i in range(6)]
    for j in range(12):
        j2 = (j + 1) % 12
        bm.faces.new((A[j], A[j2], B[j2], B[j]))
    for i in range(6):
        i2 = (i + 1) % 6
        b0, b1, b2 = B[2 * i], B[2 * i + 1], B[(2 * i + 2) % 12]
        bm.faces.new((b0, b1, H[i]))
        bm.faces.new((b1, H[i2], H[i]))
        bm.faces.new((b1, b2, H[i2]))
        bm.faces.new((H[i], H[i2], D[i2], D[i]))
    bm.faces.new(D)
    kit._xf(bm, A + B + H + D, mx)
    return bm


def _dome_screw(r, mx=None, bm=None, segs=12):
    """Tiny low domed screw head (open underneath), 3*segs tris."""
    k = r / 0.005
    return kit.lathe([(r, -0.0012), (0.72 * r, 0.0008 * k), (0.0, 0.0011 * k)], segs, bm, mx)


def _bolt_geom(R_, h, mx=None, bm=None):
    """Hex bolt head on a washer (both open underneath): 102 tris."""
    bm = bm or bmesh.new()
    k = h / 0.010
    rc = 0.62 * R_
    kit.lathe([(R_, -0.003), (R_, 0.0011 * k), (R_ - 0.0008, 0.0018 * k), (0.45 * R_, 0.0018 * k)], 12, bm, mx)
    kit.lathe([(rc, 0.0015 * k), (rc, h - 0.0012 * k), (rc * 0.84, h), (0.0, h)], 6, bm, mx)
    return bm


def _screws(p, pts, z, r, kind="hex", mat=FINE_STEEL):
    for x, y in pts:
        if kind == "hex":
            p.add(mat, _hex_screw, r, T(x, y, z), recalc=False)
        else:
            p.add(mat, _dome_screw, r, T(x, y, z), recalc=False, smooth=50.0)


def _housing(p, outline, bez, depth, mat="metal_dark", inner="inner_dark", lip=0.004, cut=None, band=0.006,
             floor_ch=0.002, wall=None):
    """Recessed housing: bezel flange (top at z = lip), cavity walls down to z = -depth, closed floor.
    Cavity faces below z = -band get `wall` (walls, default = mat) / `inner` (floor). Stores the hull cutout."""
    wall = wall or mat
    cut = min(0.010, 0.4 * bez) if cut is None else cut
    do = -(cut + 0.003)                      # outer wall below the hull: inside the cutout
    di = -bez                                # inner cavity wall
    c = min(0.0015, bez * 0.15)
    band = min(band, depth * 0.45)
    prof = [(do, -depth - 0.006), (do, -0.012), (0.0, -0.012), (0.0, lip - c), (-c, lip), (di + c, lip),
            (di, lip - c), (di, -band), (di, -depth + floor_ch), (di - floor_ch, -depth)]
    def pick(f):
        if f.calc_center_median().z >= -band * 0.7:
            return None
        return inner if f.normal.z > 0.3 else wall
    faces = p.add(mat, _oloft, outline, prof, pick=pick)
    cpoly = outline(-cut)
    p.props["cutout"] = [round(v, 5) for xy in cpoly for v in xy]
    p.props["cut_depth"] = round(depth + 0.006, 4)
    return faces


def _bell(L, re, rt, tw=0.0018, n=4, body=(0.016, 0.03), segs=28, mx=None, bm=None):
    """Closed bell nozzle along +Z: throat at z = 0, exit plane at z = L, valve body (radius, length) behind."""
    f = lambda t: 1 - (1 - t) ** 1.7
    br, bl = body
    prof = [(0.0, -bl), (br, -bl), (br, -0.002), (rt + tw + 0.002, 0.001)]
    prof += [(rt + tw + (re - rt) * f(i / n), L * i / n - (0.0012 if i == n else 0.0)) for i in range(1, n + 1)]
    prof += [(re + tw - 0.0006, L), (re + 0.0003, L)]
    prof += [(rt + (re - rt) * f(i / n), L * i / n - (0.0008 if i == n else 0.0)) for i in range(n, -1, -1)]
    prof += [(rt * 0.7, -0.003), (0.0, -0.003)]
    return kit.lathe(prof, segs, bm, mx)


def _bell_pick(mx, L, hot=RCS_HEAT, body="metal_dark", soot=0.55):
    """Bell materials: sooty throat (inner surface below soot*L), heat-tinted metal elsewhere, dark valve body."""
    inv = mx.inverted()
    r3 = inv.to_3x3()

    def pick(f):
        c = inv @ f.calc_center_median()
        n = r3 @ f.normal
        if c.x * n.x + c.y * n.y < -1e-7:
            return "metal_soot" if c.z < soot * L else hot
        if c.z < -0.0015:
            return body
        return hot
    return pick


# ------------------------------------------------------------------------------------------
# RCS
# ------------------------------------------------------------------------------------------
def rcs_quad(col=None, size=0.42, tilt=16.0):
    """Reaction-control quad: chamfered-square recessed housing, bolted bezel, 4 bells canted outwards."""
    p = _Part("rcs_quad")
    s = size / 0.42
    bez, depth = 0.030 * s, 0.088 * s
    ol = _ol_rr(size, size, size * 0.16, n=1)
    _housing(p, ol, bez, depth, wall="metal_dark")
    _screws(p, kit.outline_points(ol(0), 0.11 * s, inset=bez * 0.5), 0.004, 0.0055 * s)
    L, re, rt = 0.060 * s, 0.063 * s, 0.014 * s
    st, ct = math.sin(math.radians(tilt)), math.cos(math.radians(tilt))
    zt = -0.0022 - (re + 0.0018) * st - L * ct     # inner edge of each exit lip ends just below z = 0
    rho = 0.097 * s                                # exit centre distance from the axis
    # manifold block on the cavity floor (the throats sit on it)
    blk = _ol_rr(0.19 * s, 0.19 * s, 0.05 * s, n=1)
    p.add("metal_dark", _oloft, blk, [(0.0, -depth - 0.001), (0.0, zt - 0.004 * s), (-0.004 * s, zt)])
    for k in range(4):
        a = math.pi / 2 * k
        d = V((math.cos(a), math.sin(a), 0.0))
        mx = kit.frame(d * (rho - L * st) + V((0, 0, zt)), (d.x * st, d.y * st, ct), (0, 0, 1))
        p.add(RCS_HEAT, _bell, L, re, rt, body=(0.024 * s, 0.010 * s), mx=mx, pick=_bell_pick(mx, L))
    p.add(FINE_STEEL, _bolt_geom, 0.016 * s, 0.012 * s, T(0, 0, zt), recalc=False)
    # propellant valves in the cavity corners with feed lines into the manifold
    for k in range(4):
        a = math.pi / 4 + math.pi / 2 * k
        cx, cy = math.cos(a) * 0.185 * s, math.sin(a) * 0.185 * s
        p.add("metal_dark", kit.cylinder, 0.014 * s, -depth - 0.001, -depth + 0.020 * s, 14, chamfer=0.002,
              mx=T(cx, cy, 0))
        p.add(FINE_STEEL, kit.cylinder, 0.006 * s, -depth + 0.019 * s, -depth + 0.026 * s, 12, chamfer=0.001,
              mx=T(cx, cy, 0), smooth=50.0)
        e = V((math.cos(a), math.sin(a), 0))
        pts = [e * 0.170 * s + V((0, 0, -depth + 0.012 * s)), e * 0.120 * s + V((0, 0, -depth + 0.012 * s)),
               e * 0.090 * s + V((0, 0, -depth + 0.009 * s)), e * 0.050 * s + V((0, 0, -depth + 0.009 * s))]
        p.add(FINE_STEEL, kit.tube, kit.fillet_path(pts, 0.012 * s, n=2), 0.0042 * s, 8, smooth=50.0)
    return p.done(col)


def rcs_single(col=None, radius=0.07):
    """Single flush RCS port: bolted bezel ring and a short bell recessed below the hull surface."""
    p = _Part("rcs_single")
    k = radius / 0.07
    segs = 24
    bez, depth = 0.0145 * k, 0.060 * k
    ol = _ol_circle(radius, segs)
    _housing(p, ol, bez, depth)
    _screws(p, kit.ngon2(6, radius - bez * 0.5, 30.0), 0.004, 0.0034 * k, kind="dome")
    ri = radius - bez
    re = ri - 0.0045 * k
    L = depth - 0.012 * k
    mx = T(0, 0, -0.004 - L)
    p.add(RCS_HEAT, _bell, L, re, 0.011 * k, n=4, body=(0.020 * k, 0.0075 * k), segs=segs, mx=mx,
          pick=_bell_pick(mx, L))
    return p.done(col)


# ------------------------------------------------------------------------------------------
# vents / grilles
# ------------------------------------------------------------------------------------------
def vent(col=None, width=0.60, height=0.20, slats=6, depth=0.06, tilt=-38.0):
    """Louvered heat-exchanger vent: chamfered bezel frame, angled slats (exhausting aft, -Y), mullions,
    fin pack on a dark back plate."""
    p = _Part("vent")
    bez = 0.022
    ol = _ol_rr(width, height, 0.024, n=1)
    _housing(p, ol, bez, depth)
    wi, hi = width - 2 * bez, height - 2 * bez
    _screws(p, kit.outline_points(ol(0), 0.14, inset=bez * 0.5), 0.004, 0.0048)
    pitch = hi / slats
    chord = pitch * 1.3
    for i in range(slats):
        y = -hi / 2 + pitch * (i + 0.5)
        p.add("metal_dark", kit.box, (wi + 0.004, chord, 0.003), bevel=0.001, segs=1,
              mx=T(0, y, -0.017) @ R("X", tilt))
    nm = 2 if wi > 0.4 else (1 if wi > 0.25 else 0)
    for i in range(nm):
        x = -wi / 2 + wi * (i + 1) / (nm + 1)
        p.add("metal_dark", kit.box, (0.006, hi + 0.004, depth - 0.006), center=(x, 0, -(depth + 0.006) / 2),
              bevel=0.0012, segs=1)
    nf = int(wi / 0.012)
    for i in range(nf):
        x = -wi / 2 + wi * (i + 0.5) / nf
        p.add("metal_steel", kit.box, (0.0012, hi + 0.002, 0.022), center=(x, 0, -depth + 0.010))
    return p.done(col)


def grille(col=None, width=0.5, height=0.3, pitch=0.018, depth=0.07):
    """Intake grille: rounded bezel frame, deep vertical bars over a horizontal back grid, dark duct."""
    p = _Part("grille")
    bez = 0.024
    ol = _ol_rr(width, height, 0.036, n=3)
    _housing(p, ol, bez, depth)
    wi, hi = width - 2 * bez, height - 2 * bez
    _screws(p, kit.outline_points(ol(0), 0.12, inset=bez * 0.5), 0.004, 0.0048)
    nb = max(2, int(round(wi / pitch)))
    for i in range(1, nb):
        x = -wi / 2 + wi * i / nb
        p.add("metal_dark", kit.box, (0.0032, hi + 0.004, 0.013), center=(x, 0, -0.0095), bevel=0.0008, segs=1)
    nh = max(2, int(round(hi / 0.045)))
    for i in range(1, nh):
        y = -hi / 2 + hi * i / nh
        p.add("metal_dark", kit.box, (wi + 0.004, 0.004, 0.010), center=(0, y, -0.021), bevel=0.0008, segs=1)
    # mid-span stiffener across the front bars
    p.add("metal_dark", kit.box, (wi + 0.004, 0.010, 0.016), center=(0, 0, -0.011), bevel=0.0015, segs=1)
    return p.done(col)


# ------------------------------------------------------------------------------------------
# lights
# ------------------------------------------------------------------------------------------
def _glass_dome(outer, inner, cy, z0, H, th, n=6, top=82.0, bm=None):
    """Closed glass shell: outline scaled towards (0, cy) with height (quarter-ellipse profile)."""
    ths = [math.radians(top) * i / (n - 1) for i in range(n)]
    O = [_ring_pts(outer, z0 + H * math.sin(t), math.cos(t), cy) for t in ths]
    I = [_ring_pts(inner, z0 + (H - th) * math.sin(t), math.cos(t), cy) for t in ths]
    kit.loft(I[::-1] + O, bm)
    return bm


def nav_light(col=None, color="red", length=0.16):
    """Teardrop position light (round end forward, +Y): metal plinth, clear lens dome, emitter + reflector."""
    p = _Part("nav_light_" + color)
    k = length / 0.16
    r1, r2 = 0.032 * k, 0.010 * k
    y1, y2 = length / 2 - r1, -length / 2 + r2
    zt = 0.007 * k
    base = _ol_cap(r1, r2, y1, y2, 12, 6)
    p.add("metal_dark", _oloft, base, [(0.0, -0.010), (0.0, zt - 0.0018), (-0.0018, zt)])
    lo, li = _ol_cap(r1 - 0.0045, r2 - 0.003, y1, y2, 12, 6), _ol_cap(r1 - 0.0062, r2 - 0.0045, y1, y2, 12, 6)
    p.add(LENS, _glass_dome, lo(0), li(0), y1, zt - 0.0006, 0.024 * k, 0.0017, 6)
    # chrome reflector cup, LED carrier and emitter dome at the front circle centre
    p.add("metal_chrome", kit.lathe, [(0.0, zt - 0.001), (0.0215 * k, zt - 0.001), (0.0215 * k, zt + 0.0008),
                                      (0.0200 * k, zt + 0.0016), (0.0105 * k, zt + 0.0004), (0.0, zt + 0.0004)],
          24, mx=T(0, y1, 0))
    p.add("metal_dark", kit.cylinder, 0.0095 * k, zt, zt + 0.0045 * k, 16, chamfer=0.0012, mx=T(0, y1, 0))
    p.add(EMIT.get(color, "emit_white"), kit.lathe,
          [(0.0, zt + 0.003 * k), (0.0072 * k, zt + 0.003 * k), (0.0072 * k, zt + 0.0065 * k),
           (0.0050 * k, zt + 0.0105 * k), (0.0, zt + 0.0118 * k)], 16, mx=T(0, y1, 0), smooth=50.0)
    return p.done(col)


def strobe(col=None, color="white"):
    """Small anti-collision beacon: ring base, clear dome, emissive flash tube core."""
    p = _Part("strobe_" + color)
    p.add("metal_dark", kit.lathe, [(0.0, -0.010), (0.030, -0.010), (0.030, 0.0030), (0.028, 0.0050),
                                    (0.0235, 0.0050), (0.0225, 0.0040), (0.0, 0.0040)], 24)
    ro, ri, z0, hgt = 0.0215, 0.0198, 0.0035, 0.024
    prof = [(0.0, z0 + hgt - 0.0017)]
    prof += [(ri * math.sin(t), z0 + (hgt - 0.0017) * math.cos(t)) for t in (math.radians(a) for a in (30, 55, 75, 90))]
    prof += [(ro * math.sin(t), z0 + hgt * math.cos(t)) for t in (math.radians(a) for a in (90, 75, 55, 30))]
    prof += [(0.0, z0 + hgt)]
    p.add(LENS, kit.lathe, prof, 24)
    p.add("metal_chrome", kit.cylinder, 0.0105, 0.0035, 0.0065, 16, chamfer=0.001)
    p.add(EMIT.get(color, "emit_white"), kit.cylinder, 0.0042, 0.0060, 0.0200, 12, chamfer=0.0015, smooth=50.0)
    return p.done(col)


def landing_light(col=None, radius=0.07):
    """Recessed landing lamp: bezel, chrome parabolic reflector, emitter, flat front glass."""
    p = _Part("landing_light")
    k = radius / 0.07
    segs = 28
    bez, depth = 0.012 * k, 0.052 * k
    _housing(p, _ol_circle(radius, segs), bez, depth)
    _screws(p, kit.ngon2(6, radius - bez * 0.5, 0.0), 0.004, 0.003 * k, kind="dome")
    ri = radius - bez
    z_rim, z_bot, r_bot = -0.0055 * k, -depth + 0.008 * k, 0.010 * k
    b = (z_rim - z_bot) / (ri ** 2 - r_bot ** 2)
    rs = [ri - 0.0003, ri * 0.8, ri * 0.6, ri * 0.4, r_bot]
    inner = [(r, z_bot + b * (r * r - r_bot * r_bot)) for r in rs]
    outer = [(r + 0.0018, z - 0.0012) for r, z in reversed(inner)]
    p.add("metal_chrome", kit.lathe, inner + outer, segs, close=True)
    # LED module: finned dark carrier, emitter dome, small front shield ring
    p.add("metal_dark", kit.cylinder, 0.0135 * k, -depth - 0.001, z_bot + 0.006 * k, 20, chamfer=0.0015)
    p.add("emit_white", kit.lathe, [(0.0, z_bot + 0.005 * k), (0.0095 * k, z_bot + 0.005 * k),
                                    (0.0095 * k, z_bot + 0.0075 * k), (0.0065 * k, z_bot + 0.0115 * k),
                                    (0.0, z_bot + 0.0128 * k)], 16, smooth=50.0)
    p.add(LENS, kit.cylinder, ri + 0.001, -0.0050 * k, -0.0028 * k, segs, chamfer=0.0006)
    return p.done(col)


def light_strip(col=None, length=0.5, width=0.03, color="white"):
    """Recessed LED formation strip in a slim capsule bezel."""
    p = _Part("light_strip_" + color)
    bez = 0.0075
    ol = _ol_rr(length, width, width * 0.48, n=3)
    _housing(p, ol, bez, 0.009, lip=0.003, band=0.003)
    em = _ol_rr(length - 2 * bez - 0.002, width - 2 * bez - 0.002, (width - 2 * bez) * 0.45, n=3)
    p.add(EMIT.get(color, "emit_white"), _oloft, em, [(0.0, -0.009), (0.0, -0.0024)])
    return p.done(col)


# ------------------------------------------------------------------------------------------
# antennas, probes, sensors
# ------------------------------------------------------------------------------------------
def antenna_blade(col=None, height=0.32, chord=0.22, sweep=40.0):
    """Swept blade antenna (leading edge +Y) with a sealant fillet on a bolted base plate."""
    p = _Part("antenna_blade")
    pw, pl = 0.07, chord + 0.06
    plate = _ol_rr(pw, pl, 0.022, n=3)
    p.add("metal_dark", _oloft, plate, [(0.0, -0.010), (0.0, 0.0045), (-0.0015, 0.006)])
    pts = [(sx * (pw / 2 - 0.011), y) for sx in (-1, 1) for y in (-pl / 2 + 0.018, 0.0, pl / 2 - 0.018)]
    _screws(p, pts, 0.006, 0.0042)
    tn = math.tan(math.radians(sweep))
    rings = []
    secs = [(0.002, 1.10, 1.9), (0.0068, 1.06, 1.45), (0.013, 1.0, 1.0), (0.08, 1, 1), (0.16, 1, 1), (0.24, 1, 1),
            (height - 0.006, 1, 1), (height, 0.93, 0.55)]
    for z, cs, ts in secs:
        u = max(z, 0.0) / height
        c = chord * (1 - 0.6 * u) * cs
        th = (0.018 - 0.010 * u) * ts
        le = chord / 2 - z * tn + (cs - 1) * chord * 0.5
        rings.append([(x, y, z) for x, y in _airfoil(c, th, le, 7)])
    p.add(THIN_PAINT, kit.loft, rings,
          pick=lambda f: "rubber" if f.calc_center_median().z < 0.0105 else None)
    return p.done(col)


def antenna_whip(col=None, height=0.70):
    """Thin whip antenna on a coil-spring base."""
    p = _Part("antenna_whip")
    p.add("metal_dark", kit.lathe, [(0.0, -0.010), (0.022, -0.010), (0.022, 0.0035), (0.0195, 0.0055), (0.0110, 0.0060),
                                    (0.0105, 0.0150), (0.0, 0.0150)], 12, smooth=50.0)
    # close-wound coil spring (square-section sweep, smooth shaded)
    z0, z1, turns, ppt, rc, rw = 0.0150, 0.0600, 6.5, 7, 0.0076, 0.0019
    N = int(turns * ppt)
    helix = [(rc * math.cos(math.tau * turns * i / N), rc * math.sin(math.tau * turns * i / N),
              z0 + rw + (z1 - z0 - 2 * rw) * i / N) for i in range(N + 1)]
    p.add(FINE_STEEL, kit.tube, helix, rw, 4, smooth=80.0)
    p.add("metal_dark", kit.lathe, [(0.0, 0.0595), (0.0098, 0.0595), (0.0098, 0.070), (0.0055, 0.076), (0.0, 0.076)], 8,
          smooth=50.0)
    p.add("plastic_black", kit.lathe, [(0.0, 0.012), (0.0030, 0.012), (0.0027, 0.08), (0.0013, height - 0.004),
                                       (0.0, height - 0.004)], 6, smooth=70.0)
    p.add("plastic_black", kit.lathe, [(0.0, height - 0.0065), (0.0028, height - 0.0045), (0.0028, height - 0.0015),
                                       (0.0, height)], 6, smooth=70.0)
    return p.done(col)


def pitot(col=None, length=0.35):
    """L-shaped pitot-static probe on a streamlined pylon, pointing +Y."""
    p = _Part("pitot")
    k = length / 0.35
    zt = 0.085
    plate = _ol_rr(0.05, 0.115, 0.02, n=3)
    p.add("metal_dark", _oloft, plate, [(0.0, -0.010), (0.0, 0.0035), (-0.0015, 0.005)])
    _screws(p, [(0, 0.044), (0, -0.044), (0.016, 0.0), (-0.016, 0.0)], 0.005, 0.0036, kind="dome")
    rings = []
    for z, c, th, le in [(-0.002, 0.090, 0.019, 0.047), (0.0052, 0.084, 0.016, 0.046), (0.011, 0.078, 0.0135, 0.045),
                         (0.045, 0.066, 0.0118, 0.050), (zt + 0.004, 0.050, 0.0100, 0.056)]:
        rings.append([(x, y, z) for x, y in _airfoil(c, th, le, 6)])
    p.add(THIN_PAINT, kit.loft, rings,
          pick=lambda f: "rubber" if f.calc_center_median().z < 0.0085 else None)
    prof = [(0.0, -0.035), (0.0050, -0.033), (0.0085, -0.024), (0.0085, 0.175), (0.0095, 0.178), (0.0095, 0.196),
            (0.0080, 0.202), (0.0062, 0.306), (0.0055, 0.315), (0.0028, 0.315), (0.0022, 0.311), (0.0, 0.301)]
    prof = [(r * min(1.0, k) if r else 0.0, a * k) for r, a in prof]
    p.add(FINE_STEEL, kit.lathe, prof, 12, mx=T(0, 0, zt) @ R("X", -90), smooth=50.0,
          pick=lambda f: "inner_dark" if f.calc_center_median().y > 0.312 * k and
          math.hypot(f.calc_center_median().x, f.calc_center_median().z - zt) < 0.0027 else None)
    return p.done(col)


def sensor_dome(col=None, radius=0.12):
    """Low ceramic radome on a bolted ring base."""
    p = _Part("sensor_dome")
    k = radius / 0.12
    segs = 32
    r_in = radius - 0.0215 * k
    p.add("metal_dark", kit.lathe, [(r_in - 0.004, -0.010), (radius, -0.010), (radius, 0.0045), (radius - 0.0025, 0.007),
                                    (r_in + 0.0015, 0.007), (r_in, 0.0055), (r_in, 0.003), (r_in - 0.004, 0.003)],
          segs, close=True)
    rd, hd = r_in - 0.0012, 0.046 * k
    prof = [(0.0, 0.0020), (rd, 0.0020), (rd, 0.0062)]
    prof += [(rd * math.cos(t), 0.0062 + (hd - 0.0062) * math.sin(t)) for t in
             (math.radians(a) for a in (18, 36, 54, 70, 84))]
    prof += [(0.0, hd)]
    p.add("ceramic", kit.lathe, prof, segs)
    _screws(p, kit.ngon2(8, (radius + r_in) / 2, 22.5), 0.007, 0.0040 * k, kind="dome")
    return p.done(col)


def sensor_window(col=None, width=0.22, height=0.12):
    """Flat faceted sensor aperture: stepped faceted bezel around a dark glass panel."""
    p = _Part("sensor_window")
    ol = _ol_rr(width, height, 0.018, n=1)
    cut = 0.006
    do = -(cut + 0.003)
    prof = [(do, -0.030), (do, -0.012), (0.0, -0.012), (0.0, 0.0025), (-0.002, 0.0045), (-0.010, 0.0045),
            (-0.0165, -0.0015), (-0.0185, -0.0035), (-0.0185, -0.020), (-0.0205, -0.022)]
    p.add("metal_dark", _oloft, ol, prof, pick=lambda f: "inner_dark" if f.calc_center_median().z < -0.009 else None)
    p.props["cutout"] = [round(v, 5) for xy in ol(-cut) for v in xy]
    p.props["cut_depth"] = 0.03
    p.add("glass_dark", _oloft, ol, [(-0.0180, -0.016), (-0.0180, -0.0075), (-0.0235, -0.0046)])
    pts = [(sx * (width / 2 - 0.0085), sy * (height / 2 - 0.0085)) for sx in (-1, 1) for sy in (-1, 1)]
    _screws(p, pts, 0.0045, 0.0032)
    return p.done(col)


# ------------------------------------------------------------------------------------------
# handles, steps, small hardware
# ------------------------------------------------------------------------------------------
def handle(col=None, length=0.22, width=0.075, depth=0.04):
    """Recessed grab handle: rounded pocket with a steel bar across on end bosses."""
    p = _Part("handle")
    bez = 0.012
    _housing(p, _ol_rr(length, width, 0.03, n=4), bez, depth, wall="paint_grey", inner="paint_grey")
    xi = length / 2 - bez
    zb = -0.0145
    p.add(FINE_STEEL, kit.tube, [(-xi - 0.002, 0, zb), (xi + 0.002, 0, zb)], 0.0068, 12)
    for sx in (-1, 1):
        p.add("metal_dark", kit.cylinder, 0.0098, -0.004, 0.007, 16, chamfer=0.0015,
              mx=T(sx * xi, 0, zb) @ R("Y", -90 * sx))
    return p.done(col)


def step(col=None, width=0.26, height=0.11, depth=0.075):
    """Recessed kick-in step. Mounted on a side wall, local +Y is UP: the -Y wall is the ribbed tread,
    the floor slopes from deep (tread) to shallow (+Y)."""
    p = _Part("step")
    bez = 0.014
    ol = _ol_rr(width, height, 0.014, n=1)
    faces = _housing(p, ol, bez, depth, band=0.005,
                     inner="paint_grey", wall="paint_grey")
    y0, y1 = -height / 2 + bez, height / 2 - bez
    dmin = 0.014
    verts = {v for f in faces for v in f.verts}
    for v in verts:
        if v.co.z < -0.0046:
            t = min(1.0, max(0.0, (v.co.y - y0) / (y1 - y0)))
            dz = depth + (dmin - depth) * t
            v.co.z = -0.0045 + (v.co.z + 0.0045) * (dz - 0.0045) / (depth - 0.0045)
    p.bm.normal_update()
    # floor gets the dark cavity material, walls stay metal
    ifl = p.mi("paint_grey")
    for f in faces:
        f.normal_update()
        if f.normal.z > 0.3 and f.calc_center_median().z < -0.006:
            f.material_index = ifl
    wi = width - 2 * bez
    for i in range(5):
        z = -0.014 - 0.0118 * i
        p.add("metal_dark", kit.box, (wi + 0.002, 0.0026, 0.0034), center=(0, y0 + 0.0009, z), bevel=0.0008, segs=1)
    # hazard edge on the tread nose (bezel top, -Y side)
    hz = p.mi("paint_hazard")
    for f in faces:
        c = f.calc_center_median()
        if f.normal.z > 0.9 and c.z > 0.003 and c.y < -height / 2 + bez and abs(c.x) < width / 2 - 0.02:
            f.material_index = hz
    _screws(p, [(sx * (width / 2 - 0.007), sy * (height / 2 - 0.007)) for sx in (-1, 1) for sy in (-1, 1)],
            0.004, 0.0036, kind="hex")
    return p.done(col)


def fastener(col=None, radius=0.011, mat="metal_steel"):
    """Flush button-head screw with hex socket (~1.5 mm proud at the default size). 58 tris, open bottom."""
    p = _Part("fastener")
    p.add(mat, _hex_screw, radius, recalc=False)
    return p.done(col)


def bolt(col=None, radius=0.014, height=0.010):
    """Hex bolt head on a washer (radius = washer radius). 102 tris, open bottom."""
    p = _Part("bolt")
    p.add(FINE_STEEL, _bolt_geom, radius, height, recalc=False)
    return p.done(col)


def hinge(col=None, length=0.12, knuckles=4):
    """External piano-hinge segment along X: two screwed leaves and alternating knuckles on a pin."""
    p = _Part("hinge")
    rk, zk, gap = 0.0062, 0.0050, 0.0012
    seg = (length - gap * (knuckles - 1)) / knuckles
    for i in range(knuckles):
        x0 = -length / 2 + i * (seg + gap)
        p.add(FINE_STEEL, kit.cylinder, rk, x0, x0 + seg, 10, chamfer=0.0009, mx=T(0, 0, zk) @ R("Y", 90),
              smooth=50.0)
    for sy in (-1, 1):
        leaf = (lambda yc:lambda d: kit.rect2(length + 2 * d, 0.022 + 2 * d, 0.0, yc))(sy * 0.0145)
        p.add(FINE_STEEL, _oloft, leaf, [(0.0, -0.008), (0.0, 0.0012), (-0.0009, 0.0021)])
    for sx in (-1, 1):
        for sy in (-1, 1):
            p.add(FINE_STEEL, _dome_screw, 0.0032, T(sx * length * 0.3, sy * 0.017, 0.0021), segs=10,
                  recalc=False, smooth=50.0)
    return p.done(col)


def latch(col=None, length=0.09, width=0.036):
    """Flush access latch: shallow pocket, flush paddle and a slotted quarter-turn head."""
    p = _Part("latch")
    bez = 0.0075
    ol = _ol_rr(length, width, 0.010, n=1)
    _housing(p, ol, bez, 0.0085, lip=0.003, band=0.003)
    g = 0.0014
    pad = _ol_rr(length - 2 * (bez + g), width - 2 * (bez + g), 0.004, n=1)
    p.add("paint_grey", _oloft, pad, [(0.0, -0.006), (0.0, 0.0015), (-0.0008, 0.0024)])
    hx = length / 2 - bez - g - 0.0095
    p.add("inner_dark", kit.cylinder, 0.0068, 0.0005, 0.0028, 12, mx=T(hx, 0, 0), smooth=50.0)
    rr = 0.0064

    def half(sx):
        def f(d):
            r = rr + d
            return [(hx + sx * (0.0007 + (r - 0.0007) * math.cos(t)), sx * r * math.sin(t))
                    for t in (-math.pi / 2 + math.pi * i / 6 for i in range(7))]
        return f
    for sx in (1, -1):
        p.add(FINE_STEEL, _oloft, half(sx), [(0.0, 0.0015), (0.0, 0.0033), (-0.0006, 0.0039)])
    return p.done(col)


def fuel_port(col=None, radius=0.10):
    """Round service port: bolted bezel with a hazard ring, recessed cap with a grip bar, small hinge (-Y)."""
    p = _Part("fuel_port")
    k = radius / 0.10
    segs = 32
    Rb = radius
    rw = 0.0745 * k            # bezel inner wall
    rh0, rh1 = 0.0765 * k, 0.0805 * k
    prof = [(0.0, -0.035), (Rb - 0.014, -0.035), (Rb - 0.014, -0.012), (Rb, -0.012), (Rb, 0.0015),
            (Rb - 0.0025, 0.004), (rh1, 0.004), (rh0, 0.004), (rw + 0.0015, 0.004), (rw, 0.0025), (rw, -0.030),
            (rw - 0.0025, -0.0325), (0.0, -0.0325)]

    def pk(f):
        c = f.calc_center_median()
        rr = math.hypot(c.x, c.y)
        if c.z > 0.0035 and rh0 < rr < rh1:
            return "paint_hazard"
        if c.z < -0.004:
            return "inner_dark"
        return None
    p.add("metal_dark", kit.lathe, prof, segs, pick=pk)
    p.props["cutout"] = [round(v, 5) for xy in kit.ngon2(segs, Rb - 0.009) for v in xy]
    p.props["cut_depth"] = 0.035
    _screws(p, kit.ngon2(8, (Rb + rh1) / 2, 22.5), 0.004, 0.0052 * k)
    rc, rg = 0.0725 * k, 0.045 * k
    cprof = [(0.0, -0.008), (rc, -0.008), (rc, 0.0010), (rc - 0.0015, 0.0025), (rg + 0.0015, 0.0025), (rg, 0.0010),
             (rg, -0.0042), (rg - 0.0015, -0.0055), (0.0, -0.0055)]
    p.add("metal_alu", kit.lathe, cprof, segs,
          pick=lambda f: "inner_dark" if f.calc_center_median().z < -0.004 else None)
    p.add("metal_dark", kit.box, (2 * rg + 0.003, 0.013 * k, 0.0085), center=(0, 0, -0.0028), bevel=0.0018, segs=2)
    # hinge on the -Y side
    yh = -(rc + 0.0012)
    p.add("metal_dark", kit.cylinder, 0.0038, -0.014, 0.014, 12, chamfer=0.0007, mx=T(0, yh, 0.0062) @ R("Y", 90),
          smooth=50.0)
    p.add("metal_dark", kit.box, (0.012, 0.016, 0.0034), center=(0, yh + 0.008, 0.0039), bevel=0.0009, segs=1)
    for sx in (-1, 1):
        p.add("metal_dark", kit.box, (0.0065, 0.014, 0.0034), center=(sx * 0.0105, yh - 0.0065, 0.0055), bevel=0.0009,
              segs=1)
    return p.done(col)


def tie_down(col=None, radius=0.04):
    """Recessed anchor ring: round pocket, flat-folded D-ring on a cross pin."""
    p = _Part("tie_down")
    segs = 16
    bez, depth = 0.012, 0.024
    _housing(p, _ol_circle(radius, segs), bez, depth, wall="paint_grey", inner="paint_grey")
    ri = radius - bez
    yp, zp = 0.6 * ri, -0.0095
    hc = math.sqrt(ri * ri - yp * yp)
    p.add(FINE_STEEL, kit.tube, [(-hc - 0.002, yp, zp), (hc + 0.002, yp, zp)], 0.0030, 8, smooth=50.0)
    Rr = 0.5 * (ri + yp) - 0.0035
    p.add(FINE_STEEL, kit.torus, Rr, 0.0032, 12, 6, mx=T(0, yp + 0.0018 - Rr, zp - 0.0012), smooth=60.0)
    return p.done(col)


def static_wick(col=None, length=0.18):
    """Trailing-edge static discharger pointing -Y: clamp foot, coated rod, needle tip."""
    p = _Part("static_wick")
    foot = _ol_cap(0.0075, 0.0045, 0.010, -0.016, 6, 4)
    p.add("metal_dark", _oloft, foot, [(0.0, -0.010), (0.0, 0.0045), (-0.0028, 0.0072)])
    zr = 0.0042
    yt = -length + 0.026
    p.add("plastic_black", kit.tube, [(0, -0.010, zr), (0, yt + 0.002, zr + 0.0045)], 0.0017, 6, smooth=70.0)
    p.add(FINE_STEEL, kit.lathe, [(0.0, -0.001), (0.0024, 0.0), (0.0024, 0.007), (0.0012, 0.022), (0.0, 0.026)], 6,
          mx=T(0, yt + 0.002, zr + 0.0045) @ R("X", 90), smooth=70.0)
    return p.done(col)


# ------------------------------------------------------------------------------------------
# stores pylon
# ------------------------------------------------------------------------------------------
def hardpoint(col=None, length=0.90, height=0.22, width=0.075):
    """Empty under-wing stores pylon, long axis Y (nose +Y). +Z points OUT of the wing skin (down when mounted):
    slim body with swept leading edge and tapered tail, bolted root doubler, keel rail with two suspension lugs
    (356 mm spacing) and two sway-brace pairs, screwed side access panels."""
    p = _Part("hardpoint")
    L, H, W = length, height, width / 2
    k = L / 0.9

    def hw(u):
        if u > 0.70:                       # swept, rounded leading edge
            t = (u - 0.70) / 0.30
            h = H * (1 - 0.70 * t ** 1.5)
        elif u < 0.26:                     # tapered tail
            h = H * (0.30 + 0.70 * math.sin(0.5 * math.pi * u / 0.26))
        else:
            h = H
        if u > 0.78:
            w = W * math.sqrt(max(0.0, 1 - ((u - 0.78) / 0.22) ** 2))
        elif u < 0.34:
            w = W * (0.14 + 0.86 * math.sin(0.5 * math.pi * u / 0.34))
        else:
            w = W
        return h, max(w, 0.0045)

    us = [0.0, 0.03, 0.08, 0.15, 0.24, 0.36, 0.50, 0.64, 0.74, 0.82, 0.88, 0.93, 0.965, 0.988, 1.0]
    rings = []
    for u in us:
        h, w = hw(u)
        y = -L / 2 + u * L
        r = 0.48 * w
        sec = [(w, -0.010)]
        sec += [(w - r + r * math.cos(a), h - r + r * math.sin(a)) for a in (0.0, math.pi / 6, math.pi / 3, math.pi / 2)]
        sec += [(-w + r - r * math.cos(a), h - r + r * math.sin(a)) for a in (math.pi / 2, math.pi / 3, math.pi / 6, 0.0)]
        sec += [(-w, -0.010)]
        rings.append([(x, y, z) for x, z in sec])
    p.add("paint_grey", kit.loft, rings)
    # root doubler on the skin
    dbl = _ol_cap(0.062, 0.042, L / 2 - 0.064, -L / 2 + 0.046, 10, 6)
    p.add("metal_dark", _oloft, dbl, [(0.0, -0.010), (0.0, 0.0045), (-0.002, 0.0065)])
    for x, y in kit.outline_points(dbl(0), 0.10 * k, inset=0.0085):
        p.add(FINE_STEEL, _dome_screw, 0.0034, T(x, y, 0.0065), segs=10, recalc=False, smooth=50.0)
    # keel rail
    p.add("metal_dark", kit.box, (0.044, 0.60 * k, 0.018), center=(0, -0.02 * k, H + 0.002), bevel=0.003, segs=2)
    for y in (-0.198 * k, 0.158 * k):     # suspension lugs, 14-inch spacing
        for sx in (-1, 1):
            p.add("metal_dark", kit.box, (0.0075, 0.036, 0.026), center=(sx * 0.0105, y, H + 0.020), bevel=0.0018,
                  segs=1)
        p.add("metal_chrome", kit.cylinder, 0.0050, -0.017, 0.017, 12, chamfer=0.0008,
              mx=T(0, y, H + 0.023) @ R("Y", 90), smooth=50.0)
    # sway braces: yoke across the rail, forged arms, screw jacks with rubber pads
    for y in (-0.31 * k, 0.27 * k):
        p.add("metal_dark", kit.box, (0.076, 0.028, 0.018), center=(0, y, H + 0.008), bevel=0.0025, segs=1)
        for sx in (-1, 1):
            a, b = V((sx * 0.030, y, H + 0.010)), V((sx * 0.068, y, H + 0.024))
            d = b - a
            p.add("metal_dark", kit.box, (0.020, 0.014, d.length + 0.012), mx=kit.frame((a + b) / 2, d, (0, 1, 0)),
                  bevel=0.002, segs=1)
            fj = kit.frame(b, V((sx * 0.40, 0, 1)).normalized(), (0, 1, 0))
            p.add("metal_chrome", kit.cylinder, 0.0058, -0.008, 0.028, 12, chamfer=0.0008, mx=fj, smooth=50.0)
            p.add("metal_dark", kit.lathe, [(0.0095, 0.005), (0.0095, 0.0115), (0.0, 0.0115)], 6, mx=fj)
            p.add("metal_dark", kit.cylinder, 0.0165, 0.025, 0.030, 12, chamfer=0.0012, mx=fj, smooth=50.0)
            p.add("rubber", kit.cylinder, 0.0150, 0.0295, 0.036, 12, chamfer=0.0018, mx=fj, smooth=50.0)
    # side access panels (graphite, low-wear paint)
    for sx in (-1, 1):
        p.add(THIN_PAINT, kit.box, (0.003, 0.24 * k, 0.09), center=(sx * (W - 0.0007), 0.02 * k, H * 0.50),
              bevel=0.0010, segs=1)
        for y in (-0.095 * k, 0.02 * k, 0.135 * k):
            for z in (H * 0.50 - 0.036, H * 0.50 + 0.036):
                p.add(FINE_STEEL, _dome_screw, 0.0030, kit.frame((sx * (W + 0.0008), y, z), (sx, 0, 0)),
                      recalc=False, smooth=50.0)
    return p.done(col)


# ------------------------------------------------------------------------------------------
# demo / contact sheets
# ------------------------------------------------------------------------------------------
_PARTS = [
    ("rcs_quad", rcs_quad, {}), ("rcs_single", rcs_single, {}), ("vent", vent, {}), ("grille", grille, {}),
    ("hardpoint", hardpoint, {}),
    ("nav_light_red", nav_light, {"color": "red"}), ("nav_light_green", nav_light, {"color": "green"}),
    ("nav_light_white", nav_light, {"color": "white"}), ("strobe", strobe, {}), ("landing_light", landing_light, {}),
    ("light_strip", light_strip, {}),
    ("antenna_blade", antenna_blade, {}), ("antenna_whip", antenna_whip, {}), ("pitot", pitot, {}),
    ("sensor_dome", sensor_dome, {}), ("sensor_window", sensor_window, {}), ("static_wick", static_wick, {}),
    ("handle", handle, {}), ("step", step, {}), ("fuel_port", fuel_port, {}), ("tie_down", tie_down, {}),
    ("latch", latch, {}), ("hinge", hinge, {}), ("fastener", fastener, {}), ("bolt", bolt, {}),
    ("fastener_fine", fastener, {"mat": "sp_metal_steel_fine"}),
]


def _plate(name, col, outline, holes=(), z0=-0.025, z1=0.0, mat="paint_white"):
    """Display plate (outline polygon, top at z1) with through-holes for recessed parts."""
    bm = bmesh.new()
    loops = [outline] + [list(hl) for hl in holes]
    te, be = [], []
    for lp in loops:
        n = len(lp)
        tv = [bm.verts.new((x, y, z1)) for x, y in lp]
        bv = [bm.verts.new((x, y, z0)) for x, y in lp]
        for i in range(n):
            j = (i + 1) % n
            te.append(bm.edges.new((tv[i], tv[j])))
            be.append(bm.edges.new((bv[i], bv[j])))
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((tv[i], tv[j], bv[j], bv[i]))
    bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=te)
    bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=False, edges=be)
    bmesh.ops.dissolve_limit(bm, angle_limit=0.001, verts=bm.verts[:], edges=bm.edges[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return kit.to_obj(name, bm, col, [mats.get(mat)], smooth=None, recalc=False)


def _layout(names=None, row_w=3.4, gap=0.08, col_name="SmallParts", frame_parts=False):
    col = kit.collection(col_name)
    objs, report, all_holes = [], [], []
    x = y = row_h = 0.0
    for name, fn, kw in _PARTS:
        if names is not None and name not in names:
            continue
        ob = fn(col, **kw)
        report.append((name, tris(ob)))
        bb = [V(c) for c in ob.bound_box]
        lo = V((min(c.x for c in bb), min(c.y for c in bb), 0))
        hi = V((max(c.x for c in bb), max(c.y for c in bb), 0))
        size = hi - lo
        m = max(0.035, 0.18 * max(size.x, size.y))
        tw, th = max(size.x + 2 * m, 0.10), max(size.y + 2 * m, 0.10)
        if x > 0 and x + tw > row_w:
            x, y, row_h = 0.0, y - row_h - gap, 0.0
        cx, cy = x + tw / 2, y - th / 2
        ob.location = (cx - (lo.x + hi.x) / 2, cy - (lo.y + hi.y) / 2, 0.0)
        holes = []
        if "cutout" in ob:
            c = list(ob["cutout"])
            holes.append([(c[i] + ob.location.x, c[i + 1] + ob.location.y) for i in range(0, len(c), 2)])
        all_holes += holes
        tile = kit.chamfer_rect2(tw, th, min(tw, th) * 0.08, cx, cy)
        objs += [ob, _plate("tile_" + name, col, tile, holes)]
        x += tw + gap
        row_h = max(row_h, th)
    lo, hi = kit.bbox_world(objs[1::2])
    slab = kit.rect2(hi.x - lo.x + 0.16, hi.y - lo.y + 0.16, (lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
    objs.append(_plate("slab", col, slab, all_holes, -0.045, -0.025, "paint_dark"))
    if frame_parts:     # close-up: frame only the parts themselves (tiles/slab still render)
        objs = objs[0:-1:2]
    print("SMALLPARTS TRIS")
    for name, n in report:
        print("  %-18s %6d" % (name, n))
    return objs


def demo():
    return _layout(row_w=3.2)


def demo_a():   # RCS + vents
    return _layout(["rcs_quad", "rcs_single", "vent", "grille"], row_w=1.3, frame_parts=True)


def demo_b():   # lights
    return _layout(["nav_light_red", "nav_light_green", "nav_light_white", "strobe", "landing_light", "light_strip"],
                   row_w=0.75, frame_parts=True)


def demo_c():   # antennas / probes / sensors
    return _layout(["antenna_blade", "antenna_whip", "pitot", "sensor_dome", "sensor_window", "static_wick"],
                   row_w=1.0, frame_parts=True)


def demo_d():   # handles, ports, latches
    return _layout(["handle", "step", "fuel_port", "tie_down", "latch", "hinge"], row_w=0.75, frame_parts=True)


def demo_e():   # fasteners (library metal_steel vs fine-bevel variant)
    return _layout(["fastener", "fastener_fine", "bolt"], row_w=0.4, frame_parts=True)


def demo_f():   # stores pylon
    return _layout(["hardpoint"], frame_parts=True)


def demo_one():
    """Close-up of SP_PART=<name[,name..]> from _PARTS; SP_FRAME=part frames the parts only (tight)."""
    objs = _layout(os.environ.get("SP_PART", "rcs_quad").split(","), row_w=float(os.environ.get("SP_ROW", "0.5")),
                   frame_parts=os.environ.get("SP_FRAME") == "part")
    zmax = os.environ.get("SP_ZMAX")      # frame only the part region below this height (e.g. whip base)
    if zmax:
        lo, hi = kit.bbox_world(objs)
        z1 = min(hi.z, float(zmax))
        ob = kit.to_obj("zoom_box", kit.box((hi.x - lo.x, hi.y - lo.y, z1 - lo.z),
                                            center=((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + z1) / 2)))
        ob.hide_render = True
        objs = [ob]
    return objs
