"""ST-7 Tern - DRIFT DRIVE tail unit (the exotic FTL "drift coil" on the fuselage transom).

Local space: +Z out of the transom (aft when mounted), z = 0 = transom plane, origin = footprint centre,
+X = ship starboard, +Y = ship up. Everything stays inside x in +-width/2, y in +-height/2, z in [-0.05, depth].

Layout (rear view): octagonal back plate -> centre: segmented toroidal drift coil on four damped stand-offs,
terraced reflector dish with a needle emitter inside it, thin guard crown ring on eight struts;
left / right: finned heat-rejection packs with heat-tinted manifolds, outboard an RCS port (top) and a
service coupling (bottom); cable runs from the coil terminals to the packs, capacitor canisters, junction boxes.
"""
import math

import bmesh
from mathutils import Matrix

import kit
import mats
from kit import R, T, V

TAU = math.tau


# ------------------------------------------------------------------------------------------
# local helpers (not in kit)
# ------------------------------------------------------------------------------------------
def _merge(dst, src):
    """Append all geometry of bmesh `src` to `dst` (src is freed)."""
    src.verts.index_update()
    vm = [dst.verts.new(v.co) for v in src.verts]
    for f in src.faces:
        try:
            dst.faces.new([vm[v.index] for v in f.verts])
        except ValueError:
            pass
    src.free()


class _Acc:
    """One bmesh per material key; finished into one joined object."""

    def __init__(self):
        self.bms = {}

    def __call__(self, key):
        return self.bms.setdefault(key, bmesh.new())

    def add(self, key, piece):
        _merge(self(key), piece)

    def finish(self, name, col, matmap):
        objs = []
        for key, bm in self.bms.items():
            if not bm.faces:
                bm.free()
                continue
            objs.append(kit.to_obj(name + "_" + key, bm, col, [matmap[key]], smooth=38.0))
        return kit.join(objs, name)


def _cols(ax, ay, az, t=(0.0, 0.0, 0.0)):
    """4x4 from column vectors (local x, y, z axes) and translation."""
    m = Matrix((ax, ay, az)).transposed().to_4x4()
    m.translation = V(t)
    return m


def _mx_x(t=(0.0, 0.0, 0.0)):
    """Frame whose local Z runs along world +X (local x -> world Y, local y -> world Z)."""
    return _cols((0, 1, 0), (0, 0, 1), (1, 0, 0), t)


def _frame_ring(outer, inner, z0, z1, bm=None):
    """Closed solid between two convex CCW outlines with equal vertex counts (a flat frame)."""
    bm = bm or bmesh.new()
    n = len(outer)
    o0 = [bm.verts.new((x, y, z0)) for x, y in outer]
    o1 = [bm.verts.new((x, y, z1)) for x, y in outer]
    i0 = [bm.verts.new((x, y, z0)) for x, y in inner]
    i1 = [bm.verts.new((x, y, z1)) for x, y in inner]
    for j in range(n):
        k = (j + 1) % n
        bm.faces.new((o1[j], o1[k], i1[k], i1[j]))
        bm.faces.new((o0[j], i0[j], i0[k], o0[k]))
        bm.faces.new((o0[j], o0[k], o1[k], o1[j]))
        bm.faces.new((i0[j], i1[j], i1[k], i0[k]))
    return bm


def _pol(r, deg):
    a = math.radians(deg)
    return r * math.cos(a), r * math.sin(a)


def _bolt(P, x, y, z, r=0.009, mat="metal_steel", mx=None, washer=True):
    """Hex bolt head (+ washer) standing on the plane z, axis +Z (or along `mx`'s Z)."""
    m = (mx or Matrix.Identity(4)) @ T(x, y, z)
    bm = P(mat)
    if washer:
        kit.cylinder(r * 1.45, -0.001, 0.0022, 12, bm=bm, mx=m)
    kit.cylinder(r, 0.0015, 0.0075, 6, chamfer=0.0016, bm=bm, mx=m @ R("Z", 30))


def _bolt_circle(P, n, rad, z, r=0.008, start=0.0, mat="metal_steel", cx=0.0, cy=0.0):
    for i in range(n):
        x, y = _pol(rad, start + 360.0 * i / n)
        _bolt(P, cx + x, cy + y, z, r, mat)


def _bevelled(bm, w, segs=2, angle=30.0):
    kit.bevel_all(bm, w, segs, angle=angle)
    return bm


# ------------------------------------------------------------------------------------------
# sub-assemblies
# ------------------------------------------------------------------------------------------
def _back_plate(P, L):
    hx, hy = L["hx"], L["hy"]
    t = L["plate_t"]
    c = L["chamfer"]
    outline = kit.chamfer_rect2(2 * hx - 0.01, 2 * hy - 0.01, c)
    P.add("metal_dark", _bevelled(kit.prism(outline, -0.004, t), 0.007, 2))
    # raised perimeter frame with a bolt row
    outer = kit.offset_convex2(outline, -0.010)
    inner = kit.offset_convex2(outline, -0.062)
    P.add("metal_dark", _bevelled(_frame_ring(outer, inner, t - 0.002, t + 0.014), 0.004, 2))
    for x, y in kit.outline_points(outline, 0.115, inset=0.036):
        _bolt(P, x, y, t + 0.014, 0.0075)
    # inner recessed field: a thin darker liner plate (reads as a machined pocket inside the frame)
    field = kit.offset_convex2(outline, -0.070)
    P.add("plate", _bevelled(kit.prism(field, t - 0.002, t + 0.004), 0.002, 1))


def _drive_bed(P, L):
    """Central circular bed: flange ring, recessed cradle, bolt circles."""
    k, t = L["k"], L["plate_t"]
    ro, ri = L["bed_r"], 0.300 * k
    z1 = L["bed_z"]
    kit.ring(ro, ri, t - 0.002, z1, 128, chamfer=0.006, bm=P("metal_dark"))
    # stepped inner lip (machined steel) and the dark recess below the dish
    kit.ring(ri + 0.004, ri - 0.018 * k, t, z1 - 0.012, 128, chamfer=0.003, bm=P("metal_steel"))
    kit.cylinder(ri - 0.010 * k, t - 0.002, t + 0.010, 96, bm=P("inner_dark"))
    # groove ring on the flange face (thin raised steel band) + bolts
    kit.ring(ro - 0.018 * k, ro - 0.026 * k, z1 - 0.001, z1 + 0.003, 128, chamfer=0.001, bm=P("metal_steel"))
    _bolt_circle(P, 32, ro - 0.040 * k, z1, 0.0065, start=0.0)


def _reflector(P, L):
    """Terraced parabolic reflector dish with the needle emitter on its axis."""
    k, kz = L["k"], L["kz"]
    z0 = L["dish_z0"]
    rl = L["dish_r"]
    zl = L["dish_z1"]
    kk = (zl - z0) / (rl * rl)
    zf = lambda r: z0 + kk * r * r  # noqa: E731
    th = 0.014 * kz
    # front (concave) surface with machined terraces: every band ends in a small vertical step
    bands = [0.072, 0.114, 0.152, 0.188, 0.222, rl / k]
    front = []
    step = 0.0045 * kz
    prev = 0.052 * k
    front.append((prev, zf(prev)))
    for b in bands:
        rb = b * k
        front.append((rb, zf(rb) - step))
        if rb < rl - 1e-6:
            front.append((rb + 0.0012, zf(rb) + 0.0004))
            # dark machined bead in every terrace step: crisp concentric rings when seen from aft
            kit.torus(rb + 0.0016, 0.0024, 96, 6, bm=P("metal_dark"), mx=T(0, 0, zf(rb) - step * 0.5))
    back = [(r, z - th) for r, z in front]
    # solid: back surface outward, lip, front surface inward
    prof = [(0.0, front[0][1] - th)] + back + [(rl + 0.010 * k, zl - th * 0.5), (rl + 0.010 * k, zl + 0.002)]
    prof += list(reversed(front)) + [(0.0, front[0][1])]
    kit.lathe(prof, 128, P("metal_alu"))
    # lip ring (steel) with a fine bolt circle
    kit.ring(rl + 0.016 * k, rl - 0.006 * k, zl - 0.010 * kz, zl + 0.008 * kz, 128, chamfer=0.003, bm=P("metal_steel"))
    _bolt_circle(P, 24, rl + 0.005 * k, zl + 0.008 * kz, 0.0045, start=7.5)
    # dish support: short skirt down to the bed
    kit.cylinder(0.075 * k, L["plate_t"], z0, 48, chamfer=0.004, bm=P("metal_dark"))
    # six radial gussets carrying the dish back (top edge follows the bowl, tucked into its back)
    tb = L["plate_t"] + 0.004
    rs = [0.070 * k + (0.235 * k - 0.070 * k) * i / 5 for i in range(6)]
    top = [(r, zf(r) - th - 0.002) for r in reversed(rs)]
    poly = [(0.070 * k, tb), (0.200 * k, tb)] + top
    for i in range(6):
        g = _bevelled(kit.prism(poly, -0.004, 0.004), 0.0012, 1, 40.0)
        bmesh.ops.transform(g, matrix=R("Z", 30.0 + 60.0 * i) @ _cols((1, 0, 0), (0, 0, 1), (0, -1, 0)),
                            verts=g.verts[:])
        P.add("metal_dark", g)
    # emitter hub with a soft glowing annulus around it
    hz = z0 + 0.045 * kz
    kit.lathe([(0.0, z0 - 0.004), (0.050 * k, z0 - 0.004), (0.050 * k, z0 + 0.012 * kz), (0.040 * k, z0 + 0.020 * kz),
               (0.030 * k, z0 + 0.030 * kz), (0.024 * k, hz), (0.0, hz)], 48, P("metal_steel"))
    kit.ring(0.064 * k, 0.049 * k, z0, z0 + 0.016 * kz, 64, bm=P("core"))
    kit.ring(0.070 * k, 0.064 * k, z0, z0 + 0.021 * kz, 64, chamfer=0.001, bm=P("metal_brass"))
    for i in range(6):   # little hold-down screws on the hub shoulder
        x, y = _pol(0.040 * k, 30 + 60 * i)
        kit.cylinder(0.0045, z0 + 0.010 * kz, z0 + 0.018 * kz, 12, chamfer=0.001, bm=P("metal_dark"), mx=T(x, y, 0))
    # needle emitter: tapered rod with brass collars and a glowing spark gap / tip
    nz = L["needle_z"]
    kit.lathe([(0.0, hz - 0.002), (0.016 * k, hz - 0.002), (0.016 * k, hz + 0.030 * kz), (0.010 * k, hz + 0.045 * kz),
               (0.0068, nz - 0.090 * kz), (0.0048, nz - 0.040 * kz), (0.0030, nz - 0.014 * kz), (0.0, nz - 0.010 * kz)],
              24, P("metal_chrome"))
    for zz, rr in ((hz + 0.075 * kz, 0.0125), (hz + 0.160 * kz, 0.0105), (hz + 0.255 * kz, 0.0092)):
        kit.cylinder(rr, zz - 0.006, zz + 0.006, 24, chamfer=0.0018, bm=P("metal_brass"))
    gz = hz + 0.205 * kz
    kit.cylinder(0.0088, gz - 0.0025, gz + 0.0025, 24, bm=P("seam"))
    kit.cylinder(0.0100, gz - 0.009, gz - 0.0025, 24, chamfer=0.0012, bm=P("ceramic"))
    kit.cylinder(0.0100, gz + 0.0025, gz + 0.009, 24, chamfer=0.0012, bm=P("ceramic"))
    kit.lathe([(0.0, nz - 0.016 * kz), (0.0040, nz - 0.010 * kz), (0.0028, nz - 0.003), (0.0, nz)], 16, P("tip"))


def _tor_pt(L, deg, rad=0.0, up=0.0):
    """Point on the coil centre circle (+ radial / +Z offsets)."""
    a = math.radians(deg)
    R0 = L["R"] + rad
    return V((R0 * math.cos(a), R0 * math.sin(a), L["zc"] + up))


def _tor_frame(L, deg):
    """Frame on the coil centre line: local Z = tangent (CCW), local X = radial out, local Y = -Z world."""
    a = math.radians(deg)
    return kit.frame(_tor_pt(L, deg), (-math.sin(a), math.cos(a), 0.0), (math.cos(a), math.sin(a), 0.0))


def _winding(P, L, a0, a1, turns=14, steps_per_turn=4, segs=16):
    """One wound coil segment between angles a0..a1 (deg): rippled tube = individual wire turns."""
    r_w = L["r"] * 0.93
    amp = L["r"] * 0.085
    n = turns * steps_per_turn
    rings = []
    for i in range(n + 1):
        u = i / n
        a = math.radians(a0 + (a1 - a0) * u)
        bump = math.sqrt(abs(math.sin(math.pi * turns * u)))
        rr = r_w + amp * bump
        c = V((L["R"] * math.cos(a), L["R"] * math.sin(a), L["zc"]))
        nrm = V((math.cos(a), math.sin(a), 0.0))
        zz = V((0.0, 0.0, 1.0))
        rings.append([c + (nrm * math.cos(TAU * j / segs) + zz * math.sin(TAU * j / segs)) * rr for j in range(segs)])
    kit.loft(rings, P("copper"))
    # brass end caps of the winding
    r = L["r"]
    for a, sgn in ((a0, 1.0), (a1, -1.0)):
        m = _tor_frame(L, a)
        z0, z1 = (0.0, 0.007) if sgn > 0 else (-0.007, 0.0)
        kit.cylinder(r * 1.06, z0, z1, 28, chamfer=0.0015, bm=P("metal_brass"), mx=m)
    # binding band across the middle of the winding (dark steel strap)
    m = _tor_frame(L, (a0 + a1) * 0.5)
    kit.ring(r * 1.09, r * 0.9, -0.006, 0.006, 32, chamfer=0.0015, bm=P("metal_dark"), mx=m)


def _collar(P, L, deg, half):
    """Insulator collar between windings: brass flanges, ceramic insulators, a recessed glowing seam."""
    m = _tor_frame(L, deg)
    r = L["r"]
    g = 0.0028           # half width of the glowing slot
    cer = half - 0.0065  # end of ceramic
    # ceramic insulators with a small shed profile
    for s in (1.0, -1.0):
        prof = [(0.0, g), (r * 1.18, g), (r * 1.25, g + 0.003), (r * 1.25, cer - 0.004), (r * 1.20, cer), (0.0, cer)]
        if s < 0:
            prof = [(rr, -zz) for rr, zz in reversed(prof)]
        kit.lathe(prof, 36, P("ceramic"), mx=m)
        z0, z1 = sorted((s * cer, s * half))
        kit.cylinder(r * 1.16, z0, z1, 36, chamfer=0.0016, bm=P("metal_brass"), mx=m)
    kit.cylinder(r * 1.165, -g - 0.0005, g + 0.0005, 36, bm=P("seam"), mx=m)


def _coil(P, L, nseg=12):
    step = 360.0 / nseg
    half = 0.025 * L["k"]                       # collar half length (m, along the tangent)
    half_deg = math.degrees(half / L["R"])
    ov = math.degrees(0.0008 / L["R"])
    for i in range(nseg):
        a = step * i
        _collar(P, L, a, half)
        _winding(P, L, a + half_deg - ov, a + step - half_deg + ov)


def _clamp(P, L, deg):
    """Heavy pinch clamp around the coil tube on a damped stand-off down to the drive bed."""
    m = _tor_frame(L, deg)
    r = L["r"]
    k = L["k"]
    # clamp band
    kit.ring(r * 1.30, r * 1.02, -0.032 * k, 0.032 * k, 40, chamfer=0.004, bm=P("metal_steel"), mx=m)
    kit.ring(r * 1.34, r * 1.26, -0.020 * k, 0.020 * k, 40, chamfer=0.002, bm=P("metal_dark"), mx=m)
    # pinch ears on the outer side (local +X) with a through bolt along local Y
    for s in (1.0, -1.0):
        kit.box((0.040 * k, 0.020 * k, 0.050 * k), center=(r * 1.26 + 0.016 * k, s * 0.0135 * k, 0.0), bevel=0.003,
                bm=P("metal_steel"), mx=m)
    bm_ = P("metal_dark")
    bx = r * 1.26 + 0.022 * k
    kit.cylinder(0.0055, -0.032 * k, 0.032 * k, 12, bm=bm_, mx=m @ T(bx, 0, 0) @ R("X", -90))
    for s in (1.0, -1.0):
        zz = s * 0.0235 * k
        kit.cylinder(0.0105, min(zz, zz + s * 0.008), max(zz, zz + s * 0.008), 6, chamfer=0.0015,
                     bm=P("metal_steel"), mx=m @ T(bx, 0, 0) @ R("X", -90))
    # saddle block towards the plate (local +Y = world -Z)
    zc, st_top = L["zc"], L["st_top"]
    sy0, sy1 = r * 0.95, zc - st_top + 0.004
    kit.box((0.060 * k, sy1 - sy0, 0.056 * k), center=(0.0, (sy0 + sy1) * 0.5, 0.0), bevel=0.005, bm=P("metal_dark"),
            mx=m)
    # stand-off: foot, octagonal damper body, chrome rod, top cap
    x, y = _pol(L["R"], deg)
    zb = L["bed_z"]
    base = T(x, y, 0.0) @ R("Z", deg)
    kit.box((0.078 * k, 0.070 * k, 0.018), center=(0, 0, zb + 0.009), bevel=0.004, bm=P("metal_dark"), mx=base)
    for bx_, by_ in ((-0.027, -0.024), (0.027, -0.024), (-0.027, 0.024), (0.027, 0.024)):
        _bolt(P, bx_ * k, by_ * k, zb + 0.018, 0.0055, mx=base)
    h = st_top - zb - 0.018
    z_body1 = zb + 0.018 + h * 0.52
    kit.cylinder(0.026 * k, zb + 0.018, z_body1, 8, chamfer=0.004, bm=P("metal_dark"), mx=base @ R("Z", 22.5))
    kit.cylinder(0.029 * k, z_body1 - 0.016, z_body1 - 0.006, 32, chamfer=0.002, bm=P("metal_brass"), mx=base)
    kit.cylinder(0.0115 * k, z_body1 - 0.002, st_top - 0.020, 24, bm=P("metal_chrome"), mx=base)
    kit.cylinder(0.022 * k, st_top - 0.030, st_top + 0.004, 32, chamfer=0.003, bm=P("metal_steel"), mx=base)


def _terminal(P, L, side):
    """Bus terminal box on the coil's outer equator (3 / 9 o'clock) - cables leave from here."""
    k = L["k"]
    r = L["r"]
    x0 = L["R"] + r * 1.15
    zc = L["zc"]
    bm = P("metal_dark")
    kit.box((0.040 * k, 0.110 * k, 0.130 * k), center=(side * (x0 + 0.018 * k), 0.0, zc - 0.010), bevel=0.005, bm=bm)
    kit.box((0.006, 0.080 * k, 0.090 * k), center=(side * (x0 + 0.040 * k), 0.0, zc - 0.006), bevel=0.0015,
            bm=P("metal_steel"))
    for sy in (-1, 1):
        for sz in (-1, 1):
            _bolt(P, sy * 0.032 * k, sz * 0.038 * k, 0.0, 0.0038,
                  mx=kit.frame((side * (x0 + 0.043 * k), 0, zc - 0.006), (side, 0, 0), (0, 1, 0)), washer=False)
    # cable glands under the box
    for sy in (-1, 1):
        kit.cylinder(0.017 * k, 0.0, 0.020, 16, chamfer=0.002, bm=P("metal_brass"),
                     mx=T(side * (x0 + 0.014 * k), sy * 0.028 * k, zc - 0.073 * k) @ R("X", 180))


def _clip(P, x, y, base, cr, span, w=0.020):
    """Strap clip over a pair of cables lying on `base` (cables run along X; strap spans Y)."""
    top = base + 2 * cr
    kit.box((w, span, 0.008), center=(x, y, top + 0.003), bevel=0.0022, bm=P("metal_steel"))
    for sy in (-1, 1):
        yy = y + sy * (span * 0.5 - 0.005)
        kit.box((w, 0.010, top + 0.007 - base), center=(x, yy, (base + top + 0.007) * 0.5), bevel=0.002,
                bm=P("metal_steel"))
        kit.box((w, 0.020, 0.004), center=(x, yy + sy * 0.009, base + 0.002), bevel=0.0012, bm=P("metal_steel"))
        _bolt(P, x, yy + sy * 0.013, base + 0.004, 0.0035, washer=False)


def _cables(P, L, side):
    """Two power conduits: terminal box -> down -> over the bed -> along the plate -> radiator inboard cheek."""
    k = L["k"]
    xr = L["R"] + L["r"] * 1.15 + 0.014 * k
    zc = L["zc"]
    zb = L["bed_z"]
    tl = L["liner_z"]
    x_in = L["rad_x0"]
    cr = 0.0105 * k
    zh = zb + 0.002 + cr          # cable centre height while lying on the bed
    for sy in (-1, 1):
        y = sy * 0.028 * k
        pts = [(xr, y, zc - 0.090 * k), (xr, y, zh), (L["bed_r"] + 0.012, y, zh),
               (L["bed_r"] + 0.050, y, tl + cr), (x_in - 0.020, y, tl + cr)]
        pts = [(side * x, yy, z) for x, yy, z in pts]
        kit.tube(pts, cr, 12, P("rubber"), fillet=0.03)
        # ferrule + gland at the radiator end
        kit.cylinder(cr * 1.45, 0.0, 0.026, 16, chamfer=0.002, bm=P("metal_steel"),
                     mx=kit.frame((side * (x_in - 0.022), y, tl + cr), (side, 0, 0), (0, 1, 0)))
        kit.cylinder(cr * 1.7, 0.0, 0.006, 6, chamfer=0.0015, bm=P("metal_brass"),
                     mx=kit.frame((side * (x_in - 0.006), y, tl + cr), (side, 0, 0), (0, 1, 0)))
    _clip(P, side * (xr - 0.028), 0.0, zb, cr, 0.090 * k)
    _clip(P, side * (x_in - 0.055), 0.0, tl, cr, 0.090 * k)


def _guard(P, L):
    """Thin guard crown ring on eight struts around the coil."""
    k = L["k"]
    rg_o, rg_i = L["guard_r"], L["guard_r"] - 0.026 * k
    z0, z1 = L["guard_z"], L["guard_z"] + 0.034
    kit.ring(rg_o, rg_i, z0, z1, 160, chamfer=0.004, bm=P("metal_steel"))
    kit.ring(rg_o - 0.005 * k, rg_i + 0.005 * k, z1 - 0.001, z1 + 0.003, 160, chamfer=0.0012, bm=P("metal_dark"))
    rs = (rg_o + rg_i) * 0.5
    zb = L["bed_z"]
    for i in range(8):
        a = 22.5 + 45.0 * i
        x, y = _pol(rs, a)
        m = T(x, y, 0.0) @ R("Z", a)
        kit.box((0.015 * k, 0.020 * k, z0 - zb), center=(0, 0, (z0 + zb) * 0.5), bevel=0.003, bm=P("metal_dark"), mx=m)
        kit.box((0.024 * k, 0.038 * k, 0.020), center=(0, 0, zb + 0.010), bevel=0.003, bm=P("metal_steel"), mx=m)
        kit.box((0.026 * k, 0.034 * k, 0.026), center=(0, 0, z0 - 0.011), bevel=0.003, bm=P("metal_steel"), mx=m)
        _bolt(P, 0.0, 0.0, z1 + 0.003, 0.0055, mx=m)
    for a in (0, 90, 180, 270):  # machined index pips
        x, y = _pol(rs, a)
        kit.box((0.010, 0.010, 0.004), center=(x, y, z1 + 0.003), bevel=0.0015, bm=P("metal_brass"))


def _radiator(P, L, side):
    """Finned heat-rejection pack with tie rods, cheek plates and heat-tinted manifolds."""
    k = L["k"]
    t = L["liner_z"]
    x0, x1 = L["rad_x0"], L["rad_x1"]
    hy = 0.315 * k
    zt = L["rad_z"]
    sx = side
    # base tray
    kit.box((x1 - x0, 2 * hy, 0.062), center=(sx * (x0 + x1) * 0.5, 0.0, t + 0.030), bevel=0.008, bm=P("metal_dark"))
    # cheeks: chamfered profile in (y, z), extruded along X
    cheek_t = 0.020
    prof = kit.chamfer_rect2(2 * hy, zt - t, 0.06 * k, 0.0, (zt + t) * 0.5, corners=(0, 0, 1, 1))
    for xa in (x0, x1 - cheek_t):
        bm = _bevelled(kit.prism(prof, 0.0, cheek_t), 0.004, 2)
        bmesh.ops.transform(bm, matrix=_mx_x((sx * xa if sx > 0 else sx * xa - cheek_t, 0, 0)), verts=bm.verts[:])
        P.add("metal_dark", bm)
    # fins
    nf = L["fins"]
    fy = 0.272 * k
    fz0, fz1 = t + 0.058, zt - 0.012
    fprof = kit.chamfer_rect2(2 * fy, fz1 - fz0, 0.045 * k, 0.0, (fz0 + fz1) * 0.5, corners=(0, 0, 1, 1))
    xa, xb = x0 + cheek_t + 0.008, x1 - cheek_t - 0.008
    ft = 0.0045
    for i in range(nf):
        xc = xa + (xb - xa) * (i + 0.5) / nf
        bm = _bevelled(kit.prism(fprof, -ft * 0.5, ft * 0.5), 0.0012, 1)
        bmesh.ops.transform(bm, matrix=_mx_x((sx * xc, 0, 0)), verts=bm.verts[:])
        P.add("metal_alu", bm)
    # tie rods through the fin pack with nuts outside the cheeks
    lo, hi = sorted((sx * (x0 - 0.008), sx * (x1 + 0.008)))
    for yy, zz in ((0.120 * k, zt - 0.045), (-0.120 * k, zt - 0.045), (0.0, fz0 + 0.050)):
        kit.cylinder(0.0055, lo, hi, 12, bm=P("metal_steel"), mx=T(0, yy, zz) @ _mx_x())
        for xo in (sx * (x0 - 0.004), sx * (x1 + 0.004)):
            kit.cylinder(0.011, -0.004, 0.004, 6, chamfer=0.0015, bm=P("metal_steel"),
                         mx=kit.frame((xo, yy, zz), (1, 0, 0), (0, 1, 0)))
    # manifolds (top & bottom headers) running along the fin edges
    zm = (fz0 + fz1) * 0.5 + 0.02
    mr = 0.021 * k
    for sy in (-1, 1):
        y = sy * (fy + 0.010 * k)
        a, b = sx * (x0 - 0.012), sx * (x1 + 0.016)
        kit.tube([(a, y, zm), (b, y, zm)], mr, 24, P("heat"))
        kit.lathe([(0.0, -0.002), (mr * 1.05, -0.002), (mr * 1.05, 0.006), (mr * 0.75, 0.016), (0.0, 0.020)], 24,
                  P("heat"), mx=kit.frame((b, y, zm), (sx, 0, 0), (0, 1, 0)))
        for xe in (x0 - 0.009, x1 + 0.007):
            kit.cylinder(mr * 1.45, -0.0045, 0.0045, 24, chamfer=0.0015, bm=P("metal_steel"),
                         mx=kit.frame((sx * xe, y, zm), (1, 0, 0), (0, 1, 0)))
        # inboard riser: elbow down into a bolted boss on the plate
        xr = x0 - 0.050
        kit.tube([(sx * (x0 - 0.010), y, zm), (sx * xr, y, zm), (sx * xr, y, t + 0.012)], mr, 24, P("heat"),
                 fillet=0.035)
        kit.cylinder(mr * 1.6, t - 0.002, t + 0.016, 24, chamfer=0.003, bm=P("metal_steel"), mx=T(sx * xr, y, 0))
        _bolt_circle(P, 4, mr * 2.2, t, 0.0042, start=45, cx=sx * xr, cy=y)
        kit.cylinder(mr * 1.35, zm - 0.090, zm - 0.080, 24, chamfer=0.002, bm=P("metal_brass"), mx=T(sx * xr, y, 0))
    # stiffening ribs on the plate above / below the pack
    for sy in (-1, 1):
        ya, yb = hy - 0.004, L["hy"] - 0.070
        if yb - ya < 0.04:
            continue
        for f in (0.22, 0.5, 0.78):
            xc = sx * (x0 + (x1 - x0) * f)
            bm = _bevelled(kit.prism([(0.0, 0.0), (yb - ya, 0.0), (yb - ya, 0.010), (0.0, 0.036)], -0.006, 0.006),
                           0.0015, 1)
            mx = _cols((0, sy, 0), (0, 0, 1), (sy, 0, 0), (xc, sy * ya, t - 0.001))
            bmesh.ops.transform(bm, matrix=mx, verts=bm.verts[:])
            P.add("metal_dark", bm)
    # outboard cheek: raised access panel with screws and a vent grille
    xo = sx * (x1 + 0.002)
    zmid = (t + zt) * 0.5 - 0.01
    kit.box((0.006, 0.40 * k, 0.22), center=(xo, 0.0, zmid), bevel=0.002, bm=P("metal_dark"))
    for yy in (-0.18 * k, 0.0, 0.18 * k):
        for zz in (zmid - 0.095, zmid + 0.095):
            kit.cylinder(0.0045, 0.0, 0.004, 12, chamfer=0.001, bm=P("metal_steel"),
                         mx=kit.frame((xo + sx * 0.003, yy, zz), (sx, 0, 0), (0, 1, 0)))
    for j in range(5):
        zz = zmid - 0.050 + j * 0.025
        kit.box((0.006, 0.20 * k, 0.010), center=(xo + sx * 0.0015, 0.0, zz), bevel=0.002, bm=P("inner_dark"))
    # hazard tag on the outboard cheek top
    kit.box((0.012, 0.11 * k, 0.004), center=(sx * (x1 - 0.010), 0.0, zt + 0.0015), bevel=0.0012, bm=P("paint_hazard"))


def _rcs_port(P, L, side):
    """Small auxiliary (RCS) thruster on a bolted square mount, outboard top."""
    k = L["k"]
    t = L["liner_z"]
    x, y = side * L["out_x"], L["out_y"]
    s = 0.094 * k
    kit.box((s, s, 0.040), center=(x, y, t + 0.019), bevel=0.006, bm=P("metal_dark"))
    for bx, by in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        _bolt(P, x + bx * s * 0.36, y + by * s * 0.36, t + 0.039, 0.0042)
    m = T(x, y, t + 0.039)
    kit.lathe([(0.0, -0.002), (0.032 * k, -0.002), (0.032 * k, 0.010), (0.026 * k, 0.018), (0.028 * k, 0.024),
               (0.042 * k, 0.060), (0.042 * k, 0.064), (0.038 * k, 0.064), (0.023 * k, 0.026), (0.0, 0.022)], 40,
              P("metal_steel"), mx=m)
    kit.cylinder(0.022 * k, 0.020, 0.028, 32, bm=P("inner_dark"), mx=m)
    kit.ring(0.034 * k, 0.027 * k, 0.010, 0.016, 32, chamfer=0.001, bm=P("metal_brass"), mx=m)
    # keep-clear hazard plate under the mount
    kit.box((s + 0.016, s + 0.016, 0.003), center=(x, y, t + 0.0005), bevel=0.0012, bm=P("paint_hazard"))


def _service_coupling(P, L, side):
    """Ground service coupling with an orange dust cap, outboard bottom."""
    k = L["k"]
    t = L["liner_z"]
    x, y = side * L["out_x"], -L["out_y"]
    m = T(x, y, t)
    kit.cylinder(0.044 * k, -0.001, 0.026, 6, chamfer=0.004, bm=P("metal_dark"), mx=m @ R("Z", 30))
    for i in range(6):
        bx, by = _pol(0.034 * k, 60 * i)
        _bolt(P, x + bx, y + by, t + 0.026, 0.0036, washer=False)
    kit.cylinder(0.026 * k, 0.026, 0.074, 32, chamfer=0.003, bm=P("metal_steel"), mx=m)
    kit.ring(0.030 * k, 0.025 * k, 0.040, 0.048, 32, chamfer=0.001, bm=P("metal_dark"), mx=m)
    kit.cylinder(0.030 * k, 0.072, 0.096, 32, chamfer=0.004, bm=P("paint_accent"), mx=m)
    for i in range(8):   # grip lugs on the cap
        kit.box((0.008, 0.006, 0.016), center=(0.031 * k, 0.0, 0.084), bevel=0.0015, bm=P("paint_accent"),
                mx=m @ R("Z", 45.0 * i))


def _strip_gear(P, L, side):
    """Between the drive bed and the radiator: junction box (top), capacitor canisters (bottom)."""
    k = L["k"]
    t = L["liner_z"]
    x0 = L["rad_x0"]
    xm = side * (L["bed_r"] + x0 - 0.065) * 0.5
    sx = side
    # junction box with a hazard lid and a short conduit into the radiator cheek
    jy = 0.150 * k
    kit.box((0.070, 0.110 * k, 0.060), center=(xm, jy, t + 0.029), bevel=0.006, bm=P("metal_dark"))
    kit.box((0.054, 0.086 * k, 0.005), center=(xm, jy, t + 0.060), bevel=0.0016, bm=P("paint_hazard"))
    for bx, by in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        kit.cylinder(0.0034, t + 0.0605, t + 0.0655, 12, chamfer=0.001, bm=P("metal_steel"),
                     mx=T(xm + bx * 0.0305, jy + by * 0.050 * k, 0))
    xa = xm + sx * 0.035
    kit.tube([(xa, jy, t + 0.030), (sx * x0, jy, t + 0.030)], 0.0075, 12, P("rubber"))
    for xx in (xa, sx * (x0 - 0.004)):
        kit.cylinder(0.0105, -0.005, 0.005, 16, chamfer=0.0015, bm=P("metal_brass"),
                     mx=kit.frame((xx, jy, t + 0.030), (1, 0, 0), (0, 1, 0)))
    # capacitor canisters on a bracket plate
    by0 = -0.170 * k
    kit.box((0.078, 0.150 * k, 0.010), center=(xm, by0, t + 0.004), bevel=0.003, bm=P("metal_steel"))
    for yy in (by0 + 0.036 * k, by0 - 0.036 * k):
        mm = T(xm, yy, 0)
        kit.cylinder(0.028, t + 0.008, t + 0.112, 32, chamfer=0.004, bm=P("metal_alu"), mx=mm)
        kit.cylinder(0.0295, t + 0.036, t + 0.050, 32, chamfer=0.0015, bm=P("metal_dark"), mx=mm)
        kit.cylinder(0.021, t + 0.111, t + 0.118, 24, chamfer=0.0015, bm=P("plastic_black"), mx=mm)
        for ex in (-1, 1):
            kit.cylinder(0.0045, t + 0.116, t + 0.128, 12, chamfer=0.001, bm=P("metal_brass"),
                         mx=T(xm + ex * 0.010, yy, 0))
    _bolt(P, xm - 0.030, by0 + 0.064 * k, t + 0.009, 0.0042, washer=False)
    _bolt(P, xm + 0.030, by0 - 0.064 * k, t + 0.009, 0.0042, washer=False)


# ------------------------------------------------------------------------------------------
# public
# ------------------------------------------------------------------------------------------
def layout(width=2.30, height=0.95, depth=0.70):
    """Derived dimensions (all parts reference these)."""
    k = height / 0.95
    kz = depth / 0.70
    hx, hy = width / 2, height / 2
    L = dict(hx=hx, hy=hy, k=k, kz=kz, plate_t=0.040, chamfer=0.20 * k)
    L["bed_z"] = 0.088
    L["bed_r"] = 0.462 * k
    L["liner_z"] = 0.044
    L["R"] = 0.330 * k
    L["r"] = 0.075 * k
    L["zc"] = 0.372 * kz
    L["st_top"] = L["zc"] - L["r"] * 1.30 + 0.002
    L["dish_r"] = 0.255 * k
    L["dish_z0"] = 0.118 * kz
    L["dish_z1"] = 0.278 * kz
    L["needle_z"] = 0.640 * kz
    L["guard_r"] = 0.462 * k
    L["guard_z"] = 0.545 * kz
    L["rad_x0"] = L["bed_r"] + 0.115
    L["rad_x1"] = hx - 0.190
    L["rad_z"] = 0.420 * kz
    L["out_x"] = hx - 0.115
    L["out_y"] = 0.195 * k
    L["fins"] = max(6, int(round((L["rad_x1"] - L["rad_x0"]) / 0.030)))
    return L


def _materials(glow):
    g = max(float(glow), 0.0)
    M = {n: mats.get(n) for n in ("metal_dark", "metal_steel", "metal_alu", "metal_chrome", "metal_brass", "ceramic",
                                  "inner_dark", "rubber", "plastic_black", "paint_hazard",
                                  "paint_accent")}
    M["copper"] = mats.surface("dd_copper", (0.52, 0.215, 0.10), rough=0.30, metallic=1.0, wear=0.05, grime=0.45,
                               chip=(0.70, 0.42, 0.28))
    M["plate"] = mats.surface("dd_plate", (0.062, 0.064, 0.070), rough=0.48, metallic=0.55, wear=0.3, grime=0.25,
                              chip=(0.30, 0.30, 0.31))
    M["heat"] = mats.heat_metal("dd_heat", axis=2, start=0.06, length=0.55)
    M["seam"] = mats.emissive("dd_emit_seam_%.3f" % g, (0.15, 0.80, 1.0), 6.0 * g)
    M["core"] = mats.emissive("dd_emit_core_%.3f" % g, (0.22, 0.78, 1.0), 4.0 * g)
    M["tip"] = mats.emissive("dd_emit_tip_%.3f" % g, (0.60, 0.92, 1.0), 40.0 * g)
    return M


def build_drift_drive(col=None, width=2.30, height=0.95, depth=0.70, glow=1.0, name="DriftDrive"):
    """Drift drive tail unit as one joined mesh object (see module docstring for axes)."""
    L = layout(width, height, depth)
    P = _Acc()
    _back_plate(P, L)
    _drive_bed(P, L)
    _reflector(P, L)
    _coil(P, L, 12)
    for a in (45.0, 135.0, 225.0, 315.0):
        _clamp(P, L, a)
    _guard(P, L)
    for side in (1, -1):
        _terminal(P, L, side)
        _cables(P, L, side)
        _radiator(P, L, side)
        _rcs_port(P, L, side)
        _service_coupling(P, L, side)
        _strip_gear(P, L, side)
    ob = P.finish(name, col, _materials(glow))
    return ob


# ------------------------------------------------------------------------------------------
# demos (part_preview)
# ------------------------------------------------------------------------------------------
_MOUNT = (math.radians(90.0), 0.0, 0.0)   # local +Z -> world -Y (aft), local +Y -> world +Z


def _mounted(col=None, **kw):
    col = col or kit.collection("DriftDrive")
    unit = build_drift_drive(col, **kw)
    wall = kit.to_obj("TransomWall", kit.box((2.7, 1.25, 0.3), center=(0, 0, -0.15), bevel=0.02), col,
                      [mats.get("paint_white")])
    for ob in (unit, wall):
        ob.rotation_euler = _MOUNT
    tris = sum(len(p.vertices) - 2 for p in unit.data.polygons)
    per = {}
    for p in unit.data.polygons:
        key = unit.data.materials[p.material_index].name
        per[key] = per.get(key, 0) + len(p.vertices) - 2
    print("DRIFTDRIVE faces", len(unit.data.polygons), "tris", tris, sorted(per.items(), key=lambda kv: -kv[1]))
    return unit, wall


def demo():
    unit, wall = _mounted()
    return [unit, wall]


def _zoom(center, size):
    ob = kit.to_obj("zoom_box", kit.box(size, center=center))
    ob.hide_render = True
    return [ob]


def demo_coil():
    """Close-up of the coil / dish (world coords: unit faces -Y)."""
    _mounted()
    return _zoom((0.0, -0.40, 0.0), (0.95, 0.35, 0.95))


def demo_clamp():
    _mounted()
    return _zoom((0.25, -0.33, 0.25), (0.30, 0.25, 0.30))


def demo_strip():
    """Close-up of the starboard cable run, junction box, capacitors and terminal box."""
    _mounted()
    return _zoom((0.50, -0.16, 0.0), (0.26, 0.30, 0.55))


def demo_side():
    """Close-up of the starboard radiator pack and outboard ports."""
    _mounted()
    return _zoom((0.80, -0.22, 0.0), (0.70, 0.40, 0.70))
