"""Stellar Drift player ship v2 "SD-9 Halcyon" -- fully procedural hard-surface model.

Run:
    blender -b -P tools/blender/ship.py -- assets/models/ship.glb [--blend out.blend] [--shapes out.txt]

Design (see docs/reports/wave4_ship_v2.md): a broad faceted lifting-body wedge with a sharp chine blade,
a flat upper deck, a dorsal systems spine flowing out of a single seamless bubble canopy, two engine pods
blended into the aft hull shoulders, short forward-swept anhedral wings with tip modules, canted radiator
panels on the pods, a sensor mast, a belly cargo keel with the boarding ramp, and three telescoping lander
legs whose bays are closed by sliding doors (nothing hangs off the hull in flight or on the ground).

Axis convention
---------------
Blender (build space):  +X = right (starboard), +Y = forward (nose), +Z = up.
glTF / Godot (export):  +X = right, +Y = up, -Z = forward.  (glTF exporter "+Y up": (x, y, z)_b -> (x, z, -y)_g)

Origin = rough centre of mass on the hull axis. Gear pad contact plane (gear deployed): Z = GROUND_Z
(Godot Y = GROUND_Z = -2.95, marker GroundPoint).

Markers (empties): local Godot -Z ("forward") points along the thing they emit:
  EngineExhaust_*  -Z = plume direction (ship backward, Godot +Z)
  Thruster_*       -Z = RCS jet direction (outwards from the hull)
  Flood_*, DeckLight_*   -Z = light direction (SpotLight3D convention)
  NavLight_*, PilotSeat, PilotEye, ExitPoint, GroundPoint, CockpitLight: identity (ship orientation)
  CameraChase      a Camera3D-style transform (looks along its -Z, toward the ship)

Animated parts (separate objects, rest pose = gear DOWN, doors/hatch/canopy CLOSED); glTF extras:
  GearFront / GearRearL / GearRearR   lowest leg stage + pad; "travel" = metres it rises when stowed
  Gear*_S1.._Sn                         intermediate telescoping stages, "travel" each
  BayDoor_*                             sliding bay doors, "slide" = [x, y, z] Godot offset when open,
                                        "lift" = metres it first moves up (into the hull)
  Hatch   open = rotate local X by "open_deg" (negative: front edge drops to the ground)
  Canopy  open = rotate local X by "open_deg" (front lifts)
"""
import bpy
import bmesh
import math
import random
import sys
from bisect import bisect_right
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

# ----------------------------------------------------------------------------------------------
# Parameters (meters)
# ----------------------------------------------------------------------------------------------
NOSE_Y = 10.2
TAIL_Y = -8.2
GROUND_Z = -2.95

# hull stations and profiles (half width at the chine, chine height, deck height above chine,
# deck half width, belly depth below chine, belly half width)
# arrowhead planform: the chine runs dead straight from the nose to the shoulder at y = -2.5
HS = [-8.2, -7.0, -4.0, -2.5, 0.0, 2.5, 5.0, 7.5, 8.8, 9.6, 10.0, 10.2]
HW_V = [3.42, 3.52, 3.56, 3.56, 2.95, 2.34, 1.73, 1.12, 0.80, 0.61, 0.48, 0.30]
ZC_V = [0.12, 0.10, 0.06, 0.04, 0.0, -0.04, -0.10, -0.17, -0.21, -0.25, -0.28, -0.30]
HT_V = [1.36, 1.48, 1.52, 1.52, 1.47, 1.36, 1.12, 0.82, 0.62, 0.47, 0.36, 0.20]
DW_V = [2.00, 2.08, 2.10, 2.08, 1.88, 1.58, 1.16, 0.72, 0.48, 0.32, 0.22, 0.10]
HB_V = [0.96, 1.06, 1.12, 1.14, 1.14, 1.10, 0.96, 0.76, 0.60, 0.46, 0.35, 0.18]
BW_V = [2.20, 2.32, 2.40, 2.40, 2.25, 1.95, 1.45, 0.92, 0.62, 0.45, 0.33, 0.16]
CHINE_LIP = 0.07

# engine pods
POD_X = 3.90
POD_Z = 0.24
POD_FRONT_Y = -0.2
POD_REAR_Y = -8.3
NOZZLE_LEN = 1.35

# radiator wings: canted up from the pods' outer shoulders (heat radiators + lifting surfaces)
RAD_ROOT = (4.42, 0.98)       # root line (x, z) on the pod's upper chamfer
RAD_DIHEDRAL = 30.0           # degrees above horizontal
RAD_SPAN = 3.0
RAD_ROOT_LE, RAD_ROOT_TE = -2.5, -7.95
RAD_TIP_LE, RAD_TIP_TE = -4.3, -7.8
RAD_TH_ROOT, RAD_TH_TIP = 0.26, 0.11

# canopy / cockpit
CANOPY_Y0, CANOPY_Y1 = 2.40, 7.80
CANOPY_OPEN_DEG = 30.0
COCKPIT_FLOOR = 0.22
SEAT_Y = 4.05

# belly keel and ramp
KEEL_Z = -1.30
KEEL_Y0, KEEL_Y1 = -4.7, 3.95
HATCH_Y0, HATCH_Y1 = 0.35, 3.55
HATCH_HALF_W = 0.72

# landing gear (telescoping)
GEAR_FRONT_Y = 6.35
GEAR_REAR_Y = -5.0

BEVEL_W = 0.022
SEED = 7

MATS = ["Hull", "HullDark", "Trim", "Glass", "Emissive", "EngineInner", "Display", "Lamp"]
HULL, DARK, TRIM, GLASS, EMIT, ENGINE, DISPLAY, LAMP = range(8)
MAT_PREVIEW = {  # base colours for non-Godot viewers (Godot overrides these)
    "Hull": ((0.80, 0.80, 0.78, 1), 0.1, 0.4),
    "HullDark": ((0.10, 0.105, 0.11, 1), 0.4, 0.5),
    "Trim": ((0.55, 0.55, 0.57, 1), 1.0, 0.3),
    "Glass": ((0.03, 0.035, 0.04, 1), 0.0, 0.05),
    "Emissive": ((0.3, 0.8, 1.0, 1), 0.0, 0.5),
    "EngineInner": ((1.0, 0.6, 0.3, 1), 0.0, 0.5),
    "Display": ((0.2, 0.6, 0.9, 1), 0.0, 0.3),
    "Lamp": ((1.0, 0.95, 0.85, 1), 0.0, 0.2),
}


# ----------------------------------------------------------------------------------------------
# Math helpers
# ----------------------------------------------------------------------------------------------
def pchip(keys):
    """Monotone cubic interpolation over [(x, y), ...] (x ascending)."""
    xs = [k[0] for k in keys]
    ys = [k[1] for k in keys]
    n = len(xs)
    d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            h0, h1 = xs[i] - xs[i - 1], xs[i + 1] - xs[i]
            w1, w2 = 2 * h1 + h0, h1 + 2 * h0
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])

    def f(x):
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]
        i = bisect_right(xs, x) - 1
        h = xs[i + 1] - xs[i]
        t = (x - xs[i]) / h
        t2, t3 = t * t, t * t * t
        return ((2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1])
    return f


def lerp(a, b, t):
    return a + (b - a) * t


def smooth(t):
    t = min(max(t, 0.0), 1.0)
    return t * t * (3 - 2 * t)


def rot_x(deg):
    return Matrix.Rotation(math.radians(deg), 4, 'X')


def rot_y(deg):
    return Matrix.Rotation(math.radians(deg), 4, 'Y')


def spow(v, e):
    return math.copysign(abs(v) ** e, v)


def bez(p0, p1, p2, t):
    a = (1 - t) * (1 - t)
    b = 2 * (1 - t) * t
    c = t * t
    return (a * p0[0] + b * p1[0] + c * p2[0], a * p0[1] + b * p1[1] + c * p2[1])


def prof(vals):
    return pchip(list(zip(HS, vals)))


HW, ZC, HT, DW, HB, BW = (prof(v) for v in (HW_V, ZC_V, HT_V, DW_V, HB_V, BW_V))

# pod profiles: half width / half height / centre x
PA = pchip([(POD_REAR_Y, 0.96), (-7.6, 1.0), (-2.0, 1.0), (-0.9, 0.93), (POD_FRONT_Y, 0.80)])
PB = pchip([(POD_REAR_Y, 1.06), (-7.6, 1.12), (-2.0, 1.12), (-0.9, 1.04), (POD_FRONT_Y, 0.88)])
PCX = pchip([(POD_REAR_Y, POD_X), (-2.0, POD_X), (POD_FRONT_Y, POD_X - 0.16)])
PCZ = pchip([(POD_REAR_Y, POD_Z), (-2.0, POD_Z), (POD_FRONT_Y, POD_Z - 0.06)])
POD_PROW = 0.95   # slant of the armoured prow face: top edge this far ahead of the bottom edge (m)
POD_NT, POD_NB = 4.2, 5.5   # superellipse exponents: boxy top, flat bottom

# canopy
CW = pchip([(CANOPY_Y0, 0.80), (3.4, 0.90), (4.5, 0.94), (5.7, 0.86), (6.7, 0.64), (7.35, 0.38), (CANOPY_Y1, 0.05)])
CT = pchip([(CANOPY_Y0, 1.97), (3.4, 2.12), (4.4, 2.16), (5.6, 2.03), (6.6, 1.68), (7.3, 1.24), (CANOPY_Y1, 0.66)])
# dorsal spine: height above the deck centre, top half width
SPH = pchip([(-7.75, -0.05), (-6.7, 0.30), (-5.2, 0.55), (0.5, 0.58), (CANOPY_Y0, 0.59)])
SPW = pchip([(-7.75, 0.55), (-6.0, 0.80), (0.5, 0.84), (CANOPY_Y0, 0.80)])


# ----------------------------------------------------------------------------------------------
# Section geometry
# ----------------------------------------------------------------------------------------------
_HALF_CACHE = {}


def hull_half(y):
    """Right half of the hull section at y: [(x, z)] from belly centre to deck centre.
    Index CHINE_I is the chine blade tip."""
    key = round(y, 5)
    if key in _HALF_CACHE:
        return _HALF_CACHE[key]
    hw, zc, ht, dw, hb, bw = HW(y), ZC(y), HT(y), DW(y), HB(y), BW(y)
    zb, zt = zc - hb, zc + ht
    crown = 0.06 * ht
    pts = []
    # flat belly
    for u in (0.0, 0.35, 0.7):
        pts.append((bw * u, zb + 0.03 * hb * u * u))
    pts.append((bw, zb + 0.03 * hb))
    # two lower facets (crease) up to the chine
    pk = (lerp(bw, hw, 0.72), zc - hb * 0.42)
    pts.append(((bw + pk[0]) * 0.5, (zb + 0.03 * hb + pk[1]) * 0.5))
    pts.append(pk)
    pts.append(((pk[0] + hw) * 0.5, (pk[1] + zc - 0.035) * 0.5))
    pts.append((hw, zc - 0.035))
    lip = CHINE_LIP * smooth((NOSE_Y - y) / 1.5)
    pts.append((hw + lip, zc))  # chine blade
    # two upper facets: steep shoulder, then a shallow bevel onto the deck
    qk = (lerp(hw, dw, 0.38), zc + ht * 0.62)
    pts.append((hw, zc + 0.035))
    pts.append(((hw + qk[0]) * 0.5, (zc + 0.035 + qk[1]) * 0.5))
    pts.append(qk)
    pts.append(((qk[0] + dw) * 0.5, (qk[1] + zt) * 0.5))
    pts.append((dw, zt))
    for u in (0.35, 0.7, 1.0):
        x = dw * (1 - u)
        pts.append((x, zt + crown * (1 - (x / dw) ** 2)))
    _HALF_CACHE[key] = pts
    return pts


CHINE_I = 8


def _interp_x(poly, x):
    """poly: [(x, z)] with x ascending."""
    if x <= poly[0][0]:
        return poly[0][1]
    for i in range(len(poly) - 1):
        (xa, za), (xb, zb) = poly[i], poly[i + 1]
        if xa <= x <= xb:
            t = 0.0 if xb - xa < 1e-9 else (x - xa) / (xb - xa)
            return lerp(za, zb, t)
    return poly[-1][1]


def hull_belly_z(x, y):
    pts = hull_half(y)
    return _interp_x(pts[:CHINE_I], abs(x))


def hull_top_z(x, y):
    pts = hull_half(y)
    top = list(reversed(pts[CHINE_I + 1:]))
    return _interp_x(top, abs(x))


def hull_ring(y):
    right = hull_half(y)
    left = [(-x, z) for (x, z) in reversed(right[1:-1])]
    return [Vector((x, y, z)) for (x, z) in right + left]


POD_CH = 0.34     # octagon chamfer (fraction of the smaller half size)


def oct_ring(cx, cz, a, b, y, chamfer=POD_CH, sub=2, ct=None):
    """Chamfered-rectangle (octagon) ring, `sub` points per edge, counter-clockwise from (+a, -b+c).
    ct: optional larger chamfer on the two top corners."""
    c = chamfer * min(a, b)
    c2 = c if ct is None else ct * min(a, b)
    corners = [(a, -b + c), (a, b - c2), (a - c2, b), (-a + c2, b), (-a, b - c2), (-a, -b + c), (-a + c, -b), (a - c, -b)]
    pts = []
    for i in range(8):
        p, q = corners[i], corners[(i + 1) % 8]
        for k in range(sub):
            t = k / sub
            pts.append(Vector((cx + lerp(p[0], q[0], t), y, cz + lerp(p[1], q[1], t))))
    return pts


POD_CT = 0.55     # bigger top chamfer: armoured shoulder


def pod_ring(y, cx=None, scale=1.0):
    cx = PCX(y) if cx is None else cx
    return oct_ring(cx, PCZ(y), PA(y) * scale, PB(y) * scale, y, ct=POD_CT)


def pod_belly_z(x, y, cx):
    a, b, cz = PA(y), PB(y), PCZ(y)
    c = POD_CH * min(a, b)
    dx = abs(x - cx)
    if dx <= a - c:
        return cz - b
    return cz - b + min(dx - (a - c), c)


def pod_top_z(x, y, cx):
    a, b, cz = PA(y), PB(y), PCZ(y)
    c = POD_CT * min(a, b)
    dx = abs(x - cx)
    if dx <= a - c:
        return cz + b
    return cz + b - min(dx - (a - c), c)


def superellipse_ring(cx, cz, a, b, n, y, count=32):
    pts = []
    for i in range(count):
        t = i / count * 2 * math.pi
        pts.append(Vector((cx + a * spow(math.cos(t), 2 / n), y, cz + b * spow(math.sin(t), 2 / n))))
    return pts


def airfoil(c, t):
    """Faceted hard-surface section in (chord, normal) offsets: LE at 0, TE at -c."""
    up = [(0.0, 0.0), (-0.08 * c, 0.30 * t), (-0.30 * c, 0.5 * t), (-0.70 * c, 0.42 * t), (-c, 0.05 * t)]
    lo = [(-c, -0.05 * t), (-0.70 * c, -0.40 * t), (-0.30 * c, -0.46 * t), (-0.08 * c, -0.28 * t)]
    return up + lo


# ----------------------------------------------------------------------------------------------
# bmesh builders
# ----------------------------------------------------------------------------------------------
def loft(bm, rings, mat, cap0=True, cap1=True, seg_mat=None, pole0=None, pole1=None, closed=True, cap_mats=None,
         ring_mats=None):
    """Stitch equal-sized rings. seg_mat(i) -> material for the band between ring i and i+1."""
    vrings = [[bm.verts.new(p) for p in r] for r in rings]
    n = len(rings[0])
    cm0 = cap_mats[0] if cap_mats else mat
    cm1 = cap_mats[1] if cap_mats else mat
    faces = []
    for i in range(len(vrings) - 1):
        a, b = vrings[i], vrings[i + 1]
        m = seg_mat(i) if seg_mat else mat
        rng = range(n) if closed else range(n - 1)
        for j in rng:
            k = (j + 1) % n
            f = bm.faces.new((a[j], a[k], b[k], b[j]))
            f.material_index = ring_mats[j] if ring_mats is not None and m == mat else m
            faces.append(f)
    if pole0 is not None:
        pv = bm.verts.new(pole0)
        for j in range(n):
            f = bm.faces.new((vrings[0][(j + 1) % n], vrings[0][j], pv))
            f.material_index = cm0
    elif cap0 and closed:
        f = bm.faces.new(list(reversed(vrings[0])))
        f.material_index = cm0
    if pole1 is not None:
        pv = bm.verts.new(pole1)
        for j in range(n):
            f = bm.faces.new((vrings[-1][j], vrings[-1][(j + 1) % n], pv))
            f.material_index = cm1
    elif cap1 and closed:
        f = bm.faces.new(vrings[-1])
        f.material_index = cm1
    return vrings


def add_box(bm, center, size, mat, rot=None):
    m = Matrix.Translation(Vector(center))
    if rot is not None:
        m = m @ rot
    m = m @ Matrix.Diagonal((size[0], size[1], size[2], 1.0))
    res = bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    fs = {f for v in res['verts'] for f in v.link_faces}
    for f in fs:
        f.material_index = mat
    return res['verts']


def align_z(direction):
    d = Vector(direction).normalized()
    return d.to_track_quat('Z', 'Y').to_matrix().to_4x4()


def add_cyl(bm, p0, p1, r, mat, segs=16, r2=None):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    m = Matrix.Translation((p0 + p1) * 0.5) @ align_z(d)
    res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segs, radius1=r,
                                radius2=r if r2 is None else r2, depth=d.length, matrix=m)
    fs = {f for v in res['verts'] for f in v.link_faces}
    for f in fs:
        f.material_index = mat
    return res['verts']


def add_sphere(bm, c, r, mat, segs=12, rings=8, scale=(1, 1, 1)):
    m = Matrix.Translation(Vector(c)) @ Matrix.Diagonal((scale[0], scale[1], scale[2], 1))
    res = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r, matrix=m)
    fs = {f for v in res['verts'] for f in v.link_faces}
    for f in fs:
        f.material_index = mat
    return res['verts']


def sweep(bm, frames, hw, hh, mat, cap=True):
    """Rectangular tube along frames [(center, u_axis, v_axis)]; profile +-hw along u, +-hh along v."""
    rings = []
    for c, u, v in frames:
        u, v = u.normalized(), v.normalized()
        rings.append([c + u * hw + v * hh, c - u * hw + v * hh, c - u * hw - v * hh, c + u * hw - v * hh])
    return loft(bm, rings, mat, cap0=cap, cap1=cap)


def add_quad_uv(bm, uv_layer, corners, uv_rect, mat):
    """One quad with explicit UVs (corners counter-clockwise seen from the front)."""
    vs = [bm.verts.new(c) for c in corners]
    f = bm.faces.new(vs)
    f.material_index = mat
    u0, v0, u1, v1 = uv_rect
    for loop, uv in zip(f.loops, ((u0, v0), (u1, v0), (u1, v1), (u0, v1))):
        loop[uv_layer].uv = uv
    return f


# ----------------------------------------------------------------------------------------------
# Scene / object helpers
# ----------------------------------------------------------------------------------------------
def make_materials():
    out = []
    for name in MATS:
        m = bpy.data.materials.new(name)
        col, metal, rough = MAT_PREVIEW[name]
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = col
            bsdf.inputs["Metallic"].default_value = metal
            bsdf.inputs["Roughness"].default_value = rough
            if name in ("Emissive", "EngineInner", "Display", "Lamp"):
                bsdf.inputs["Emission Color"].default_value = col
                bsdf.inputs["Emission Strength"].default_value = 4.0
        out.append(m)
    return out


MATERIALS = []


def obj_from_bm(name, bm, location=(0, 0, 0), recalc=True):
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in MATERIALS:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    ob.location = location
    bpy.context.scene.collection.objects.link(ob)
    return ob


def activate(ob):
    bpy.context.view_layer.update()
    for o in bpy.context.view_layer.objects:
        if o is not None:
            o.select_set(False)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob


def apply_mods(ob):
    activate(ob)
    for md in list(ob.modifiers):
        try:
            bpy.ops.object.modifier_apply(modifier=md.name)
        except RuntimeError as e:
            print("[ship] modifier failed", ob.name, md.name, e)
            ob.modifiers.remove(md)


def boolean(ob, cutter, op, solver='EXACT'):
    md = ob.modifiers.new("bool", 'BOOLEAN')
    md.operation = op
    md.object = cutter
    md.solver = solver
    if hasattr(md, "material_mode"):
        md.material_mode = 'TRANSFER'
    apply_mods(ob)
    print("[ship] bool %-10s %-14s -> %d faces" % (op, cutter.name, len(ob.data.polygons)))


def bevel(ob, width=BEVEL_W, segs=2, angle=32.0):
    md = ob.modifiers.new("bevel", 'BEVEL')
    md.width = width
    md.segments = segs
    md.limit_method = 'ANGLE'
    md.angle_limit = math.radians(angle)
    md.use_clamp_overlap = True
    md.profile = 0.6
    md.miter_outer = 'MITER_ARC'
    apply_mods(ob)


def remove(ob):
    me = ob.data
    bpy.data.objects.remove(ob, do_unlink=True)
    if me and me.users == 0:
        bpy.data.meshes.remove(me)


def join(objs, name):
    activate(objs[0])
    for o in objs[1:]:
        o.select_set(True)
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def finalize_normals(ob, sharp_deg=46.0):
    """Smooth shading + sharp edges by angle + weighted normals (keeps flat faces flat)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=1e-6)
    lim = math.radians(sharp_deg)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        if len(e.link_faces) != 2:
            e.smooth = False
            continue
        e.smooth = e.calc_face_angle(0.0) < lim and e.link_faces[0].material_index == e.link_faces[1].material_index
    bm.to_mesh(ob.data)
    bm.free()
    md = ob.modifiers.new("wn", 'WEIGHTED_NORMAL')
    md.keep_sharp = True
    md.weight = 50
    md.mode = 'FACE_AREA'
    apply_mods(ob)


def ensure_uv(ob):
    if not ob.data.uv_layers:
        ob.data.uv_layers.new(name="UVMap")


def empty(name, loc, direction=None, rot=None, size=0.3, extras=None, parent=None):
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_type = 'ARROWS'
    ob.empty_display_size = size
    ob.location = loc
    if direction is not None:
        # Godot -Z == Blender +Y, so track +Y along the emission direction
        ob.rotation_mode = 'QUATERNION'
        ob.rotation_quaternion = Vector(direction).normalized().to_track_quat('Y', 'Z')
    elif rot is not None:
        ob.rotation_mode = 'QUATERNION'
        ob.rotation_quaternion = rot
    if extras:
        for k, v in extras.items():
            ob[k] = v
    bpy.context.scene.collection.objects.link(ob)
    if parent is not None:
        ob.parent = parent
        ob.matrix_parent_inverse = parent.matrix_world.inverted()
    return ob


# ----------------------------------------------------------------------------------------------
# Main hull parts
# ----------------------------------------------------------------------------------------------
def station_ys():
    ys = []
    y = TAIL_Y
    while y < NOSE_Y - 0.06:
        ys.append(y)
        step = 0.4 if y < 7.5 else (0.22 if y < 10.2 else 0.1)
        y += step
    ys.append(NOSE_Y - 0.04)
    return ys


def build_hull():
    bm = bmesh.new()
    rings = [hull_ring(y) for y in station_ys()]
    loft(bm, rings, HULL, cap0=True, pole1=Vector((0, NOSE_Y + 0.05, ZC(NOSE_Y))), cap_mats=(HULL, HULL))
    return obj_from_bm("HullBody", bm)


SPINE_K = 16


def _poly_at(poly, u):
    """Point at normalized arc length u along a 2D polyline."""
    segs = [math.dist(poly[i], poly[i + 1]) for i in range(len(poly) - 1)]
    tot = sum(segs)
    d = u * tot
    for i, s_ in enumerate(segs):
        if d <= s_ or i == len(segs) - 1:
            t = 0.0 if s_ < 1e-9 else min(d / s_, 1.0)
            return (lerp(poly[i][0], poly[i + 1][0], t), lerp(poly[i][1], poly[i + 1][1], t))
        d -= s_
    return poly[-1]


def spine_profile(y):
    """Upper outline of the spine at y (right base -> top -> left base), SPINE_K + 1 points.
    Near the canopy it is the canopy arc itself (seamless), aft it becomes a chamfered trapezoid."""
    w = smooth((y - (-0.8)) / (CANOPY_Y0 - (-0.8)))
    yc = min(y, CANOPY_Y0)
    cw, ct = CW(yc), CT(yc)
    zbc = hull_top_z(cw, y) - 0.05
    zd = hull_top_z(0, y)
    zt = zd + SPH(y)
    wt = SPW(y)
    wb = wt + 0.46
    trap = [(wb, hull_top_z(wb, y) - 0.03), (wt + 0.18, zt - 0.12), (wt + 0.03, zt - 0.01), (wt * 0.55, zt + 0.035),
            (0.0, zt + 0.045)]
    trap = trap + [(-x, z) for (x, z) in reversed(trap[:-1])]
    out = []
    for i in range(SPINE_K + 1):
        a = i / SPINE_K * math.pi
        xa = cw * spow(math.cos(a), 2 / 2.35)
        za = zbc + (ct - zbc) * abs(math.sin(a)) ** (2 / 2.35)
        xt, zt_ = _poly_at(trap, i / SPINE_K)
        out.append((lerp(xt, xa, w), lerp(zt_, za, w)))
    return out


def build_spine():
    """Dorsal systems spine: grows out of the canopy rear and fades into the deck at the tail."""
    bm = bmesh.new()
    rings = []
    ys = [lerp(-7.75, CANOPY_Y0 + 0.45, i / 30) for i in range(31)]
    for y in ys:
        prof_ = spine_profile(y)
        zd = hull_top_z(0, y)
        xb = abs(prof_[0][0])
        pts = prof_ + [(-xb * 0.95, zd - 0.35), (xb * 0.95, zd - 0.35)]
        rings.append([Vector((x, y, z)) for (x, z) in pts])
    loft(bm, rings, HULL)
    return obj_from_bm("Spine", bm)


def pod_ys():
    ys = [POD_REAR_Y + i * 0.45 for i in range(int((-2.4 - POD_REAR_Y) / 0.45) + 1)]
    ys += [lerp(-2.4, POD_FRONT_Y - 0.02, (i / 8) ** 0.9) for i in range(1, 9)]
    return ys


def build_pods():
    bm = bmesh.new()
    for side in (1, -1):
        rings = []
        ys = pod_ys()
        y_sh = ys[-6]
        for y in ys:
            ring = pod_ring(y)
            # shear the front rings into a slanted armoured prow (top forward)
            k = smooth((y - y_sh) / (POD_FRONT_Y - y_sh))
            if k > 0:
                cz, b = PCZ(y), PB(y)
                for p in ring:
                    p.y += k * POD_PROW * (p.z - cz) / (2 * b)
            rings.append([Vector((p.x * side, p.y, p.z)) for p in ring])
        loft(bm, rings, HULL, cap_mats=(DARK, HULL))
    return obj_from_bm("Pods", bm)


def rad_axes(side):
    a = math.radians(RAD_DIHEDRAL)
    span = Vector((math.cos(a) * side, 0, math.sin(a)))
    nrm = Vector((-math.sin(a) * side, 0, math.cos(a)))
    root = Vector((RAD_ROOT[0] * side, 0, RAD_ROOT[1]))
    return root, span, nrm


def rad_chord(t):
    return lerp(RAD_ROOT_LE, RAD_TIP_LE, t), lerp(RAD_ROOT_TE, RAD_TIP_TE, t), lerp(RAD_TH_ROOT, RAD_TH_TIP, t)


def rad_frame(side, t, along):
    """Point on the radiator wing mid-plane: t = 0..1 span (root..tip), along = 0..1 chord (LE->TE);
    returns (pos, normal, span_dir, half_thickness)."""
    root, span, nrm = rad_axes(side)
    le, te, th = rad_chord(t)
    c = root + span * (RAD_SPAN * t)
    return Vector((c.x, lerp(le, te, along), c.z)), nrm, span, th * 0.5


def build_wings():
    """Radiator wings: thick slabs with chamfered edges, embedded in the pod shoulders at the root."""
    bm = bmesh.new()
    for side in (1, -1):
        root, span, nrm = rad_axes(side)
        geo = []
        ts = [-0.12] + [i / 7 for i in range(8)]
        for t in ts:
            le, te, th = rad_chord(max(t, 0.0))
            c = root + span * (RAD_SPAN * t)
            chord = le - te
            ring = []
            for (dy, dn) in ((0.0, 0.0), (-0.22, 0.5), (-chord + 0.18, 0.5), (-chord, 0.12), (-chord, -0.12),
                             (-chord + 0.18, -0.5), (-0.22, -0.5)):
                ring.append(Vector((c.x, le + dy, c.z)) + nrm * (dn * th))
            geo.append(ring)
        loft(bm, geo, HULL)
    return obj_from_bm("Wings", bm)


def wing_tip(side=1):
    root, span, nrm = rad_axes(side)
    return root + span * RAD_SPAN


def build_wingtip_caps():
    """Chunky tip blocks on the radiator wings (nav light at the front corner)."""
    bm = bmesh.new()
    for side in (1, -1):
        root, span, nrm = rad_axes(side)
        rings = []
        for k, (t, sc) in enumerate(((1.0 - 0.10 / RAD_SPAN, 1.0), (1.0 + 0.10 / RAD_SPAN, 1.0), (1.0 + 0.16 / RAD_SPAN, 0.75))):
            le, te, th = rad_chord(1.0)
            le += 0.35
            te -= 0.08
            c = root + span * (RAD_SPAN * t)
            h = 0.13 * sc
            chord = le - te
            ring = [(0.0, 0.0), (-0.4, h), (-chord + 0.25, h * 0.9), (-chord, 0.0), (-chord + 0.25, -h * 0.9), (-0.4, -h)]
            rings.append([Vector((c.x, le + dy, c.z)) + nrm * dn for (dy, dn) in ring])
        loft(bm, rings, HULL)
    return obj_from_bm("TipCaps", bm)



def build_keel():
    """Belly cargo keel (the boarding ramp is cut into its front half)."""
    bm = bmesh.new()
    rings = []
    ys = [KEEL_Y0 - 0.7, KEEL_Y0] + [lerp(KEEL_Y0, KEEL_Y1, i / 14) for i in range(1, 14)] + [KEEL_Y1, KEEL_Y1 + 0.75]
    for k, y in enumerate(ys):
        zb = hull_belly_z(0, y)
        if k == 0 or k == len(ys) - 1:
            zk = zb + 0.06
            wb = 1.05
        else:
            zk = KEEL_Z
            wb = 1.38
        wt = 1.62
        z0 = zb + 0.25
        right = [(0.0, zk), (wb - 0.08, zk), (wb, zk + 0.07), (wt, z0)]
        left = [(-x, z) for (x, z) in reversed(right[1:])]
        rings.append([Vector((x, y, z)) for (x, z) in right + left])
    loft(bm, rings, HULL)
    return obj_from_bm("Keel", bm)


# ----------------------------------------------------------------------------------------------
# Cutters
# ----------------------------------------------------------------------------------------------
def build_cockpit_cutter():
    bm = bmesh.new()
    rings = []
    ys = [lerp(CANOPY_Y0 + 0.35, CANOPY_Y1 - 0.7, i / 16) for i in range(17)]
    for y in ys:
        hw = max(CW(y) - 0.09, 0.14)
        top = 2.6
        rings.append(superellipse_ring(0, (COCKPIT_FLOOR + top) / 2, hw, (top - COCKPIT_FLOOR) / 2, 6.0, y, count=28))
    loft(bm, rings, DARK)
    return obj_from_bm("CockpitCut", bm)


def build_pocket_cutter():
    bm = bmesh.new()
    ztop = KEEL_Z + 0.62
    add_box(bm, (0, (HATCH_Y0 + HATCH_Y1) / 2, (ztop + KEEL_Z - 0.4) / 2),
            (HATCH_HALF_W * 2 + 0.04, HATCH_Y1 - HATCH_Y0 + 0.03, ztop - KEEL_Z + 0.4), DARK)
    return obj_from_bm("PocketCut", bm)


# ----------------------------------------------------------------------------------------------
# Nozzles & aft
# ----------------------------------------------------------------------------------------------
def build_nozzles():
    bm = bmesh.new()
    for side in (1, -1):
        cx = POD_X * side
        cz = POD_Z
        a0, b0 = PA(POD_REAR_Y), PB(POD_REAR_Y)
        y0 = POD_REAR_Y + 0.05
        y1 = POD_REAR_Y - NOZZLE_LEN
        n = 2.3
        # (y, scale x, scale z, material of band to next)
        prof_ = [
            (y0, 0.92, 0.88, TRIM), (y0 - 0.22, 0.92, 0.88, TRIM), (y0 - 0.24, 0.97, 0.93, TRIM),
            (y0 - 0.42, 0.97, 0.93, TRIM), (y0 - 0.44, 0.90, 0.86, TRIM), (y1 + 0.16, 0.95, 0.91, TRIM),
            (y1 + 0.04, 0.96, 0.92, EMIT), (y1, 0.96, 0.92, TRIM), (y1 - 0.01, 0.90, 0.86, TRIM),
            (y1, 0.84, 0.80, ENGINE), (y1 + 0.55, 0.76, 0.72, ENGINE), (y0 - 0.3, 0.66, 0.62, ENGINE),
        ]
        rings = [oct_ring(cx, cz, a0 * sx, b0 * sz, y, sub=4, ct=POD_CT) for (y, sx, sz, _) in prof_]
        loft(bm, rings, TRIM, seg_mat=lambda i, p=prof_: p[i][3], cap0=True,
             pole1=Vector((cx, y0 - 0.6, cz)), cap_mats=(TRIM, ENGINE))
        # centre plug
        add_cyl(bm, (cx, y0 - 0.55, cz), (cx, y1 + 0.35, cz), 0.24, TRIM, segs=20, r2=0.10)
        add_cyl(bm, (cx, y1 + 0.35, cz), (cx, y1 + 0.28, cz), 0.10, ENGINE, segs=20, r2=0.04)
        # actuator fairings around the bell
        for ang in (35, 145, 215, 325):
            a = math.radians(ang)
            px = cx + math.cos(a) * a0 * 0.95
            pz = cz + math.sin(a) * b0 * 0.92
            add_cyl(bm, (px, y0 - 0.1, pz), (px, y0 - 0.75, pz), 0.045, DARK, segs=8)
    # centre auxiliary engine in the hull tail
    cz = 0.12
    prof_ = [(TAIL_Y + 0.05, 1.0, TRIM), (TAIL_Y - 0.35, 0.97, TRIM), (TAIL_Y - 0.38, 0.98, EMIT),
             (TAIL_Y - 0.40, 0.88, ENGINE), (TAIL_Y - 0.05, 0.80, ENGINE)]
    rings = [superellipse_ring(0, cz, 0.78 * s, 0.30 * s, 3.2, y, count=32) for (y, s, _) in prof_]
    loft(bm, rings, TRIM, seg_mat=lambda i: prof_[i][2], pole1=Vector((0, TAIL_Y + 0.02, cz)), cap_mats=(TRIM, ENGINE))
    return obj_from_bm("Nozzles", bm)


# ----------------------------------------------------------------------------------------------
# Details (not unioned)
# ----------------------------------------------------------------------------------------------
def rcs_points():
    """(position, outward jet direction) in Blender space, names in RCS_NAMES."""
    pts = []
    y = 9.0
    hw = HW(y)
    pts.append(((hw - 0.06, y, ZC(y) + 0.10), (1, 0, 0)))
    pts.append(((-hw + 0.06, y, ZC(y) + 0.10), (-1, 0, 0)))
    pts.append(((0, y, hull_top_z(0, y) - 0.005), (0, 0.15, 1)))
    pts.append(((0, y - 0.3, hull_belly_z(0, y - 0.3) + 0.005), (0, 0.15, -1)))
    y = -7.55
    for s in (1, -1):
        pts.append(((s * (POD_X + PA(y) - 0.02), y, POD_Z + 0.25), (s, 0, 0)))
    for s in (1, -1):
        pts.append(((s * (POD_X + 0.42), y, pod_top_z(POD_X + 0.42, y, POD_X) - 0.01), (0, 0, 1)))
    for s in (1, -1):
        pts.append(((s * (POD_X + 0.45), y, pod_belly_z(POD_X + 0.45, y, POD_X) + 0.01), (0, 0, -1)))
    return pts


RCS_NAMES = ["Thruster_NoseR", "Thruster_NoseL", "Thruster_NoseUp", "Thruster_NoseDown",
             "Thruster_TailR", "Thruster_TailL", "Thruster_TailUpR", "Thruster_TailUpL",
             "Thruster_TailDownR", "Thruster_TailDownL"]


def nav_points():
    tr = wing_tip(1)
    le = rad_chord(1.0)[0] + 0.33
    zt = mast_top()
    return {"NavLight_R": Vector((tr.x + 0.10, le, tr.z + 0.08)), "NavLight_L": Vector((-tr.x - 0.10, le, tr.z + 0.08)),
            "NavLight_Top": Vector((0, MAST_Y - 0.28, zt + 0.07)),
            "NavLight_Tail": Vector((0, TAIL_Y - 0.06, hull_top_z(0, TAIL_Y) - 0.18)),
            "NavLight_Belly": Vector((0, -5.6, hull_belly_z(0, -5.6) - 0.06))}


MAST_Y = -3.2


def mast_base():
    y = MAST_Y
    return Vector((0, y, hull_top_z(0, y) + SPH(y) + 0.02))


def mast_top():
    return mast_base().z + 1.12


def flood_points():
    """Downward/forward floodlights under the hull: (name, pos, dir)."""
    out = []
    y = 8.6
    for s, nm in ((1, "Flood_NoseR"), (-1, "Flood_NoseL")):
        x = 0.42 * s
        out.append((nm, Vector((x, y, hull_belly_z(x, y) - 0.02)), Vector((0.08 * s, 0.55, -1.0))))
    y = -6.6
    for s, nm in ((1, "Flood_PodR"), (-1, "Flood_PodL")):
        x = (POD_X - 0.35) * s
        out.append((nm, Vector((x, y, pod_belly_z(abs(x), y, POD_X) - 0.02)), Vector((0.25 * s, -0.35, -1.0))))
    return out


def deck_light_points():
    """Small lamps at the spine shoulders shining back over the engine deck / radiators."""
    out = []
    y = -0.6
    for s, nm in ((1, "DeckLight_R"), (-1, "DeckLight_L")):
        z = hull_top_z(0, y) + SPH(y) - 0.08
        x = (SPW(y) + 0.12) * s
        out.append((nm, Vector((x, y, z)), Vector((0.55 * s, -1.0, -0.22))))
    return out


def flank_light_points():
    """Logo-style lamps under the radiator tips, washing the pod flanks and hull sides (night readability)."""
    out = []
    for s, nm in ((1, "FlankLight_R"), (-1, "FlankLight_L")):
        tip = wing_tip(s)
        p = Vector((tip.x - 0.35 * s, rad_chord(1.0)[0] - 0.6, tip.z - 0.22))
        out.append((nm, p, Vector((-0.75 * s, 0.55, -0.55))))
    return out


def build_details():
    bm = bmesh.new()
    # --- emissive chine strip (just under the blade, full length) ---
    for side in (1, -1):
        frames = []
        n = 30
        for i in range(n + 1):
            y = lerp(-7.9, 9.6, i / n)
            p = Vector((side * (HW(y) + 0.012), y, ZC(y) - 0.045))
            frames.append((p, Vector((side, 0, -0.5)), Vector((0, 0, 1))))
        sweep(bm, frames, 0.010, 0.012, EMIT)
    # --- deck edge accent strips (aft deck, visible from the chase camera) ---
    for side in (1, -1):
        frames = []
        n = 18
        for i in range(n + 1):
            y = lerp(-7.95, 1.4, i / n)
            dw = DW(y)
            p = Vector((side * (dw + 0.03), y, hull_top_z(dw + 0.03, y) + 0.004))
            frames.append((p, Vector((side, 0, 0.6)), Vector((-0.6 * side, 0, 1))))
        sweep(bm, frames, 0.012, 0.008, EMIT)
    # --- pod flank strips ---
    for side in (1, -1):
        frames = []
        for i in range(13):
            y = lerp(-7.9, -1.6, i / 12)
            x = side * (PCX(y) + PA(y) * 0.985)
            frames.append((Vector((x, y, POD_Z + 0.32)), Vector((side, 0, 0)), Vector((0, 0, 1))))
        sweep(bm, frames, 0.010, 0.014, EMIT)
    # --- RCS blocks ---
    for p, n in rcs_points():
        n = Vector(n)
        rot = n.to_track_quat('Z', 'Y').to_matrix().to_4x4()
        add_box(bm, Vector(p) - n * 0.03, (0.26, 0.26, 0.10), DARK, rot)
        for ox in (-0.06, 0.06):
            off = (rot @ Vector((ox, 0, 0, 0))).to_3d()
            add_cyl(bm, Vector(p) + off - n * 0.01, Vector(p) + off + n * 0.04, 0.035, ENGINE, segs=8)
    # --- nav light housings ---
    for name, p in nav_points().items():
        add_sphere(bm, p, 0.065, GLASS, segs=10, rings=6)
    # --- floodlight housings (lamp lens + bezel) ---
    for nm, p, d in flood_points() + deck_light_points() + flank_light_points():
        d = d.normalized()
        rot = d.to_track_quat('Z', 'Y').to_matrix().to_4x4()
        add_cyl(bm, p - d * 0.06, p + d * 0.01, 0.12, DARK, segs=14)
        add_cyl(bm, p + d * 0.01, p + d * 0.02, 0.09, LAMP, segs=14)
    # --- sensor mast ---
    b = mast_base()
    zt = mast_top()
    add_box(bm, (0, MAST_Y, b.z + 0.05), (0.34, 0.6, 0.16), DARK)
    add_cyl(bm, b, (0, MAST_Y - 0.25, zt), 0.07, TRIM, segs=12, r2=0.04)
    add_sphere(bm, (0, MAST_Y - 0.14, b.z + 0.62), 0.16, HULL, segs=16, rings=10, scale=(1.0, 1.6, 0.85))
    add_box(bm, (0, MAST_Y - 0.14, b.z + 0.62), (0.36, 0.08, 0.03), EMIT)
    add_cyl(bm, (0, MAST_Y + 0.05, b.z + 0.62), (0, MAST_Y + 0.2, b.z + 0.62), 0.16, DARK, segs=16, r2=0.22)  # dish
    for zz, w in ((zt - 0.32, 0.55), (zt - 0.12, 0.38)):
        add_box(bm, (0, MAST_Y - 0.22, zz), (w, 0.04, 0.025), TRIM)
    add_cyl(bm, (0, MAST_Y - 0.28, zt), (0, MAST_Y - 0.28, zt + 0.04), 0.05, DARK, segs=10)
    # --- spine vent louvres (both flanks) ---
    for side in (1, -1):
        for i in range(9):
            y = lerp(-0.4, -4.6, i / 8)
            zd = hull_top_z(0, y)
            zt_ = zd + SPH(y)
            wt = SPW(y)
            p = Vector((side * (wt + 0.22), y, zt_ - 0.28))
            nrm = Vector((side * 0.9, 0, 0.45)).normalized()
            rot = nrm.to_track_quat('Z', 'Y').to_matrix().to_4x4()
            add_box(bm, p, (0.28, 0.07, 0.04), DARK, rot)
    # --- radiator wing ribs (both faces) + glowing trailing edge ---
    for side in (1, -1):
        for face in (1, -1):
            for k in range(13):
                along = 0.10 + 0.82 * k / 12
                t0 = 0.10 if along > 0.35 else 0.10 + (0.35 - along) * 0.6
                pa, n, sp, ha = rad_frame(side, t0, along)
                pb, _, _, hb = rad_frame(side, 0.93, along)
                frames = [(pa + n * face * (ha + 0.004), n, Vector((0, 1, 0))),
                          (pb + n * face * (hb + 0.004), n, Vector((0, 1, 0)))]
                sweep(bm, frames, 0.014, 0.026, TRIM)
        pa, n, sp, ha = rad_frame(side, 0.04, 0.995)
        pb, _, _, hb = rad_frame(side, 0.97, 0.995)
        sweep(bm, [(pa, Vector((0, 1, 0)), n), (pb, Vector((0, 1, 0)), n)], 0.018, ha * 0.5, EMIT)
    # --- rear bulkhead: tail light bars, heat-exchanger grills ---
    yb = TAIL_Y - 0.01
    for side in (1, -1):
        x0 = 1.15 * side
        add_box(bm, (x0, yb - 0.02, 0.62), (0.9, 0.04, 0.05), EMIT)
        for k in range(5):
            add_box(bm, (side * (1.25 + 0.0), yb - 0.03, -0.12 - k * 0.1), (0.95, 0.05, 0.035), DARK)
    add_box(bm, (0, yb - 0.03, 0.82), (0.9, 0.06, 0.18), DARK)
    # --- belly antenna blades and sensor dome ---
    for y in (-2.0, -3.2):
        zb = KEEL_Z
        ring0 = [Vector((0.02, y + 0.25, zb + 0.02)), Vector((0.02, y - 0.25, zb + 0.02)),
                 Vector((-0.02, y - 0.25, zb + 0.02)), Vector((-0.02, y + 0.25, zb + 0.02))]
        ring1 = [Vector((0.01, y - 0.10, zb - 0.32)), Vector((0.01, y - 0.30, zb - 0.32)),
                 Vector((-0.01, y - 0.30, zb - 0.32)), Vector((-0.01, y - 0.10, zb - 0.32))]
        loft(bm, [ring0, ring1], DARK)
    add_sphere(bm, (0, 9.6, hull_belly_z(0, 9.6) + 0.03), 0.17, GLASS, segs=16, rings=8, scale=(1, 1.4, 0.6))
    # --- nose sensor window (chin) ---
    # --- pod nose sensor caps ---
    for side in (1, -1):
        cx, cz, bb = PCX(POD_FRONT_Y) * side, PCZ(POD_FRONT_Y), PB(POD_FRONT_Y)
        nrm = Vector((0, 2 * bb, -POD_PROW)).normalized()          # prow face normal (forward-down)
        rot = nrm.to_track_quat('Z', 'Y').to_matrix().to_4x4()
        for dz, w, h, m in ((0.35, 0.9, 0.16, GLASS), (-0.15, 0.5, 0.10, DARK), (-0.42, 0.7, 0.06, LAMP)):
            pz = cz + dz * bb
            py = POD_FRONT_Y + POD_PROW * (pz - cz) / (2 * bb)
            add_box(bm, Vector((cx, py, pz)) + nrm * 0.005, (w, h, 0.03), m, rot)
    return obj_from_bm("Details", bm)


# ----------------------------------------------------------------------------------------------
# Cockpit
# ----------------------------------------------------------------------------------------------
def build_cockpit_interior():
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    fl = COCKPIT_FLOOR
    sy = SEAT_Y
    # floor plate with tread strips
    add_box(bm, (0, 4.9, fl + 0.03), (1.3, 4.2, 0.06), DARK)
    for k in range(6):
        add_box(bm, (0, 3.2 + k * 0.32, fl + 0.065), (0.5, 0.05, 0.015), TRIM)
    # seat: base, cushion, back, headrest, side bolsters, arm rests
    add_box(bm, (0, sy + 0.05, fl + 0.18), (0.42, 0.5, 0.3), TRIM)
    add_box(bm, (0, sy + 0.12, fl + 0.40), (0.56, 0.58, 0.12), DARK)
    back = rot_x(16)
    add_box(bm, (0, sy - 0.22, fl + 0.86), (0.54, 0.14, 0.86), DARK, back)
    add_box(bm, (0, sy - 0.38, fl + 1.40), (0.34, 0.16, 0.26), DARK, back)
    for sx in (-0.31, 0.31):
        add_box(bm, (sx, sy - 0.17, fl + 0.82), (0.08, 0.2, 0.8), TRIM, back)
        add_box(bm, (sx * 1.05, sy + 0.12, fl + 0.62), (0.09, 0.5, 0.06), DARK)
        add_box(bm, (sx * 1.05, sy + 0.12, fl + 0.645), (0.05, 0.4, 0.01), EMIT)
    # side consoles
    for side in (1, -1):
        add_box(bm, (side * 0.62, sy + 0.55, fl + 0.38), (0.26, 1.6, 0.62), DARK)
        tilt = Matrix.Rotation(math.radians(-18 * side), 4, 'Y')
        add_box(bm, (side * 0.6, sy + 0.55, fl + 0.70), (0.26, 1.5, 0.04), TRIM, tilt)
        # small console screens
        for k, yy in enumerate((sy + 0.15, sy + 0.75)):
            x0, x1 = side * 0.50, side * 0.70
            z0 = fl + 0.728
            zA = z0 + (x0 - side * 0.6) * math.tan(math.radians(18)) * side
            zB = z0 + (x1 - side * 0.6) * math.tan(math.radians(18)) * side
            sid = 4 + k + (0 if side > 0 else 2)
            c = [Vector((x0, yy - 0.2, zA)), Vector((x1, yy - 0.2, zB)), Vector((x1, yy + 0.2, zB)), Vector((x0, yy + 0.2, zA))]
            if side < 0:
                c = [c[1], c[0], c[3], c[2]]
            add_quad_uv(bm, uv, c, (sid, 0.0, sid + 1, 1.0), DISPLAY)
        # throttle / stick
    add_cyl(bm, (0.5, sy + 0.45, fl + 0.72), (0.5, sy + 0.55, fl + 0.95), 0.025, TRIM, segs=8)
    add_box(bm, (0.5, sy + 0.56, fl + 0.98), (0.07, 0.09, 0.11), DARK)
    add_box(bm, (-0.52, sy + 0.40, fl + 0.82), (0.07, 0.14, 0.16), DARK)
    add_box(bm, (-0.52, sy + 0.40, fl + 0.905), (0.06, 0.12, 0.012), EMIT)
    # main dash: body + angled face with three displays
    dy = 5.45
    add_box(bm, (0, dy + 0.25, fl + 0.33), (1.25, 0.6, 0.66), DARK)
    tilt = rot_x(48)
    add_box(bm, (0, dy - 0.02, fl + 0.64), (1.32, 0.5, 0.06), TRIM, tilt)
    # glare shield
    add_box(bm, (0, dy + 0.26, fl + 0.78), (1.36, 0.36, 0.05), DARK, rot_x(8))
    # displays (on the tilted dash face)
    face_n = (tilt @ Vector((0, 0, 1, 0))).to_3d()
    face_u = Vector((1, 0, 0))
    face_v = (tilt @ Vector((0, 1, 0, 0))).to_3d()
    cen = Vector((0, dy - 0.02, fl + 0.64)) + face_n * 0.032
    for k, (ox, w) in enumerate(((-0.42, 0.36), (0.0, 0.40), (0.42, 0.36))):
        c0 = cen + face_u * (ox - w / 2) - face_v * 0.17
        c1 = cen + face_u * (ox + w / 2) - face_v * 0.17
        c2 = cen + face_u * (ox + w / 2) + face_v * 0.17
        c3 = cen + face_u * (ox - w / 2) + face_v * 0.17
        add_quad_uv(bm, uv, [c0, c1, c2, c3], (k, 0.0, k + 1, 1.0), DISPLAY)
    # HUD combiner: thin glass on a post, with a glowing projector
    add_box(bm, (0, dy + 0.12, fl + 0.82), (0.22, 0.08, 0.05), DARK)
    add_box(bm, (0, dy + 0.10, fl + 0.85), (0.16, 0.02, 0.01), EMIT)
    add_box(bm, (0, dy + 0.08, fl + 0.97), (0.26, 0.008, 0.18), GLASS, rot_x(-14))
    # rear equipment bulkhead
    add_box(bm, (0, 2.95, fl + 0.7), (1.35, 0.3, 1.4), DARK)
    for k in range(4):
        add_box(bm, (-0.45 + k * 0.3, 3.11, fl + 0.95), (0.18, 0.02, 0.05), EMIT if k % 2 == 0 else LAMP)
    # canopy sill coaming
    for side in (1, -1):
        frames = []
        for i in range(13):
            y = lerp(CANOPY_Y0 + 0.4, CANOPY_Y1 - 0.75, i / 12)
            x = side * (CW(y) - 0.12)
            frames.append((Vector((x, y, hull_top_z(CW(y), y) - 0.08)), Vector((1, 0, 0)), Vector((0, 0, 1))))
        sweep(bm, frames, 0.05, 0.06, DARK)
    bmesh.ops.recalc_face_normals(bm, faces=[f for f in bm.faces if f.material_index != DISPLAY])
    return obj_from_bm("Cockpit", bm, recalc=False)


def canopy_arc(y, k=18, n=2.35, inset=0.0, lift=0.0):
    cw = CW(y) - inset
    zb = hull_top_z(cw, y) - 0.05
    ct = CT(y) - inset * 0.6 + lift
    pts = []
    for i in range(k + 1):
        a = i / k * math.pi
        x = cw * spow(math.cos(a), 2 / n)
        z = zb + (ct - zb) * abs(math.sin(a)) ** (2 / n)
        pts.append(Vector((x, y, z)))
    return pts


def canopy_ys():
    return [lerp(CANOPY_Y0, CANOPY_Y1 - 0.01, (i / 28) ** 0.9) for i in range(29)]


def build_canopy():
    """Single seamless bubble (open bottom, solidified) + a slim sill rail and rear seal. Origin = rear hinge."""
    bm = bmesh.new()
    rings = [canopy_arc(y) for y in canopy_ys()]
    tip = Vector((0, CANOPY_Y1 + 0.03, hull_top_z(0, CANOPY_Y1) - 0.02))
    vr = loft(bm, rings, GLASS, closed=False, cap0=False, cap1=False)
    last = vr[-1]
    pv = bm.verts.new(tip)
    for j in range(len(last) - 1):
        f = bm.faces.new((last[j], last[j + 1], pv))
        f.material_index = GLASS
    glass = obj_from_bm("CanopyGlass", bm, recalc=False)
    bm2 = bmesh.new()
    bm2.from_mesh(glass.data)
    bmesh.ops.recalc_face_normals(bm2, faces=bm2.faces)
    ctr = Vector((0, (CANOPY_Y0 + CANOPY_Y1) / 2, 0.8))
    flip = sum((f.normal.dot(f.calc_center_median() - ctr) < 0) for f in bm2.faces) > len(bm2.faces) / 2
    if flip:
        bmesh.ops.reverse_faces(bm2, faces=bm2.faces)
    bm2.to_mesh(glass.data)
    bm2.free()
    md = glass.modifiers.new("solid", 'SOLIDIFY')
    md.thickness = 0.025
    md.offset = -1.0
    apply_mods(glass)
    # sill rail (slim, follows the glass foot) + rear seal frame
    bmf = bmesh.new()
    for s in (0, -1):
        frames = []
        for y in canopy_ys()[:-1]:
            arc = canopy_arc(y)
            p = arc[0] if s == 0 else arc[-1]
            side = 1 if s == 0 else -1
            frames.append((p + Vector((side * 0.01, 0, 0.02)), Vector((side, 0, 0.25)), Vector((0, 0, 1))))
        sweep(bmf, frames, 0.022, 0.03, DARK)
    arc = canopy_arc(CANOPY_Y0 + 0.02, lift=0.006)
    frames = []
    for i, p in enumerate(arc):
        q = arc[min(i + 1, len(arc) - 1)] - arc[max(i - 1, 0)]
        out = Vector((0, 1, 0)).cross(q).normalized()
        if out.z < -0.2 or (abs(out.z) < 0.2 and out.x * p.x < 0):
            out = -out
        frames.append((p, Vector((0, 1, 0)), out))
    sweep(bmf, frames, 0.06, 0.035, DARK)
    frame = obj_from_bm("CanopyFrame", bmf)
    bevel(frame, width=0.006, segs=1, angle=40)
    ob = join([glass, frame], "Canopy")
    hinge = Vector((0, CANOPY_Y0 + 0.02, CT(CANOPY_Y0) - 0.03))
    ob.data.transform(Matrix.Translation(-hinge))
    ob.location = hinge
    ob["open_deg"] = CANOPY_OPEN_DEG
    ob["axis"] = "x"
    return ob


# ----------------------------------------------------------------------------------------------
# Hatch (boarding ramp in the keel)
# ----------------------------------------------------------------------------------------------
def build_hatch():
    bm = bmesh.new()
    yc = (HATCH_Y0 + HATCH_Y1) / 2
    ln = HATCH_Y1 - HATCH_Y0 - 0.03
    hw = HATCH_HALF_W - 0.015
    add_box(bm, (0, yc, KEEL_Z + 0.06), (hw * 2, ln, 0.12), HULL)
    # walkway (inner face, visible when open): treads + glowing side rails
    for i in range(10):
        y = lerp(HATCH_Y0 + 0.3, HATCH_Y1 - 0.25, i / 9)
        add_box(bm, (0, y, KEEL_Z + 0.13), (hw * 1.5, 0.06, 0.03), DARK)
    for sx in (-1, 1):
        add_box(bm, (sx * (hw - 0.07), yc, KEEL_Z + 0.15), (0.06, ln - 0.2, 0.06), EMIT)
        add_box(bm, (sx * (hw - 0.02), yc, KEEL_Z + 0.20), (0.04, ln - 0.1, 0.14), TRIM)
    hatch = obj_from_bm("Hatch", bm)
    bevel(hatch, width=0.01, segs=1, angle=35)
    hinge = Vector((0, HATCH_Y0 + 0.03, KEEL_Z + 0.06))
    hatch.data.transform(Matrix.Translation(-hinge))
    hatch.location = hinge
    L = ln
    t = 0.12
    drop = hinge.z - GROUND_Z
    best = 0
    for d10 in range(0, 900):
        a = math.radians(d10 / 10)
        if L * math.sin(a) + t * math.cos(a) >= drop:
            best = d10 / 10
            break
    hatch["open_deg"] = -best
    hatch["axis"] = "x"
    return hatch, best


# ----------------------------------------------------------------------------------------------
# Landing gear: telescoping legs + sliding bay doors
# ----------------------------------------------------------------------------------------------
def build_gear(name, cx, cy, belly_fn, pad_r, r0, bay_half, bay_depth, slide_axis):
    """Returns (stage objects [lowest first], door objects, bay cutter, static mount object).
    Rest pose = deployed. Stage k (1..n) rises travel*k/n when stowed; the lowest stage carries the pad."""
    zb = belly_fn(cx, cy)
    ztop = zb + bay_depth
    pad_t = 0.16
    stow_pad = zb + 0.085           # pad bottom when stowed (just above the closed doors)
    travel = stow_pad - GROUND_Z
    stack_bot = stow_pad + pad_t + 0.10
    seg_len = ztop - 0.05 - stack_bot
    n = max(2, int(math.ceil(travel / (seg_len - 0.16))))
    radii = [r0 * (1.0 - 0.12 * k) for k in range(n + 1)]
    objs = []
    # fixed mount (in the bay ceiling) + outer sleeve
    bmm = bmesh.new()
    add_box(bmm, (cx, cy, ztop - 0.06), (bay_half * 1.6, bay_half * 1.2, 0.1), DARK)
    add_cyl(bmm, (cx, cy, ztop - 0.04), (cx, cy, stack_bot + 0.02), radii[0], TRIM, segs=20)
    add_cyl(bmm, (cx, cy, stack_bot + 0.10), (cx, cy, stack_bot), radii[0] + 0.03, DARK, segs=20)
    for ang in (0, 120, 240):
        a = math.radians(ang)
        ox, oy = math.cos(a) * (radii[0] + 0.05), math.sin(a) * (radii[0] + 0.05)
        add_cyl(bmm, (cx + ox, cy + oy, ztop - 0.08), (cx + ox, cy + oy, stack_bot + 0.12), 0.022, DARK, segs=6)
    # bay light
    add_box(bmm, (cx, cy + bay_half * 0.55, ztop - 0.115), (bay_half * 0.9, 0.05, 0.02), LAMP)
    mount = obj_from_bm(name + "_Mount", bmm)
    # telescoping stages, modelled at their deployed position
    for k in range(1, n + 1):
        dz = -travel * k / n
        bm = bmesh.new()
        r = radii[k]
        top = ztop - 0.08 - 0.02 * k + dz
        bot = stack_bot + dz if k < n else stow_pad + pad_t + dz
        add_cyl(bm, (0, 0, top), (0, 0, bot + (0.08 if k < n else 0.2)), r, TRIM, segs=20)
        if k < n:
            add_cyl(bm, (0, 0, bot + 0.1), (0, 0, bot), r + 0.025, DARK, segs=20)    # gland collar
        else:
            zp = stow_pad + dz                                                        # pad bottom
            # ankle: fork + ball
            add_cyl(bm, (0, 0, zp + pad_t + 0.24), (0, 0, zp + pad_t + 0.08), r + 0.04, DARK, segs=20)
            add_sphere(bm, (0, 0, zp + pad_t + 0.06), r * 0.95, TRIM, segs=16, rings=10)
            # pad: octagonal foot with a chamfered rim and gussets
            add_cyl(bm, (0, 0, zp), (0, 0, zp + 0.07), pad_r, DARK, segs=8, r2=pad_r * 0.97)
            add_cyl(bm, (0, 0, zp + 0.07), (0, 0, zp + pad_t), pad_r * 0.96, HULL, segs=8, r2=pad_r * 0.7)
            for g in range(4):
                a = math.radians(45 + g * 90)
                d = Vector((math.cos(a), math.sin(a), 0))
                p0 = Vector((0, 0, zp + pad_t)) + d * (r * 0.9)
                p1 = Vector((0, 0, zp + 0.08)) + d * (pad_r * 0.8)
                add_cyl(bm, p0, p1, 0.03, TRIM, segs=6)
            # contact marker paint ring / light
            if name == "GearFront":
                add_cyl(bm, (0, -r - 0.03, zp + pad_t + 0.45), (0, -r - 0.07, zp + pad_t + 0.45), 0.055, LAMP, segs=12)
        nm = name if k == n else "%s_S%d" % (name, k)
        ob = obj_from_bm(nm, bm, location=(cx, cy, 0.0))
        bevel(ob, width=0.006, segs=1, angle=40)
        ob["travel"] = round(travel * k / n, 4)
        objs.append(ob)
    objs.reverse()  # lowest (named `name`) first
    # bay cutter (rounded square opening)
    bmc = bmesh.new()
    rings = []
    for z in (zb - 0.5, ztop):
        rings.append(superellipse_ring(cx, 0, bay_half, bay_half, 5.0, 0, count=32))
        for v in rings[-1]:
            v.y, v.z = cy + (v.z - 0), z
    loft(bmc, rings, DARK)
    cut = obj_from_bm(name + "_BayCut", bmc)
    # sliding doors (closed rest pose), flush with the skin
    doors = []
    gap = 0.012
    for half in (1, -1):
        bmd = bmesh.new()
        nu, nv = 8, 6
        grid_o, grid_i = [], []
        for i in range(nu + 1):
            row_o, row_i = [], []
            for j in range(nv + 1):
                u = lerp(-bay_half + gap, bay_half - gap, i / nu)
                v = lerp(gap * 0.5, bay_half - gap, j / nv) * half
                # u runs across the slide axis, v along it
                if slide_axis == 'x':
                    x, y = cx + v, cy + u
                else:
                    x, y = cx + u, cy + v
                # clip the square to the rounded opening (superellipse n=5)
                rx, ry = (x - cx) / bay_half, (y - cy) / bay_half
                rr = (abs(rx) ** 5 + abs(ry) ** 5) ** 0.2
                if rr > 0.985:
                    k = 0.985 / rr
                    x, y = cx + (x - cx) * k, cy + (y - cy) * k
                z = belly_fn(x, y)
                row_o.append(bmd.verts.new((x, y, z)))
                row_i.append(bmd.verts.new((x, y, z + 0.045)))
            grid_o.append(row_o)
            grid_i.append(row_i)
        for i in range(nu):
            for j in range(nv):
                bmd.faces.new((grid_o[i][j], grid_o[i + 1][j], grid_o[i + 1][j + 1], grid_o[i][j + 1])).material_index = HULL
                bmd.faces.new((grid_i[i][j], grid_i[i][j + 1], grid_i[i + 1][j + 1], grid_i[i + 1][j])).material_index = DARK
        # rims
        border = ([(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] +
                  [(i, nv) for i in range(nu, 0, -1)] + [(0, j) for j in range(nv, 0, -1)])
        for idx in range(len(border)):
            a = border[idx]
            b = border[(idx + 1) % len(border)]
            bmd.faces.new((grid_o[a[0]][a[1]], grid_i[a[0]][a[1]], grid_i[b[0]][b[1]], grid_o[b[0]][b[1]])).material_index = DARK
        tag = {"GearFront": "F", "GearRearL": "RL", "GearRearR": "RR"}[name]
        side_tag = ("R" if half > 0 else "L") if slide_axis == 'x' else ("Fwd" if half > 0 else "Aft")
        dn = "BayDoor_%s_%s" % (tag, side_tag)
        door = obj_from_bm(dn, bmd)
        # slide outward along the axis, after lifting into the skin (Godot coordinates)
        d = bay_half + 0.03
        if slide_axis == 'x':
            door["slide"] = [round(d * half, 4), 0.0, 0.0]
        else:
            door["slide"] = [0.0, 0.0, round(-d * half, 4)]   # Blender +Y = Godot -Z
        door["lift"] = 0.07
        doors.append(door)
    return objs, doors, cut, mount, travel


# ----------------------------------------------------------------------------------------------
# Vertex data: R = convex edge, G = cavity, B = ambient visibility (1 = open)
# ----------------------------------------------------------------------------------------------
def bake_vertex_data(objs, occluders):
    random.seed(SEED)
    verts_all, polys_all = [], []
    for ob in occluders:
        mw = ob.matrix_world
        base = len(verts_all)
        verts_all.extend(mw @ v.co for v in ob.data.vertices)
        polys_all.extend([base + i for i in p.vertices] for p in ob.data.polygons)
    bvh = BVHTree.FromPolygons(verts_all, polys_all, epsilon=0.0)
    dirs = []
    n_rays = 24
    for i in range(n_rays):  # cosine-weighted hemisphere (z-up)
        u, v = (i + 0.5) / n_rays, (i * 0.618034) % 1.0
        r = math.sqrt(u)
        phi = 2 * math.pi * v
        dirs.append(Vector((r * math.cos(phi), r * math.sin(phi), math.sqrt(max(0.0, 1 - u)))))
    maxd = 1.8
    for ob in objs:
        me = ob.data
        mw = ob.matrix_world
        mn = mw.to_3x3().inverted().transposed()
        bm = bmesh.new()
        bm.from_mesh(me)
        bm.verts.ensure_lookup_table()
        conv = [0.0] * len(bm.verts)
        for v in bm.verts:
            if not v.link_edges:
                continue
            acc = 0.0
            for e in v.link_edges:
                o = e.other_vert(v)
                d = v.co - o.co
                ln = d.length
                if ln > 1e-6:
                    acc += v.normal.dot(d) / ln
            conv[v.index] = acc / len(v.link_edges)
        sm = conv[:]
        for v in bm.verts:
            if v.link_edges:
                s = sum(conv[e.other_vert(v).index] for e in v.link_edges)
                sm[v.index] = 0.5 * conv[v.index] + 0.5 * s / len(v.link_edges)
        vis = [1.0] * len(bm.verts)
        for v in bm.verts:
            n = (mn @ v.normal).normalized()
            if n.length < 0.5:
                continue
            p = mw @ v.co + n * 0.01
            q = n.to_track_quat('Z', 'Y').to_matrix()
            occ = 0.0
            for d in dirs:
                hit = bvh.ray_cast(p, q @ d, maxd)
                if hit[0] is not None:
                    occ += 1.0 - (hit[3] / maxd) ** 0.7
            vis[v.index] = 1.0 - occ / n_rays
        bm.free()
        attr = me.color_attributes.new("Color", 'FLOAT_COLOR', 'POINT')
        for i in range(len(me.vertices)):
            c = sm[i]
            r = min(max((c - 0.03) / 0.35, 0.0), 1.0)
            g = min(max((-c - 0.03) / 0.35, 0.0), 1.0)
            attr.data[i].color = (r, g, vis[i], 1.0)
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = 0


# ----------------------------------------------------------------------------------------------
# Collision helper output (Godot coordinates)
# ----------------------------------------------------------------------------------------------
def godot_pts(pts):
    return ", ".join("%.3f, %.3f, %.3f" % (p.x, p.z, -p.y) for p in pts)


def write_shapes(path, travel):
    hull_pts = []
    for y in (TAIL_Y, -4.0, 0.0, 3.0, 6.0, 8.5, 10.0, NOSE_Y):
        half = hull_half(y)
        for i in (0, 3, 5, CHINE_I, 11, 13, len(half) - 1):
            x, z = half[i]
            hull_pts.append(Vector((x, y, z)))
            if x > 1e-3:
                hull_pts.append(Vector((-x, y, z)))
    keel = []
    for y in (KEEL_Y0, KEEL_Y1):
        for x in (-1.38, 1.38):
            keel.append(Vector((x, y, KEEL_Z)))
            keel.append(Vector((x * 1.15, y, hull_belly_z(0, y) + 0.2)))
    with open(path, "w") as f:
        f.write("hull: %s\n" % godot_pts(hull_pts))
        f.write("keel: %s\n" % godot_pts(keel))
        w = []
        for t in (0.0, 1.04):
            le, te, th = rad_chord(min(t, 1.0))
            for along in (0.0, 1.0):
                p, n, sp, h = rad_frame(1, t, along)
                p.y = le + 0.35 if along == 0.0 and t > 1 else p.y
                w += [p + n * (h + 0.05), p - n * (h + 0.05)]
        f.write("wingR: %s\n" % godot_pts(w))
        f.write("pod centre x=%.2f z=%.2f y=[%.2f, %.2f] half=(%.2f, %.2f)\n" % (
            POD_X, POD_Z, POD_REAR_Y - NOZZLE_LEN, POD_FRONT_Y, PA(-5), PB(-5)))
        f.write("gear travel %s\n" % travel)


# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else "assets/models/ship.glb"
    blend_out = argv[argv.index("--blend") + 1] if "--blend" in argv else None
    shapes_out = argv[argv.index("--shapes") + 1] if "--shapes" in argv else None

    bpy.ops.wm.read_factory_settings(use_empty=True)
    MATERIALS.extend(make_materials())

    body = build_hull()
    for part in (build_spine(), build_pods(), build_wings(), build_keel(), build_wingtip_caps()):
        boolean(body, part, 'UNION')
        remove(part)
    for cutter in (build_cockpit_cutter(), build_pocket_cutter()):
        boolean(body, cutter, 'DIFFERENCE')
        remove(cutter)

    gears, doors, mounts, travels = [], [], [], {}
    specs = [("GearFront", 0.0, GEAR_FRONT_Y, lambda x, y: hull_belly_z(x, y), 0.44, 0.20, 0.52, 1.08, 'x')]
    for side, nm in ((1, "GearRearR"), (-1, "GearRearL")):
        cx = POD_X * side
        specs.append((nm, cx, GEAR_REAR_Y, lambda x, y, c=cx: pod_belly_z(abs(x), y, abs(c)), 0.60, 0.25, 0.66, 1.18, 'y'))
    for (nm, cx, cy, fn, pad_r, r0, bh, depth, axis) in specs:
        st, dr, cut, mount, travel = build_gear(nm, cx, cy, fn, pad_r, r0, bh, depth, axis)
        boolean(body, cut, 'DIFFERENCE')
        remove(cut)
        gears += st
        doors += dr
        mounts.append(mount)
        travels[nm] = travel
    bevel(body)

    noz = build_nozzles()
    bevel(noz, width=0.012, segs=2, angle=35)
    det = build_details()
    bevel(det, width=0.006, segs=1, angle=40)
    for m in mounts:
        bevel(m, width=0.006, segs=1, angle=40)
    hull = join([body, noz, det] + mounts, "Hull")

    cockpit = build_cockpit_interior()
    canopy = build_canopy()
    hatch, hatch_deg = build_hatch()

    meshes = [hull, canopy, hatch, cockpit] + gears + doors
    for ob in meshes:
        finalize_normals(ob, sharp_deg=70.0 if ob.name == "Canopy" else 46.0)
        ensure_uv(ob)
    # AO: everything occludes (gear in the deployed pose, doors closed)
    bake_vertex_data(meshes, meshes)

    # ---------------- markers ----------------
    for side, nm in ((1, "EngineExhaust_R"), (-1, "EngineExhaust_L")):
        empty(nm, (POD_X * side, POD_REAR_Y - NOZZLE_LEN - 0.05, POD_Z), direction=(0, -1, 0),
              extras={"radius": round(PA(POD_REAR_Y) * 0.72, 3), "kind": "main"})
    empty("EngineExhaust_C", (0, TAIL_Y - 0.45, 0.12), direction=(0, -1, 0), extras={"radius": 0.3, "kind": "aux"})
    for (p, n), nm in zip(rcs_points(), RCS_NAMES):
        empty(nm, Vector(p) + Vector(n).normalized() * 0.06, direction=n, size=0.15)
    for nm, p in nav_points().items():
        empty(nm, p, size=0.1)
    for nm, p, d in flood_points() + deck_light_points() + flank_light_points():
        empty(nm, p + d.normalized() * 0.04, direction=d, size=0.2)
    empty("CockpitLight", (0, SEAT_Y + 0.6, 1.55), size=0.1)
    empty("PilotSeat", (0, SEAT_Y + 0.1, COCKPIT_FLOOR + 0.46), size=0.3)
    empty("PilotEye", (0, SEAT_Y + 0.02, COCKPIT_FLOOR + 1.16), size=0.15)
    ramp_tip_y = HATCH_Y0 + (HATCH_Y1 - HATCH_Y0) * math.cos(math.radians(hatch_deg))
    empty("ExitPoint", (0, ramp_tip_y + 0.9, GROUND_Z), size=0.5)
    empty("GroundPoint", (0, 0, GROUND_Z), size=0.5)
    cam_pos = Vector((0, -20.0, 4.4))
    look = (Vector((0, 2.0, 0.8)) - cam_pos).normalized()
    empty("CameraChase", cam_pos, direction=look, size=0.6)

    tris = 0
    for ob in meshes:
        ob.data.calc_loop_triangles()
        tris += len(ob.data.loop_triangles)
        print("[ship] %-16s tris=%d" % (ob.name, len(ob.data.loop_triangles)))
    print("[ship] TOTAL tris=%d  hatch_open=%.1f deg  gear travel=%s" % (tris, -hatch_deg, travels))
    feet = [(0.0, GEAR_FRONT_Y), (-POD_X, GEAR_REAR_Y), (POD_X, GEAR_REAR_Y)]
    print("[ship] FEET (Godot): " + ", ".join("Vector3(%.2f, %.2f, %.2f)" % (x, GROUND_Z - 0.15, -y) for x, y in feet))
    if shapes_out:
        write_shapes(shapes_out, travels)

    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=blend_out)
    for o in bpy.context.view_layer.objects:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_yup=True, export_apply=True,
                              export_extras=True, export_vertex_color='ACTIVE', export_normals=True,
                              export_tangents=False, export_materials='EXPORT', export_cameras=False,
                              export_lights=False, export_image_format='NONE')
    print("[ship] exported", out)


main()
