"""ST-7 Tern: panelized skins, paint scheme, fasteners, mounted parts, cockpit.

Design-space coordinates used for regions (always given for the STARBOARD side, mirrored by `side`):
    p_top / p_bot : (x, y)      world, looking down / up
    p_out         : (y, z)      world, looking at the ship's flank
    p_obl         : (y, v)      v = distance up the sloped surface from the frame origin
"""
import importlib
import math

import bmesh
import bpy
import numpy as np
from mathutils.bvhtree import BVHTree

import design as D
import kit
import mats
from kit import V, chamfer_rect2 as crect, rect2

# paint slots (mats.PAINTS)
WHITE, DARK, ORANGE, BARE, HAZARD, MATT, GREY, HEAT = range(8)


def ccw(pts):
    a = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    return list(pts) if a > 0 else list(reversed(pts))


class Proj:
    def __init__(self, mx, fn):
        self.mx = mx
        self.fn = fn

    def poly(self, pts):
        return ccw([self.fn(p) for p in pts])


def p_top(side=1):
    return Proj(kit.frame((0, 0, 0), (0, 0, 1), (1, 0, 0)), lambda p: (side * p[0], p[1]))


def p_bot(side=1):
    return Proj(kit.frame((0, 0, 0), (0, 0, -1), (1, 0, 0)), lambda p: (side * p[0], -p[1]))


def p_out(side=1):
    return Proj(kit.frame((0, 0, 0), (side, 0, 0), (0, 1, 0)), lambda p: (p[0], side * p[1]))


def p_obl(origin, normal, side=1):
    o = (side * origin[0], origin[1], origin[2])
    n = (side * normal[0], normal[1], normal[2])
    return Proj(kit.frame(o, n, (0, 1, 0)), lambda p: (p[0] - origin[1], side * p[1]))


UP_O, UP_N = (1.40, 0.0, 0.55), (0.74, 0.0, 0.67)      # fuselage upper flank
LO_O, LO_N = (1.68, 0.0, -0.65), (0.84, 0.0, -0.55)    # fuselage lower flank


# ------------------------------------------------------------------------------------------
class Body:
    """One smooth body -> panel skin + dark under-layer, with fastener rows and part mounts."""

    def __init__(self, name, bm, thickness=0.03, bevel=0.006, shrink=0.022, gap=0.016):
        self.name = name
        self.bm = bm
        self.under = bm.copy()
        self.bvh = BVHTree.FromBMesh(self.under)
        self.pz = kit.Panelizer(bm, gap=gap)
        self.upz = kit.Panelizer(self.under, gap=0.0)
        self.thickness, self.bevel, self.shrink = thickness, bevel, shrink
        self.fast = []
        self.mounts = []
        self.decals = []

    def reg(self, proj, pts, through=False, fasteners=0.0, **kw):
        poly = proj.poly(pts)
        r = self.pz.region(proj.mx, poly, **kw)
        if through:
            self.upz.region(proj.mx, poly, depth=kw.get("depth", (-1e6, 1e6)), facing=kw.get("facing", 0.15), remove=True)
        if fasteners:
            self.fast.append((proj.mx, poly, fasteners, kw.get("offset", 0.0)))
        return r

    def mount(self, proj, pt, part, rot=0.0, sink=0.0, **kw):
        self.mounts.append((proj, pt, part, rot, sink, kw))

    def hit(self, proj, pt):
        lx, ly = proj.fn(pt)
        zax = proj.mx.to_3x3() @ V((0, 0, 1))
        loc, nrm, _i, _d = self.bvh.ray_cast(proj.mx @ V((lx, ly, 60.0)), -zax)
        return loc, nrm

    def finish(self, col):
        self.pz.run()
        if self.upz.regions:
            self.upz.run()
        skin, under = kit.skin_objects(self.name, self.bm, col, [mats.get("hull_paint"), mats.get("glass_dark")],
                                       self.thickness, self.bevel, under=self.under, under_mat=mats.get("inner_dark"),
                                       under_shrink=self.shrink)
        tmp = kit.bm_from_obj(skin)
        self.skin_bvh = BVHTree.FromBMesh(tmp)
        tmp.free()
        return [skin, under]

    def decal(self, proj, pt, width, image, rot=0.0, color=(0.03, 0.032, 0.036), nx=None, ny=None):
        self.decals.append((proj, pt, width, image, rot, color, nx, ny))


# ------------------------------------------------------------------------------------------
# part library (modules written by the part agents; placeholders until they exist)
# ------------------------------------------------------------------------------------------
_CACHE = {}
_MISSING = set()


def _placeholder(col, name, kw):
    s = kw.get("size", kw.get("width", kw.get("radius", kw.get("length", 0.15))))
    bm = kit.box((s, s * 0.6, 0.03), center=(0, 0, 0.012), bevel=0.004)
    return kit.to_obj("ph_" + name, bm, col, [mats.get("metal_dark")])


def part(col, name, **kw):
    """Instance of a library part ('module.function' or a smallparts function name)."""
    key = (name, tuple(sorted(kw.items())))
    if key not in _CACHE:
        tcol = kit.collection("TernTemplates")
        tcol.hide_render = True
        tcol.hide_viewport = True
        mod, fn = name.split(".") if "." in name else ("smallparts", name)
        try:
            m = importlib.import_module(mod)
            ob = getattr(m, fn)(tcol, **kw)
        except Exception as e:  # noqa: BLE001
            if name not in _MISSING:
                print("PART MISSING %s: %s" % (name, str(e)[:120]))
                _MISSING.add(name)
            ob = _placeholder(tcol, name.replace(".", "_"), kw)
        _CACHE[key] = ob
    src = _CACHE[key]
    inst = src.copy()
    col.objects.link(inst)
    return inst


def surface_matrix(loc, nrm, rot=0.0, sink=0.0):
    n = V(nrm).normalized()
    xh = V((0, 1, 0)).cross(n)
    if xh.length < 1e-4:
        xh = V((1, 0, 0))
    return kit.frame(loc, n, xh) @ kit.R("Z", rot) @ kit.T(0, 0, -sink)


def place_mounts(col, bodies):
    out = []
    for b in bodies:
        for proj, pt, name, rot, sink, kw in b.mounts:
            loc, nrm = b.hit(proj, pt)
            if loc is None:
                print("MOUNT MISS", b.name, name, pt)
                continue
            ob = part(col, name, **kw)
            ob.matrix_world = surface_matrix(loc, nrm, rot, sink)
            out.append(ob)
    return out


def build_fasteners(col, bodies):
    tcol = kit.collection("TernTemplates")
    try:
        import smallparts
        tmpl = smallparts.fastener(tcol)
    except Exception:  # noqa: BLE001
        tmpl = kit.to_obj("fastener_ph", kit.cylinder(0.011, -0.003, 0.0016, 10, chamfer=0.0008), tcol,
                          [mats.get("metal_steel")])
    src = bmesh.new()
    src.from_mesh(tmpl.data)
    bm = bmesh.new()
    count = 0
    for b in bodies:
        for mx, poly, spacing, offset in b.fast:
            pts = kit.outline_points(poly, spacing, inset=0.045)
            for loc, nrm in kit.surface_points(b.bvh, mx, pts):
                m = surface_matrix(loc + nrm * offset, nrm, rot=(count * 37) % 360)
                vmap = {}
                for v in src.verts:
                    vmap[v] = bm.verts.new(m @ v.co)
                for f in src.faces:
                    bm.faces.new([vmap[v] for v in f.verts])
                count += 1
    src.free()
    mat = tmpl.data.materials[0] if tmpl.data.materials else mats.get("metal_steel")
    ob = kit.to_obj("Fasteners", bm, col, [mat], smooth=40.0, recalc=False)
    print("FASTENERS", count)
    return [ob]


# ------------------------------------------------------------------------------------------
# decals: small conforming quads with alpha-masked paint
# ------------------------------------------------------------------------------------------
import os  # noqa: E402

DECAL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "decals")
_ASPECT = {}
_DMAT = {}


def _aspect(image):
    if not _ASPECT:
        with open(os.path.join(DECAL_DIR, "aspect.txt")) as fh:
            for line in fh:
                k, v = line.split()
                _ASPECT[k] = float(v)
    return _ASPECT[image]


def decal_material(image, color):
    key = (image, tuple(color))
    if key in _DMAT:
        return _DMAT[key]
    m = bpy.data.materials.new("decal_%s_%d" % (image, len(_DMAT)))
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    b = mats.NB(nt)
    out = b.new("ShaderNodeOutputMaterial")
    tex = b.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(os.path.join(DECAL_DIR, image + ".png"), check_existing=True)
    tex.extension = "CLIP"
    tc = b.new("ShaderNodeTexCoord").outputs["Object"]
    chips = b.smooth(b.noise(tc, 38.0, 5.0, 0.65), 0.30, 0.42)            # paint flaked off in small spots
    fade = b.math("MULTIPLY_ADD", b.noise(tc, 3.0, 3.0, 0.5), 0.35, 0.68)  # uneven fading
    alpha = b.math("MULTIPLY", tex.outputs["Alpha"], b.math("MULTIPLY", chips, fade), clamp=True)
    p = b.new("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = tuple(color) + (1.0,)
    p.inputs["Roughness"].default_value = 0.46
    b.set(p.inputs["Alpha"], alpha)
    nt.links.new(p.outputs[0], out.inputs["Surface"])
    _DMAT[key] = m
    return m


def build_decals(col, bodies):
    objs = []
    for b in bodies:
        groups = {}
        for proj, pt, width, image, rot, color, nx, ny in b.decals:
            h = width / _aspect(image)
            nx = nx or max(4, int(width / 0.05))
            ny = ny or max(2, int(h / 0.05))
            cx, cy = proj.fn(pt)
            ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))
            zax = proj.mx.to_3x3() @ V((0, 0, 1))
            bm = groups.setdefault((image, tuple(color)), bmesh.new())
            uv = bm.loops.layers.uv.verify()
            grid = {}
            for j in range(ny + 1):
                for i in range(nx + 1):
                    a, c = (i / nx - 0.5) * width, (j / ny - 0.5) * h
                    o = proj.mx @ V((cx + a * ca - c * sa, cy + a * sa + c * ca, 60.0))
                    loc, nrm, _i, _d = b.bvh.ray_cast(o, -zax)
                    if loc is None:
                        continue
                    lift = 0.0
                    loc2, _n2, _i2, _d2 = b.skin_bvh.ray_cast(o, -zax)
                    if loc2 is not None:
                        lift = max(0.0, (loc2 - loc).dot(nrm))
                    grid[(i, j)] = (bm.verts.new(loc + nrm * (lift + 0.0022)), (i / nx, j / ny))
            for j in range(ny):
                for i in range(nx):
                    q = [grid.get(k) for k in ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1))]
                    if None in q:
                        continue
                    f = bm.faces.new([v for v, _ in q])
                    for loop, (_, t) in zip(f.loops, q):
                        loop[uv].uv = t
        for (image, color), bm in groups.items():
            ob = kit.to_obj("decal_%s_%s" % (b.name, image), bm, col, [decal_material(image, color)], smooth=60.0,
                            recalc=False)
            ob.visible_shadow = False
            objs.append(ob)
    return objs


# ------------------------------------------------------------------------------------------
# fuselage
# ------------------------------------------------------------------------------------------
def setup_fuselage(b):
    bm = b.bm
    li = bm.faces.layers.int["li"]
    lj = bm.faces.layers.int["lj"]
    zone = {0: 0, 11: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 4, 7: 5, 8: 5, 9: 6, 10: 6}
    zpaint = {0: WHITE, 1: WHITE, 6: WHITE, 2: GREY, 5: GREY, 3: DARK, 4: DARK}

    def base(f):
        i, j = f[li], f[lj]
        if i == -1:
            return (1, DARK)                       # nose cap belongs to the radome
        if i < 0:
            return (902, DARK)
        z = zone[j]
        if i == 0:
            return (1, DARK)                       # radome tip: one piece
        if i >= 10:
            return (1000 + (i - 10) * 10 + z, DARK if z in (3, 4) else HEAT)   # tail cone ring
        return (i * 10 + z, zpaint[z])

    b.pz.base_face = base
    b.upz.base_face = lambda f: (0, 0)

    for side in (1, -1):
        up = p_obl(UP_O, UP_N, side)
        # livery: a slanted signal-orange band + pinstripe behind the cockpit (painted, no seams)
        b.reg(up, [(0.10, -1.0), (0.80, -1.0), (0.20, 1.475), (-0.50, 1.475)], facing=0.45, paint=ORANGE, seam=False)
        b.reg(up, [(-0.17, -1.0), (-0.04, -1.0), (-0.64, 1.475), (-0.77, 1.475)], facing=0.45, paint=ORANGE, seam=False)
    top = p_top()
    b.reg(top, [(-0.24, 7.28), (0.24, 7.28), (0.44, 6.30), (-0.44, 6.30)], paint=MATT, seam=False)   # anti-glare

    # canopy: frame ring, glazing, bows
    flank = p_out(1)
    ring = b.reg(flank, kit.offset_convex2(ccw(D.CANOPY), 0.10), facing=-2, paint=DARK, offset=0.007, gap=0.012,
                 name="canopy_frame")
    b.reg(flank, D.CANOPY, facing=-2, mat=1, paint=WHITE, offset=-0.004, gap=0.010, through=True, name="glass")
    for q in ([(4.70, 0.2), (4.80, 0.2), (4.40, 1.75), (4.30, 1.75)], [(3.22, 0.2), (3.31, 0.2), (3.21, 1.75), (3.12, 1.75)]):
        b.reg(flank, q, facing=-2, paint=DARK, offset=0.007, gap=0.012, join=ring, name="bow")
    b.reg(top, rect2(0.085, 1.80, 0.0, 2.36), paint=DARK, offset=0.007, gap=0.012, join=ring, name="roof_frame")

    # dorsal deck
    b.reg(top, crect(0.84, 0.98, 0.14, 0.0, 0.80), offset=0.008, gap=0.014, name="dorsal_hatch")
    b.mount(top, (0.25, 1.29), "hinge")
    b.mount(top, (-0.25, 1.29), "hinge")
    for sx in (1, -1):
        b.mount(top, (sx * 0.52, 7.00), "pitot")
    b.mount(top, (0.0, 0.50), "handle", rot=90)
    b.mount(top, (0.0, 1.50), "sensor_dome", radius=0.10)
    b.reg(top, crect(1.30, 1.10, 0.10, 0.0, -1.55), offset=0.006, fasteners=0.14, name="spine_a")
    for sx in (1, -1):
        b.reg(top, rect2(0.24, 0.78, sx * 0.34, -2.95), remove=True, gap=0.0, name="vent")
        b.mount(top, (sx * 0.34, -2.95), "vent", rot=90, width=0.80, height=0.26, slats=7)
    b.mount(top, (0.0, -3.72), "antenna_blade")
    b.reg(top, crect(1.20, 1.00, 0.10, 0.0, -4.45), offset=0.006, fasteners=0.14, name="spine_b")
    b.mount(top, (0.0, -5.30), "strobe", color="red")
    b.mount(top, (0.42, -5.75), "antenna_whip")

    for side in (1, -1):
        up = p_obl(UP_O, UP_N, side)
        lo = p_obl(LO_O, LO_N, side)
        # under the canopy sill
        b.reg(up, crect(0.80, 0.36, 0.06, 4.05, -0.52), facing=0.45, offset=0.005, gap=0.010, fasteners=0.12)
        b.reg(up, crect(0.60, 0.36, 0.06, 3.02, -0.52), facing=0.45, offset=0.005, gap=0.010, fasteners=0.12)
        b.reg(up, rect2(0.38, 0.12, 5.00, -0.60), facing=0.45, remove=True, gap=0.0)
        b.mount(up, (5.00, -0.60), "vent", rot=90, width=0.42, height=0.16, slats=4)
        if side < 0:   # port: crew door
            b.reg(up, crect(1.00, 1.50, 0.16, -1.25, -0.03), facing=0.45, gap=0.020, offset=-0.003, name="crew_door")
            b.mount(up, (-0.72, 0.42), "hinge", length=0.16)
            b.mount(up, (-0.72, -0.48), "hinge", length=0.16)
            b.mount(up, (-1.62, -0.05), "handle", rot=90)
            b.mount(lo, (-1.25, 0.30), "step", rot=-90)
        else:          # starboard: equipment bay
            b.reg(up, crect(1.30, 0.84, 0.10, -1.30, -0.12), facing=0.45, offset=0.006, fasteners=0.14, name="equip_bay")
            for k in (-0.4, 0.0, 0.4):
                b.mount(up, (-1.30 + k, -0.47), "latch")
        b.reg(up, crect(0.90, 0.60, 0.08, -3.20, 0.05), facing=0.45, offset=0.005, gap=0.012, fasteners=0.14)
        b.reg(up, rect2(0.56, 0.16, -4.60, 0.30), facing=0.45, remove=True, gap=0.0)
        b.mount(up, (-4.60, 0.30), "vent", rot=90, width=0.60, height=0.20, slats=5)
        b.reg(up, crect(0.36, 0.36, 0.06, -5.25, -0.32), facing=0.45, offset=0.004, gap=0.010, fasteners=0.11)
        # lower flank
        b.reg(lo, crect(0.37, 0.37, 0.07, 5.55, -0.30), facing=0.45, remove=True, gap=0.0)
        b.mount(lo, (5.55, -0.30), "rcs_quad", size=0.42)
        b.reg(lo, crect(1.70, 0.62, 0.10, 1.90, -0.03), facing=0.45, offset=0.006, fasteners=0.15, name="lower_door")
        b.reg(lo, crect(0.80, 0.50, 0.07, -0.60, -0.03), facing=0.45, offset=0.005, gap=0.012, fasteners=0.13)
        b.mount(lo, (-2.30, 0.10), "fuel_port")
        b.reg(lo, rect2(0.66, 0.16, -3.50, 0.05), facing=0.45, remove=True, gap=0.0)
        b.mount(lo, (-3.50, 0.05), "vent", rot=90, width=0.70, height=0.20, slats=5)
        b.reg(lo, crect(0.37, 0.37, 0.07, -5.50, -0.02), facing=0.45, remove=True, gap=0.0)
        b.mount(lo, (-5.50, -0.02), "rcs_quad", size=0.42)

    INK, RED = (0.03, 0.032, 0.036), (0.55, 0.07, 0.02)
    for side in (1, -1):
        up = p_obl(UP_O, UP_N, side)
        lo = p_obl(LO_O, LO_N, side)
        r = 0.0 if side > 0 else 180.0
        b.decal(up, (1.52, -0.22), 1.25, "txt_st7", r, INK)
        b.decal(up, (5.82, -0.42), 0.60, "txt_tern", r, INK)
        b.decal(up, (3.55, -0.215), 0.50, "lbl_rescue", r, RED)
        b.decal(up, (-4.55, -0.30), 0.80, "txt_reg", r, INK)
        b.decal(up, (-3.20, 0.10), 0.34, "lbl_spec", r, INK)
        b.decal(up, (-2.45, 0.62), 0.42, "lbl_lift", r, INK)
        b.decal(lo, (1.55, 0.02), 0.34, "lbl_spec2", r, INK)
        b.decal(lo, (4.92, -0.30), 0.52, "lbl_caution", r, RED)
        b.decal(lo, (-4.88, -0.02), 0.52, "lbl_caution", r, RED)
        b.decal(lo, (-2.30, -0.20), 0.30, "lbl_fuel", r, INK)
        b.decal(lo, (3.45, -0.42), 0.30, "lbl_jack", r, INK)
        if side > 0:
            b.decal(up, (-1.30, 0.02), 0.36, "lbl_spec", r, INK)
        else:
            b.decal(up, (-1.25, 0.45), 0.52, "lbl_exit", r, RED)
    b.decal(top, (0.0, -1.55), 0.36, "lbl_spec2", 0.0, INK)
    b.decal(top, (0.0, -4.45), 0.60, "emblem", 0.0, INK)

    # belly
    bot = p_bot()
    gx, gy = D.GEAR_NOSE
    b.reg(bot, rect2(0.62, 1.50, gx, gy), through=True, remove=True, gap=0.0, name="nose_gear_bay")
    b.mount(bot, (0.0, 6.30), "chin.build_sensor_turret")
    for (vx, vy) in ((0.78, 2.55), (0.86, -0.90)):
        for sx in (1, -1):
            b.reg(bot, kit.ngon2(20, 0.205, 9.0, sx * vx, -vy), through=True, remove=True, gap=0.0, name="vtol")
            b.mount(bot, (sx * vx, vy), "nozzle.build_vtol_nozzle", radius=0.22)
    b.reg(bot, crect(1.80, 3.10, 0.22, 0.0, -3.95), gap=0.024, offset=-0.004, name="cargo_ramp")
    b.reg(bot, rect2(1.30, 0.10, 0.0, -2.62), paint=HAZARD, seam=False)
    b.reg(bot, rect2(1.30, 0.10, 0.0, -5.28), paint=HAZARD, seam=False)
    for sx in (1, -1):
        b.mount(bot, (sx * 0.42, 5.60), "landing_light")


# ------------------------------------------------------------------------------------------
# engine pods
# ------------------------------------------------------------------------------------------
def setup_pod(b, side):
    bm = b.bm
    li = bm.faces.layers.int["li"]
    for m in (b.bm, b.under):
        l2 = m.faces.layers.int["li"]
        bmesh.ops.delete(m, geom=[f for f in m.faces if f[l2] == -2], context="FACES")
    ax = V((side * D.NAC_X, 0.0, D.NAC_Z))
    for a in (0.0, 60.0, 120.0):
        ar = math.radians(a)
        b.pz.plane(ax, (-side * math.sin(ar), 0.0, math.cos(ar)), where=lambda C, N: C[:, 1] < 0.2)
    b.pz.plane((0, -2.45, 0), (0, 1, 0), where=lambda C, N: C[:, 1] < 0.2)

    def base(f):
        i = f[li]
        if i in (0, 1, 2, -1):
            return (0, MATT)
        if i in (3, 4, 5):
            return (1, BARE)
        if i == -2:
            return (2, DARK)
        c = f.calc_center_median()
        ang = math.degrees(math.atan2(c.z - D.NAC_Z, (c.x - ax.x) * side)) % 360.0
        sector = int(ang // 60.0)
        band = {6: 2, 7: 3, 8: 5, 9: 6}[i]
        if i == 7 and c.y < -2.45:
            band = 4
        paint = HEAT if band == 6 else (GREY if sector == 4 else WHITE)
        return (band * 10 + sector, paint)

    b.pz.base_face = base
    flank = p_out(side)
    b.reg(flank, rect2(0.34, 4.0, -0.86, D.NAC_Z), facing=-2, paint=ORANGE, seam=False)
    b.reg(flank, rect2(0.09, 4.0, -1.17, D.NAC_Z), facing=-2, paint=ORANGE, seam=False)
    b.reg(flank, crect(2.00, 0.90, 0.12, -3.05, D.NAC_Z), facing=0.3, offset=0.007, fasteners=0.15, name="cowl_door")
    for k in (-0.6, 0.0, 0.6):
        b.mount(flank, (-3.05 + k, D.NAC_Z - 0.36), "latch")
    r = 0.0 if side > 0 else 180.0
    b.decal(flank, (-1.63, D.NAC_Z + 0.02), 0.52, "txt_07", r)
    b.decal(flank, (-3.05, D.NAC_Z + 0.10), 0.34, "lbl_spec", r)
    b.decal(flank, (-4.75, D.NAC_Z + 0.25), 0.55, "lbl_caution", r, (0.55, 0.07, 0.02))
    top = p_top(side)
    b.reg(top, crect(0.42, 0.80, 0.07, D.NAC_X - 0.34, -2.75), facing=0.5, offset=0.005, gap=0.011, fasteners=0.12)
    b.reg(top, rect2(0.20, 0.66, D.NAC_X - 0.36, -4.30), facing=0.5, remove=True, gap=0.0)
    b.mount(top, (D.NAC_X - 0.36, -4.30), "vent", rot=90, width=0.70, height=0.24, slats=6)
    b.mount(top, (D.NAC_X - 0.32, -1.80), "fuel_port", radius=0.085)
    bot = p_bot(side)
    gx, gy = D.GEAR_MAIN
    b.reg(bot, rect2(0.66, 1.60, gx, gy), through=True, remove=True, gap=0.0, facing=0.5, name="main_gear_bay")


def setup_wing(b, side):
    bm = b.bm
    lj = bm.faces.layers.int["lj"]
    li = bm.faces.layers.int["li"]
    for x in (5.07, 6.08):
        b.pz.plane((side * x, 0, 0), (1, 0, 0))
    edges = [2.6, 3.55, 4.53, 5.07, 5.6, 6.08]

    def base(f):
        if f[li] < 0:
            return (9, DARK)
        j = f[lj]
        x = abs(f.calc_center_median().x)
        band = sum(1 for e in edges if x > e)
        big = 0 if x < 4.53 else (1 if x < 5.6 else 2)
        if j in (0, 8):
            return (1000 + big, BARE)
        if j in (3, 4, 5):
            return (2000 + big, WHITE)
        if j in (1, 2):
            return (3000 + band * 10 + j, WHITE)
        return (4000 + band * 10 + j, GREY)

    b.pz.base_face = base
    top = p_top(side)
    bot = p_bot(side)
    b.reg(top, rect2(0.30, 6.0, 6.17, -3.0), facing=-2, paint=ORANGE, seam=False)
    b.reg(top, rect2(0.07, 6.0, 5.90, -3.0), facing=-2, paint=ORANGE, seam=False)
    b.reg(top, crect(0.46, 0.62, 0.07, 5.02, -2.98), facing=0.5, offset=0.004, gap=0.009, fasteners=0.11)
    b.mount(top, (4.88, -1.80), "fuel_port", radius=0.08)
    b.mount(top, (5.86, -3.45), "light_strip", rot=75, length=0.46)
    for wx, wy in ((4.90, -4.61), (5.60, -4.35), (6.25, -4.11)):
        b.mount(top, (wx, wy), "static_wick")
    b.reg(bot, crect(0.50, 0.70, 0.07, 5.05, -2.60), facing=0.5, offset=0.004, gap=0.009, fasteners=0.11)
    b.mount(bot, (5.20, -3.25), "hardpoint", rot=180)
    b.decal(top, (5.02, -4.22), 0.46, "lbl_nostep", 0.0)
    b.decal(top, (5.55, -2.70), 0.50, "txt_07", 0.0)
    b.decal(top, (5.02, -2.98), 0.26, "lbl_spec2", 0.0)


def setup_fin(b, side):
    bm = b.bm
    lj = bm.faces.layers.int["lj"]
    li = bm.faces.layers.int["li"]

    def base(f):
        i, j = f[li], f[lj]
        if i < 0:
            return (9, DARK)
        if j in (0, 8):
            return (10 + i, DARK)
        if j in (3, 4, 5):
            return (20 + i, WHITE)
        return (30 + i * 4 + (0 if j in (1, 2) else 1), WHITE)

    b.pz.base_face = base
    flank = p_out(side)
    ztip = D.FIN_ROOT[1] + D.FIN[-1][0] * math.cos(math.radians(D.FIN_CANT))
    b.reg(flank, rect2(6.0, 0.28, -5.0, ztip - 0.36), facing=-2, paint=ORANGE, seam=False)
    b.reg(flank, rect2(6.0, 0.06, -5.0, ztip - 0.62), facing=-2, paint=ORANGE, seam=False)
    b.decal(flank, (-5.05, ztip - 1.05), 0.56, "emblem", 0.0 if side > 0 else 180.0)
    b.decal(p_out(-side), (-5.05, ztip - 1.05), 0.56, "emblem", 180.0 if side > 0 else 0.0)


def setup_tip(b, side):
    li = b.bm.faces.layers.int["li"]
    b.pz.base_face = lambda f: (f[li] + 5, DARK if f[li] in (0, 1, 4, -1, -2) else WHITE)
    flank = p_out(side)
    b.mount(flank, (-2.85, D.POD_Z), "nav_light", color="green" if side > 0 else "red")
    b.mount(p_top(side), (D.POD_X, -3.95), "rcs_single")
    b.mount(p_bot(side), (D.POD_X, -3.95), "rcs_single")
    b.mount(flank, (-3.95, D.POD_Z), "rcs_single")


def setup_cheek(b, side):
    li = b.bm.faces.layers.int["li"]
    b.pz.base_face = lambda f: (f[li] + 5, DARK if f[li] < 0 else GREY)


def place_fixed(col, name, matrix, **kw):
    ob = part(col, name, **kw)
    ob.matrix_world = matrix
    return ob


def setup_spike(b, side):
    li = b.bm.faces.layers.int["li"]
    b.pz.base_face = lambda f: (f[li] + 5, DARK if f[li] in (0, -1) else BARE)


# ------------------------------------------------------------------------------------------
# cockpit (only a dark suggestion of an interior behind the tinted glass)
# ------------------------------------------------------------------------------------------
def cockpit(col, fus):
    objs = []
    rings = []
    floor = -0.52
    y = 1.62
    while y < 6.05:
        sill = 0.31 + (6.22 - y) * 0.0638 - 0.05
        half = []
        for z in (sill, sill - 0.22, (sill + floor) * 0.5, floor + 0.12):
            loc, _n, _i, _d = fus.bvh.ray_cast(V((0.0, y, z)), V((1.0, 0.0, 0.0)))
            x = (loc.x if loc is not None else 0.4) - 0.09
            half.append((max(x, 0.08), z))
        half.append((max(half[-1][0] - 0.16, 0.05), floor))
        rings.append([V((-x, y, z)) for x, z in half] + [V((x, y, z)) for x, z in reversed(half)])
        y += 0.42
    bm, _ = kit.loft(rings, cap_start=True, cap_end=True, closed=False)
    objs.append(kit.to_obj("cockpit_tub", bm, col, [mats.get("plastic_black")], recalc=False))
    seat = bmesh.new()
    for sx in (-0.52, 0.52):
        kit.box((0.52, 0.16, 0.95), bevel=0.04, bm=seat, mx=kit.T(sx, 3.15, 0.20) @ kit.R("X", -12))
        kit.box((0.30, 0.14, 0.26), center=(sx, 3.05, 0.80), bevel=0.04, bm=seat)
        kit.box((0.54, 0.55, 0.14), center=(sx, 3.50, -0.26), bevel=0.04, bm=seat)
    kit.box((1.30, 0.50, 0.36), bevel=0.05, bm=seat, mx=kit.T(0, 4.80, -0.04) @ kit.R("X", 20))
    kit.box((0.34, 1.7, 0.36), center=(0, 3.9, -0.30), bevel=0.04, bm=seat)
    objs.append(kit.to_obj("cockpit_seats", seat, col, [mats.get("plastic_black")]))
    scr = bmesh.new()
    for sx, w in ((-0.42, 0.34), (0.0, 0.40), (0.42, 0.34)):
        kit.box((w, 0.012, 0.17), bm=scr, mx=kit.T(sx, 4.585, 0.09) @ kit.R("X", 20))
    objs.append(kit.to_obj("cockpit_screens", scr, col, [mats.emissive("emit_screen", (0.20, 0.75, 1.0), 2.2)]))
    return objs


def _aft(x, y, z):
    """Matrix for a part whose local +Z must point aft (ship -Y), local +Y up, local +X starboard."""
    from mathutils import Matrix
    return Matrix(((1, 0, 0, x), (0, 0, -1, y), (0, 1, 0, z), (0, 0, 0, 1)))


def hardware(col, fus, bodies, opt):
    """Engines, drift drive and landing gear."""
    objs = []
    for side in (1, -1):
        objs.append(place_fixed(col, "nozzle.build_nozzle", _aft(side * D.NAC_X, D.NAC_END_Y, D.NAC_Z),
                                radius=D.NOZZLE_R, length=1.35, glow=float(opt.get("glow", 1.8))))
    objs.append(place_fixed(col, "driftdrive.build_drift_drive", _aft(0.0, D.TAIL_Y, 0.05),
                            width=1.95, height=0.80, depth=0.62))
    if "nogear" in opt:
        return objs
    bot = p_bot()
    # nose gear: bay pitched to follow the belly
    gx, gy = D.GEAR_NOSE
    zf = fus.hit(bot, (0.0, gy + 0.70))[0].z
    zr = fus.hit(bot, (0.0, gy - 0.70))[0].z
    pitch = math.degrees(math.atan2(zf - zr, 1.40))
    zs = (zf + zr) * 0.5
    depth = 0.45
    base = kit.T(gx, gy, zs) @ kit.R("X", pitch)
    objs.append(place_fixed(col, "gear.build_bay", base @ kit.T(0, 0, depth), length=1.50, width=0.62, depth=depth))
    for sx in (1, -1):
        objs.append(place_fixed(col, "gear.build_door", base @ kit.T(sx * 0.31, 0, 0), length=1.46, width=0.33, side=sx))
    za = zs + depth - 0.02
    beef = kit.S(1.25, 1.25, 1.0)   # sturdier legs: widen the whole leg, keep its height
    objs.append(place_fixed(col, "gear.build_gear", kit.T(gx, gy, za) @ beef, height=round(za - D.GROUND_Z, 4),
                            bay_depth=depth, kind="nose"))
    # main gear under the engine pods
    mx_, my = D.GEAR_MAIN
    for side in (1, -1):
        pod = bodies["pod_R" if side > 0 else "pod_L"]
        ze = pod.hit(p_bot(side), (mx_ + 0.33, my))[0].z       # skin height at the edge of the opening
        depth = 0.40
        za = ze + depth
        objs.append(place_fixed(col, "gear.build_bay", kit.T(side * mx_, my, za), length=1.60, width=0.66, depth=depth))
        for sx in (1, -1):
            objs.append(place_fixed(col, "gear.build_door", kit.T(side * mx_ + sx * 0.33, my, ze), length=1.56,
                                    width=0.34, side=sx))
        objs.append(place_fixed(col, "gear.build_gear", kit.T(side * mx_, my, za - 0.02) @ beef,
                                height=round(za - 0.02 - D.GROUND_Z, 4), bay_depth=depth, kind="main"))
    return objs


# ------------------------------------------------------------------------------------------
def build(col, opt=None):
    opt = opt or {}
    raw = D.bodies(3)
    bodies = []
    fus = Body("fuselage", raw["fuselage"])
    setup_fuselage(fus)
    bodies.append(fus)
    for side, tag in ((1, "R"), (-1, "L")):
        pod = Body("pod_" + tag, raw["nacelle_" + tag])
        setup_pod(pod, side)
        wing = Body("wing_" + tag, raw["wing_" + tag], thickness=0.014, bevel=0.004, shrink=0.012, gap=0.012)
        setup_wing(wing, side)
        fin = Body("fin_" + tag, raw["fin_" + tag], thickness=0.012, bevel=0.0035, shrink=0.010, gap=0.011)
        setup_fin(fin, side)
        tip = Body("tip_" + tag, raw["pod_" + tag], thickness=0.012, bevel=0.0035, shrink=0.010, gap=0.011)
        setup_tip(tip, side)
        spk = Body("spike_" + tag, raw["spike_" + tag], thickness=0.012, bevel=0.0035, shrink=0.010, gap=0.010)
        setup_spike(spk, side)
        chk = Body("cheek_" + tag, raw["cheek_" + tag], thickness=0.012, bevel=0.0035, shrink=0.010, gap=0.010)
        setup_cheek(chk, side)
        bodies += [pod, wing, fin, tip, spk, chk]
    objs = []
    for b in bodies:
        objs += b.finish(col)
        print("SKIN %-12s faces=%d fixed=%d" % (b.name, len(objs[-2].data.polygons), b.pz.fixed))
    objs += build_fasteners(col, bodies)
    objs += build_decals(col, bodies)
    if "nomounts" not in opt:
        objs += place_mounts(col, bodies)
        from mathutils import Matrix
        objs += hardware(col, fus, {b.name: b for b in bodies}, opt)
        for side in (1, -1):
            # cannon: local +Z -> ship +Y (muzzle forward), local +Y -> ship +Z
            m = Matrix(((-1, 0, 0, side * D.CHEEK_X), (0, 0, 1, D.CANNON_Y), (0, 1, 0, D.CHEEK_Z), (0, 0, 0, 1)))
            objs.append(place_fixed(col, "chin.build_cannon", m, length=2.2))
    objs += cockpit(col, fus)
    return objs
