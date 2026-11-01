"""Stellar Drift player ship "SD-7 Kestrel" -- fully procedural hard-surface model.

Run:
    blender -b -P tools/blender/ship.py -- assets/models/ship.glb [--blend out.blend]

Axis convention
---------------
Blender (build space):  +X = right (starboard), +Y = forward (nose), +Z = up.
glTF / Godot (export):  +X = right, +Y = up, -Z = forward.  (glTF exporter "+Y up": (x, y, z)_b -> (x, z, -y)_g)
So the nose points to Godot -Z, i.e. the ship faces the same way as a default Godot Camera3D / Node3D.

Origin = rough centre of mass, on the fuselage axis. Ground contact (gear pads) is at Z = GROUND_Z
(Godot Y = GROUND_Z) when the gear is deployed.

Markers (empties) are oriented so that their local Godot -Z ("forward") points along the thing they emit:
  EngineExhaust_*  -Z = plume direction (ship backward, Godot +Z)
  Thruster_*       -Z = RCS jet direction (outwards from the hull)
  NavLight_*, PilotSeat, PilotEye, ExitPoint, GroundPoint: identity (ship orientation)
  CameraChase      a Camera3D-style transform (looks along its -Z, toward the ship)

Animated parts (separate objects, origin = hinge, rest pose = gear DOWN / hatch CLOSED / canopy CLOSED):
  GearFront  retract = rotate local X by -90 deg (folds back)    -> extras "retract_deg"
  GearRearL/R retract = rotate local X by +90 deg (fold forward)
  Hatch      open    = rotate local X by HATCH_OPEN_DEG (negative, front edge drops to the ground)
  Canopy     open    = rotate local X by +CANOPY_OPEN_DEG (front lifts)
The same values are exported as glTF extras (Godot node metadata "extras").
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
# Parameters (meters). Key proportions -- tweak here.
# ----------------------------------------------------------------------------------------------
NOSE_Y = 10.30            # nose tip
TAIL_Y = -8.4             # fuselage rear bulkhead
FUSE_HALF_W = 1.60        # max fuselage half width
FUSE_TOP = 1.05           # max fuselage height above chine line
FUSE_BOTTOM = 0.88        # max fuselage depth below chine line

NAC_X = 2.80              # engine nacelle centre offset
NAC_Z = -0.05
NAC_HALF_W = 0.95
NAC_HALF_H = 0.84
NAC_FRONT_Y = -0.6
NAC_REAR_Y = -8.6
NOZZLE_LEN = 1.25

WING_ROOT_X = 1.0
WING_TIP_X = 6.9
WING_ROOT_LE_Y = 2.6
WING_TIP_LE_Y = -4.4
WING_ROOT_TE_Y = -5.8
WING_TIP_TE_Y = -6.7
WING_Z = -0.28
WING_DROP = 1.2           # downturned wing-tip fin length

FIN_CANT_DEG = 34.0
FIN_HEIGHT = 1.95

GROUND_Z = -2.95          # gear pad contact plane
GEAR_FRONT_Y = 6.3
GEAR_REAR_Y = -4.5
GEAR_HINGE_DEPTH = 0.42   # hinge height above the local belly

HATCH_Y0, HATCH_Y1 = 0.2, 3.6   # belly ramp (aft hinge at Y0)
HATCH_HALF_W = 0.70

CANOPY_Y0, CANOPY_Y1 = 2.35, 7.35
CANOPY_OPEN_DEG = 32.0

BEVEL_W = 0.022
SEED = 7

# Material slots (fixed order on every object)
MATS = ["Hull", "HullDark", "Trim", "Glass", "Emissive", "EngineInner"]
HULL, DARK, TRIM, GLASS, EMIT, ENGINE = range(6)
MAT_PREVIEW = {  # base colours for non-Godot viewers (Godot overrides these)
    "Hull": ((0.72, 0.73, 0.74, 1), 0.2, 0.45),
    "HullDark": ((0.05, 0.055, 0.06, 1), 0.4, 0.5),
    "Trim": ((0.55, 0.55, 0.57, 1), 1.0, 0.3),
    "Glass": ((0.03, 0.035, 0.04, 1), 0.0, 0.05),
    "Emissive": ((0.3, 0.8, 1.0, 1), 0.0, 0.5),
    "EngineInner": ((1.0, 0.6, 0.3, 1), 0.0, 0.5),
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


def rot_x(deg):
    return Matrix.Rotation(math.radians(deg), 4, 'X')


# ----------------------------------------------------------------------------------------------
# Profiles
# ----------------------------------------------------------------------------------------------
FW = pchip([(-8.4, 1.36), (-6.0, 1.50), (-2.0, FUSE_HALF_W), (1.0, FUSE_HALF_W), (3.0, 1.57), (5.0, 1.48),
            (6.5, 1.38), (8.0, 1.20), (9.0, 1.00), (9.7, 0.74), (10.1, 0.44), (10.3, 0.14)])
FHT = pchip([(-8.4, 0.70), (-6.0, 0.90), (-3.0, 1.00), (0.0, FUSE_TOP), (2.5, 0.98), (4.5, 0.87), (6.5, 0.69),
             (8.0, 0.50), (9.0, 0.36), (9.7, 0.23), (10.3, 0.07)])
FHB = pchip([(-8.4, 0.62), (-6.0, 0.82), (-2.0, FUSE_BOTTOM), (2.0, FUSE_BOTTOM), (5.0, 0.82), (7.0, 0.66),
             (8.5, 0.44), (9.3, 0.30), (9.9, 0.17), (10.3, 0.05)])
FCH = pchip([(-8.4, 0.04), (-3.0, 0.10), (1.0, 0.17), (5.0, 0.18), (8.5, 0.17), (9.8, 0.10), (10.3, 0.02)])  # chine blade
FZC = pchip([(-8.4, 0.05), (0.0, 0.0), (6.0, -0.05), (9.0, -0.09), (10.3, -0.12)])
FNT = pchip([(-8.4, 2.8), (0.0, 2.6), (6.0, 2.5), (10.3, 2.3)])
FMB = pchip([(-8.4, 3.6), (0.0, 3.6), (7.0, 3.2), (10.3, 2.6)])

NA = pchip([(NAC_REAR_Y, 0.80), (-7.6, 0.85), (-4.0, NAC_HALF_W), (-1.6, 0.85), (NAC_FRONT_Y, 0.79)])
NB = pchip([(NAC_REAR_Y, 0.70), (-7.6, 0.75), (-4.0, NAC_HALF_H), (-1.6, 0.75), (NAC_FRONT_Y, 0.71)])
NAC_N = 3.2

CW = pchip([(CANOPY_Y0, 0.40), (3.0, 0.76), (4.0, 0.86), (5.2, 0.85), (6.3, 0.70), (7.0, 0.44), (CANOPY_Y1, 0.08)])
CT = pchip([(CANOPY_Y0, 1.19), (3.1, 1.42), (4.2, 1.50), (5.3, 1.43), (6.3, 1.18), (7.0, 0.93), (CANOPY_Y1, 0.76)])
SPINE_T = pchip([(-7.7, 0.88), (-6.0, 1.08), (-3.0, 1.19), (0.5, 1.23), (CANOPY_Y0 + 0.1, 1.21)])


def spow(v, e):
    return math.copysign(abs(v) ** e, v)


def fuse_top_z(x, y):
    """Fuselage upper surface height at (x, y) (|x| < half width)."""
    w, ht, zc, nt = FW(y), FHT(y), FZC(y), FNT(y)
    r = min(abs(x) / w, 1.0)
    lip = 0.07
    return zc + lip + (ht - lip) * (1.0 - r ** nt) ** (1.0 / nt)


def fuse_belly_z(x, y):
    w, hb, zc, mb = FW(y), FHB(y), FZC(y), FMB(y)
    u = min(abs(x) / w, 1.0)
    return zc - hb * (1.0 - u ** mb)


def nac_belly_z(dx, y):
    a, b = NA(y), NB(y)
    r = min(abs(dx) / a, 1.0)
    return NAC_Z - b * (1.0 - r ** NAC_N) ** (1.0 / NAC_N)


def fuse_ring(y, nb=7, nt=13):
    w, ht, hb, zc, ent, mb = FW(y), FHT(y), FHB(y), FZC(y), FNT(y), FMB(y)
    ext = FCH(y)
    lip = 0.07
    right = []
    for i in range(nb + 1):
        u = 1.0 - (1.0 - i / nb) ** 1.4
        right.append((w * u, zc - hb * (1.0 - u ** mb)))
    right.append((w + ext, zc + 0.025))  # chine blade tip
    for j in range(0, nt + 1):
        a = j / nt * math.pi / 2
        right.append((w * math.cos(a) ** (2 / ent), zc + lip + (ht - lip) * math.sin(a) ** (2 / ent)))
    left = [(-x, z) for (x, z) in reversed(right[1:-1])]
    return [Vector((x, y, z)) for (x, z) in right + left]


def superellipse_ring(cx, cz, a, b, n, y, count=32, y_shear=0.0):
    pts = []
    for i in range(count):
        t = i / count * 2 * math.pi
        x = cx + a * spow(math.cos(t), 2 / n)
        z = cz + b * spow(math.sin(t), 2 / n)
        pts.append(Vector((x, y + y_shear * (z - cz) / max(b, 1e-6), z)))
    return pts


def airfoil(c, t):
    """Faceted hard-surface section in (chord, normal) offsets: LE at 0, TE at -c."""
    up = [(0.0, 0.0), (-0.10 * c, 0.32 * t), (-0.32 * c, 0.5 * t), (-0.68 * c, 0.42 * t), (-c, 0.04 * t)]
    lo = [(-0.68 * c, -0.40 * t), (-0.32 * c, -0.48 * t), (-0.10 * c, -0.30 * t)]
    return up + lo


# ----------------------------------------------------------------------------------------------
# bmesh builders
# ----------------------------------------------------------------------------------------------
def tag_new(bm, before_faces, mat):
    for f in bm.faces:
        if f.index == -2:  # never
            pass
    for f in set(bm.faces) - before_faces:
        f.material_index = mat


def loft(bm, rings, mat, cap0=True, cap1=True, seg_mat=None, pole0=None, pole1=None, closed=True, cap_mats=None):
    """Stitch equal-sized rings. seg_mat(i) -> material for the band between ring i and i+1."""
    vrings = [[bm.verts.new(p) for p in r] for r in rings]
    n = len(rings[0])
    cm0 = cap_mats[0] if cap_mats else mat
    cm1 = cap_mats[1] if cap_mats else mat
    for i in range(len(vrings) - 1):
        a, b = vrings[i], vrings[i + 1]
        m = seg_mat(i) if seg_mat else mat
        rng = range(n) if closed else range(n - 1)
        for j in rng:
            k = (j + 1) % n
            f = bm.faces.new((a[j], a[k], b[k], b[j]))
            f.material_index = m
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
            if name in ("Emissive", "EngineInner"):
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
    for o in bpy.context.view_layer.objects:
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


def smart_uv(ob):
    activate(ob)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.002, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode='OBJECT')


def empty(name, loc, direction=None, rot=None, size=0.3, extras=None):
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
    return ob


# ----------------------------------------------------------------------------------------------
# Parts
# ----------------------------------------------------------------------------------------------
def station_ys():
    ys = []
    y = TAIL_Y
    while y < NOSE_Y - 0.04:
        ys.append(y)
        step = 0.42 if y < 7.0 else (0.24 if y < 10.0 else 0.12)
        y += step
    ys.append(NOSE_Y - 0.03)
    return ys


def build_fuselage():
    bm = bmesh.new()
    rings = [fuse_ring(y) for y in station_ys()]
    loft(bm, rings, HULL, cap0=True, pole1=Vector((0, NOSE_Y + 0.04, FZC(NOSE_Y) + 0.0)), cap_mats=(DARK, HULL))
    return obj_from_bm("Fuselage", bm)


def build_wings():
    bm = bmesh.new()
    for side in (1, -1):
        rings = []
        nst = 9
        for i in range(nst + 1):
            t = i / nst
            x = lerp(WING_ROOT_X, WING_TIP_X, t)
            le = lerp(WING_ROOT_LE_Y, WING_TIP_LE_Y, t)
            te = lerp(WING_ROOT_TE_Y, WING_TIP_TE_Y, t)
            th = lerp(0.40, 0.13, t ** 0.8)
            z = WING_Z + 0.06 * t
            rings.append((Vector((x, 0, z)), le, le - te, th, 0.0))
        # downturned tip fin: arc then straight
        tip = rings[-1]
        cx, cz = WING_TIP_X, WING_Z + 0.06
        rad = 0.45
        for k, phi in enumerate((22, 45, 68, 84)):
            p = math.radians(phi)
            x = cx + rad * math.sin(p)
            z = cz - rad + rad * math.cos(p)
            le = WING_TIP_LE_Y - 0.25 * (k + 1)
            c = tip[2] * (1.0 - 0.06 * (k + 1))
            rings.append((Vector((x, 0, z)), le, c, tip[3] * 0.9, p))
        last = rings[-1]
        p = math.radians(86)
        for s in (0.45, WING_DROP - 0.4):
            pos = last[0] + Vector((math.cos(p), 0, -math.sin(p))) * 0 + Vector((math.sin(math.radians(4)), 0, -1)) * s
            rings.append((pos, last[1] - 0.55 * s, last[2] * (1.0 - 0.3 * s / WING_DROP), last[3] * 0.85, p))
        geo = []
        for (c, le, chord, th, phi) in rings:
            n = Vector((math.sin(phi), 0, math.cos(phi)))
            ring = []
            for (dy, dn) in airfoil(chord, th):
                p = Vector((c.x, le + dy, c.z)) + n * dn
                ring.append(Vector((p.x * side, p.y, p.z)))
            geo.append(ring)
        loft(bm, geo, HULL, seg_mat=lambda i: DARK if i >= nst else HULL)
    return obj_from_bm("Wings", bm)


def build_nacelles():
    bm = bmesh.new()
    for side in (1, -1):
        cx = NAC_X * side
        ys = [NAC_REAR_Y + i * (NAC_FRONT_Y - NAC_REAR_Y) / 22 for i in range(23)]
        rings = [superellipse_ring(cx, NAC_Z, NA(y), NB(y), NAC_N, y, y_shear=0.0) for y in ys]
        # slanted intake lip: top further forward
        shear = 0.35
        lip = superellipse_ring(cx, NAC_Z, NA(NAC_FRONT_Y) * 0.99, NB(NAC_FRONT_Y) * 0.99, NAC_N,
                                NAC_FRONT_Y + 0.08, y_shear=shear)
        rings[-1] = superellipse_ring(cx, NAC_Z, NA(NAC_FRONT_Y), NB(NAC_FRONT_Y), NAC_N, NAC_FRONT_Y, y_shear=shear * 0.85)
        inner0 = superellipse_ring(cx, NAC_Z, NA(NAC_FRONT_Y) * 0.80, NB(NAC_FRONT_Y) * 0.76, NAC_N,
                                   NAC_FRONT_Y + 0.02, y_shear=shear * 0.8)
        inner1 = superellipse_ring(cx, NAC_Z, NA(NAC_FRONT_Y) * 0.76, NB(NAC_FRONT_Y) * 0.72, NAC_N,
                                   NAC_FRONT_Y - 0.9, y_shear=0.0)
        rings = rings + [lip, inner0, inner1]
        n_out = len(rings) - 3

        def segm(i, n_out=n_out):
            if i < 4:
                return DARK  # hot section
            return HULL if i < n_out - 1 else (TRIM if i == n_out - 1 or i == n_out else DARK)
        loft(bm, rings, HULL, seg_mat=segm, cap_mats=(DARK, DARK))
    return obj_from_bm("Nacelles", bm)


def build_fins():
    bm = bmesh.new()
    cant = math.radians(FIN_CANT_DEG)
    for side in (1, -1):
        span = Vector((math.sin(cant), 0, math.cos(cant)))
        nrm = Vector((math.cos(cant), 0, -math.sin(cant)))
        root = Vector((NAC_X, 0, NAC_Z + NAC_HALF_H - 0.18))
        geo = []
        nst = 6
        for i in range(nst + 1):
            t = i / nst
            s = -0.1 + (FIN_HEIGHT + 0.1) * t
            c = root + span * s
            le = lerp(-5.0, -8.3, t ** 0.9)
            chord = lerp(3.8, 1.2, t)
            th = lerp(0.26, 0.08, t)
            ring = []
            for (dy, dn) in airfoil(chord, th):
                p = Vector((c.x, le + dy, c.z)) + nrm * dn
                ring.append(Vector((p.x * side, p.y, p.z)))
            geo.append(ring)
        loft(bm, geo, HULL)
    return obj_from_bm("Fins", bm)


def build_deck():
    """Blended engine deck between fuselage and nacelles (turns the rear into one wide lifting body)."""
    bm = bmesh.new()
    top = pchip([(-8.3, 0.50), (-7.0, 0.58), (-3.2, 0.56), (-1.9, 0.30), (-1.0, WING_Z + 0.12)])
    for side in (1, -1):
        rings = []
        ys = [lerp(-8.3, -1.0, i / 16) for i in range(17)]
        for y in ys:
            zt = top(y)
            xi, xo = 1.0, NAC_X
            ring = [Vector((xi, y, WING_Z - 0.12)), Vector((xo, y, WING_Z - 0.12)), Vector((xo, y, zt)),
                    Vector((lerp(xi, xo, 0.5), y, zt + 0.03)), Vector((xi, y, zt))]
            rings.append([Vector((v.x * side, v.y, v.z)) for v in ring])
        loft(bm, rings, HULL)
    return obj_from_bm("Deck", bm)


def build_spine():
    bm = bmesh.new()
    rings = []
    ys = [-7.7 + i * (CANOPY_Y0 + 0.2 + 7.7) / 24 for i in range(25)]
    for y in ys:
        top = SPINE_T(y)
        base = fuse_top_z(0.5, y) - 0.25
        hw_t = 0.30 if y > -6.5 else lerp(0.18, 0.30, (y + 7.7) / 1.2)
        hw_b = hw_t + 0.16
        rings.append([Vector((hw_b, y, base)), Vector((hw_t, y, top - 0.04)), Vector((hw_t - 0.06, y, top)),
                      Vector((-hw_t + 0.06, y, top)), Vector((-hw_t, y, top - 0.04)), Vector((-hw_b, y, base))])
    loft(bm, rings, DARK)
    return obj_from_bm("Spine", bm)


def build_cannon_pods():
    bm = bmesh.new()
    for side in (1, -1):
        x = 1.78 * side
        z = WING_Z - 0.02
        rings = []
        for y, r in ((-1.2, 0.05), (-0.6, 0.15), (1.0, 0.17), (2.2, 0.15), (2.55, 0.11)):
            rings.append(superellipse_ring(x, z, r, r * 0.9, 2.0, y, count=16))
        loft(bm, rings, DARK)
        add_cyl(bm, (x, 2.4, z), (x, 3.5, z), 0.055, TRIM, segs=12)
        add_cyl(bm, (x, 3.38, z), (x, 3.62, z), 0.075, TRIM, segs=12)
    return obj_from_bm("CannonPods", bm)


def build_canards():
    bm = bmesh.new()
    for side in (1, -1):
        geo = []
        y0 = 7.05
        for i, t in enumerate((0.0, 0.5, 1.0)):
            x = lerp(FW(y0) - 0.15, FW(y0) + 1.15, t)
            le = lerp(y0 + 0.7, y0 - 0.55, t ** 0.9)
            chord = lerp(1.6, 0.55, t)
            th = lerp(0.12, 0.05, t)
            z = FZC(y0) + 0.02 - 0.12 * t
            ring = []
            for (dy, dn) in airfoil(chord, th):
                ring.append(Vector((x * side, le + dy, z + dn)))
            geo.append(ring)
        loft(bm, geo, HULL)
    return obj_from_bm("Canards", bm)


def build_nozzles():
    bm = bmesh.new()
    for side in (1, -1):
        cx = NAC_X * side
        a0, b0 = NA(NAC_REAR_Y), NB(NAC_REAR_Y)
        y0 = NAC_REAR_Y + 0.05
        y1 = NAC_REAR_Y - NOZZLE_LEN
        prof = [  # (y, scale, material of band to next)
            (y0, 0.95, TRIM), (y0 - 0.3, 0.95, TRIM), (y0 - 0.32, 1.0, TRIM), (y0 - 0.5, 1.0, TRIM),
            (y0 - 0.52, 0.97, TRIM), (y1 + 0.12, 1.0, TRIM), (y1, 0.99, TRIM), (y1 - 0.01, 0.86, ENGINE),
            (y1 + 0.5, 0.80, ENGINE), (y0 - 0.25, 0.70, ENGINE),
        ]
        rings = [superellipse_ring(cx, NAC_Z, a0 * s, b0 * s, NAC_N, y) for (y, s, _) in prof]
        loft(bm, rings, TRIM, seg_mat=lambda i, prof=prof: prof[i][2], cap0=True,
             pole1=Vector((cx, y0 - 0.55, NAC_Z)), cap_mats=(TRIM, ENGINE))
        # central plug / spike
        add_cyl(bm, (cx, y0 - 0.5, NAC_Z), (cx, y1 + 0.25, NAC_Z), 0.20, TRIM, segs=16, r2=0.08)
    # centre auxiliary engine in the fuselage tail
    cz = 0.22
    prof = [(TAIL_Y + 0.05, 1.0, TRIM), (TAIL_Y - 0.45, 0.95, TRIM), (TAIL_Y - 0.5, 0.80, ENGINE),
            (TAIL_Y - 0.1, 0.75, ENGINE)]
    rings = [superellipse_ring(0, cz, 0.52 * s, 0.30 * s, 3.0, y, count=28) for (y, s, _) in prof]
    loft(bm, rings, TRIM, seg_mat=lambda i: prof[i][2], pole1=Vector((0, TAIL_Y - 0.05, cz)), cap_mats=(TRIM, ENGINE))
    return obj_from_bm("Nozzles", bm)


def build_details():
    """Small static greebles that are not unioned: emissive strips, RCS blocks, nav housings, antenna."""
    bm = bmesh.new()
    # chine light strips (follow the chine line)
    for side in (1, -1):
        frames = []
        for i in range(17):
            y = lerp(-6.6, 0.8, i / 16)
            frames.append((Vector((side * (FW(y) + 0.004), y, FZC(y) - 0.01)), Vector((side, 0, 0)), Vector((0, 0, 1))))
        sweep(bm, frames, 0.014, 0.018, EMIT)
    # nacelle side strips
    for side in (1, -1):
        y0, y1 = -7.2, -2.2
        frames = []
        for i in range(9):
            y = lerp(y0, y1, i / 8)
            x = side * (NAC_X + NA(y) - 0.004)
            frames.append((Vector((x, y, NAC_Z + 0.22)), Vector((side, 0, 0)), Vector((0, 0, 1))))
        sweep(bm, frames, 0.012, 0.016, EMIT)
    # RCS thruster blocks
    for p, n in rcs_points():
        n = Vector(n)
        rot = n.to_track_quat('Z', 'Y').to_matrix().to_4x4()
        add_box(bm, Vector(p) - n * 0.02, (0.22, 0.22, 0.08), DARK, rot)
        for ox in (-0.05, 0.05):
            off = rot @ Vector((ox, 0, 0))
            add_cyl(bm, Vector(p) + off.to_3d() - n * 0.01, Vector(p) + off.to_3d() + n * 0.035, 0.03, ENGINE, segs=8)
    # nav light housings
    for name, p in nav_points().items():
        add_sphere(bm, p, 0.07, GLASS, segs=10, rings=6)
    # dorsal antenna blade
    y_a = -6.2
    zt = SPINE_T(y_a)
    blade = [[Vector((0.02 * s, y, zt - 0.05)) for s in (1, -1)] for y in (y_a + 0.25, y_a - 0.35)]
    ring0 = [Vector((0.03, y_a + 0.3, zt - 0.05)), Vector((0.03, y_a - 0.3, zt - 0.05)),
             Vector((-0.03, y_a - 0.3, zt - 0.05)), Vector((-0.03, y_a + 0.3, zt - 0.05))]
    ring1 = [Vector((0.012, y_a - 0.05, zt + 0.55)), Vector((0.012, y_a - 0.32, zt + 0.55)),
             Vector((-0.012, y_a - 0.32, zt + 0.55)), Vector((-0.012, y_a - 0.05, zt + 0.55))]
    loft(bm, [ring0, ring1], DARK)
    del blade
    # sensor dome under the nose
    add_sphere(bm, (0, 8.7, fuse_belly_z(0, 8.7) + 0.02), 0.16, GLASS, segs=14, rings=8, scale=(1, 1.4, 0.6))
    # intake splitter vanes (inside intakes)
    for side in (1, -1):
        add_box(bm, (NAC_X * side, NAC_FRONT_Y - 0.4, NAC_Z), (0.04, 0.8, NAC_HALF_H * 1.4), TRIM)
    return obj_from_bm("Details", bm)


def build_cockpit_interior():
    bm = bmesh.new()
    seat_y = 3.85
    # seat
    add_box(bm, (0, seat_y + 0.1, 0.27), (0.56, 0.6, 0.16), DARK)
    back = rot_x(-14)
    add_box(bm, (0, seat_y - 0.24, 0.80), (0.54, 0.14, 0.95), DARK, back)
    add_box(bm, (0, seat_y - 0.38, 1.33), (0.32, 0.14, 0.22), DARK, back)
    add_box(bm, (0, seat_y + 0.05, 0.13), (0.3, 0.5, 0.18), TRIM)
    for sx in (-0.3, 0.3):
        add_box(bm, (sx, seat_y + 0.05, 0.42), (0.07, 0.55, 0.16), TRIM)
    # console
    add_box(bm, (0, 5.35, 0.45), (1.0, 0.7, 0.5), DARK)
    tilt = rot_x(-38)
    add_box(bm, (0, 5.05, 0.75), (0.95, 0.42, 0.06), DARK, tilt)
    for sx in (-0.24, 0.24):
        add_box(bm, (sx, 5.03, 0.78), (0.36, 0.3, 0.02), EMIT, tilt)
    add_box(bm, (0, 4.95, 0.95), (0.3, 0.1, 0.12), EMIT, rot_x(-70))  # HUD combiner glow
    # side consoles
    for sx in (-0.5, 0.5):
        add_box(bm, (sx, 4.3, 0.42), (0.18, 1.3, 0.22), DARK)
        add_box(bm, (sx, 4.4, 0.535), (0.1, 0.4, 0.01), EMIT)
    # stick + throttle
    add_cyl(bm, (0, 4.55, 0.3), (0, 4.6, 0.7), 0.025, TRIM, segs=8)
    add_box(bm, (0, 4.6, 0.73), (0.06, 0.07, 0.1), DARK)
    add_box(bm, (-0.5, 4.1, 0.62), (0.05, 0.12, 0.14), DARK)
    # floor
    add_box(bm, (0, 4.5, 0.06), (1.2, 3.6, 0.08), DARK)
    return obj_from_bm("CockpitInterior", bm)


def canopy_arc(y, k=6, n=2.2, inset=0.0, lift=0.0):
    cw = CW(y) - inset
    zb = fuse_top_z(cw, y) - 0.06
    ct = CT(y) - inset * 0.6 + lift
    pts = []
    for i in range(k + 1):
        a = i / k * math.pi
        x = cw * spow(math.cos(a), 2 / n)
        z = zb + (ct - zb) * abs(math.sin(a)) ** (2 / n)
        pts.append(Vector((x, y, z)))
    return pts


def canopy_ys():
    return [lerp(CANOPY_Y0, CANOPY_Y1 - 0.02, (i / 22) ** 0.95) for i in range(23)]


def build_canopy():
    """Glass shell (open bottom, solidified) + frame bows. Origin at rear hinge."""
    bm = bmesh.new()
    rings = [canopy_arc(y) for y in canopy_ys()]
    tip = Vector((0, CANOPY_Y1, fuse_top_z(0.0, CANOPY_Y1) - 0.02))
    loft(bm, rings, GLASS, closed=False, cap0=False, cap1=False)
    # close the front with a fan to the tip
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me_glass = bm
    glass = obj_from_bm("CanopyGlass", me_glass, recalc=False)
    # make normals point outward (centroid test)
    bm2 = bmesh.new()
    bm2.from_mesh(glass.data)
    ctr = Vector((0, (CANOPY_Y0 + CANOPY_Y1) / 2, 0.4))
    flip = sum((f.normal.dot(f.calc_center_median() - ctr) < 0) for f in bm2.faces) > len(bm2.faces) / 2
    if flip:
        bmesh.ops.reverse_faces(bm2, faces=bm2.faces)
    bm2.to_mesh(glass.data)
    bm2.free()
    md = glass.modifiers.new("solid", 'SOLIDIFY')
    md.thickness = 0.03
    md.offset = -1.0
    apply_mods(glass)
    del tip
    # frames
    bmf = bmesh.new()

    def bow(y, hw, hh):
        arc = canopy_arc(y, lift=0.012)
        frames = []
        for i, p in enumerate(arc):
            q = arc[min(i + 1, len(arc) - 1)] - arc[max(i - 1, 0)]
            out = q.cross(Vector((0, 1, 0))).normalized()
            if out.z < 0 and abs(out.x) < 0.3:
                out = -out
            if i < len(arc) / 2 and out.x < 0:
                out = -out
            frames.append((p, Vector((0, 1, 0)), out))
        sweep(bmf, frames, hw, hh, DARK)
    bow(6.15, 0.05, 0.03)
    bow(3.75, 0.035, 0.025)
    bow(CANOPY_Y0 + 0.04, 0.06, 0.035)
    # base rails
    for s in (0, -1):
        frames = []
        ys = canopy_ys()
        for y in ys:
            arc = canopy_arc(y, lift=0.0)
            p = arc[0] if s == 0 else arc[-1]
            side = 1 if s == 0 else -1
            frames.append((p + Vector((side * 0.012, 0, 0.03)), Vector((side, 0, 0.35)), Vector((0, 0, 1))))
        sweep(bmf, frames, 0.035, 0.045, DARK)
    frame = obj_from_bm("CanopyFrame", bmf)
    bevel(frame, width=0.008, segs=1, angle=40)
    ob = join([glass, frame], "Canopy")
    # origin at the rear hinge
    hinge = Vector((0, CANOPY_Y0 + 0.02, CT(CANOPY_Y0) - 0.02))
    ob.data.transform(Matrix.Translation(-hinge))
    ob.location = hinge
    ob["open_deg"] = CANOPY_OPEN_DEG
    ob["axis"] = "x"
    return ob


def rcs_points():
    """(position, outward jet direction) in Blender space, names in RCS_NAMES."""
    pts = []
    y = 8.35
    pts.append(((FW(y) - 0.02, y, FZC(y) + 0.08), (1, 0, 0)))
    pts.append(((-FW(y) + 0.02, y, FZC(y) + 0.08), (-1, 0, 0)))
    pts.append(((0, y + 0.3, fuse_top_z(0, y + 0.3) - 0.01), (0, 0.15, 1)))
    pts.append(((0, y - 0.4, fuse_belly_z(0, y - 0.4) + 0.01), (0, 0.15, -1)))
    y = -7.75
    for s in (1, -1):
        pts.append(((s * (NAC_X + NA(y) - 0.02), y, NAC_Z - 0.2), (s, 0, 0)))
    for s in (1, -1):
        pts.append(((s * (NAC_X - 0.35), y, NAC_Z + NB(y) * 0.97 - 0.02), (0, 0, 1)))
    for s in (1, -1):
        pts.append(((s * (NAC_X + 0.35), y, NAC_Z - NB(y) * 0.97 + 0.02), (0, 0, -1)))
    return pts


RCS_NAMES = ["Thruster_NoseR", "Thruster_NoseL", "Thruster_NoseUp", "Thruster_NoseDown",
             "Thruster_TailR", "Thruster_TailL", "Thruster_TailUpR", "Thruster_TailUpL",
             "Thruster_TailDownR", "Thruster_TailDownL"]


def nav_points():
    tip_x = WING_TIP_X + 0.45 * math.sin(math.radians(68)) + 0.06
    tip_z = WING_Z + 0.06 - 0.45 + 0.45 * math.cos(math.radians(68))
    tip_y = WING_TIP_LE_Y - 0.9
    zt = SPINE_T(-6.2) + 0.58
    return {"NavLight_R": Vector((tip_x, tip_y, tip_z)), "NavLight_L": Vector((-tip_x, tip_y, tip_z)),
            "NavLight_Top": Vector((0, -6.25, zt))}


# ----------------------------------------------------------------------------------------------
# Gear & hatch
# ----------------------------------------------------------------------------------------------
def build_gear(name, hinge, retract_deg, belly_fn, pad_r, door_hw):
    """Leg modelled DOWN in local space (origin at hinge). A leg door is modelled in the retracted
    pose (flush with the belly) and moved to the deployed pose by the inverse retract rotation."""
    bm = bmesh.new()
    H = Vector(hinge)
    L = H.z - GROUND_Z          # hinge to ground
    pad_h = 0.12
    zpad = -L + pad_h * 0.5
    # trunnion & hinge block
    add_cyl(bm, (-door_hw * 0.8, 0, 0), (door_hw * 0.8, 0, 0), 0.075, TRIM, segs=14)
    add_box(bm, (0, 0, -0.05), (0.32, 0.30, 0.28), DARK)
    # main cylinder + oleo piston
    up_len = L * 0.52
    add_cyl(bm, (0, 0, -0.1), (0, 0, -up_len), 0.13, DARK, segs=18)
    add_cyl(bm, (0, 0, -up_len + 0.05), (0, 0, -up_len - 0.06), 0.15, TRIM, segs=18)  # gland ring
    add_cyl(bm, (0, 0, -up_len), (0, 0, zpad + 0.28), 0.085, TRIM, segs=16)
    # axle fork / ankle
    add_box(bm, (0, 0, zpad + 0.24), (0.26, 0.22, 0.16), DARK)
    add_cyl(bm, (-0.16, 0, zpad + 0.18), (0.16, 0, zpad + 0.18), 0.06, TRIM, segs=12)
    # pad
    add_cyl(bm, (0, 0, zpad - pad_h * 0.5), (0, 0, zpad + pad_h * 0.5), pad_r, DARK, segs=24, r2=pad_r * 0.9)
    add_cyl(bm, (0, 0, zpad + pad_h * 0.5), (0, 0, zpad + pad_h * 0.5 + 0.06), pad_r * 0.55, TRIM, segs=20)
    # torque links (scissor) on the back side
    sgn = 1 if retract_deg < 0 else -1  # side facing the door is +y for a rear-folding leg
    zk = -up_len - 0.02
    zb = zpad + 0.3
    mid = (zk + zb) / 2
    for (za, zb_) in ((zk, mid), (mid, zb)):
        p0 = Vector((0, -sgn * 0.14, za))
        p1 = Vector((0, -sgn * 0.26, (za + zb_) / 2))
        p2 = Vector((0, -sgn * 0.14, zb_))
        for (a, b) in ((p0, p1), (p1, p2)):
            add_cyl(bm, a, b, 0.03, TRIM, segs=6)
    # hydraulic line
    add_cyl(bm, (0.15, 0, -0.1), (0.15, 0, -up_len + 0.1), 0.018, DARK, segs=6)
    # drag/side brace to the door
    d = GEAR_HINGE_DEPTH
    for z in (-0.35, -L * 0.62):
        add_box(bm, (0, sgn * d * 0.5, z), (0.08, d, 0.06), DARK)
    # door (retracted pose: along the belly)
    R = rot_x(retract_deg)
    Rinv = R.inverted()
    door_len = L - 0.55
    seg = 6
    top_rings = []
    for i in range(seg + 1):
        s = lerp(-0.12, door_len, i / seg)
        y = H.y + (s if retract_deg > 0 else -s)
        ring = []
        for (x, dz) in ((door_hw, 0.0), (-door_hw, 0.0), (-door_hw + 0.03, 0.05), (door_hw - 0.03, 0.05)):
            zb2 = belly_fn(x, y) + 0.004 + dz
            ring.append(Rinv @ (Vector((x, y, zb2)) - H))
        top_rings.append(ring)
    loft(bm, top_rings, DARK, cap_mats=(DARK, DARK))
    # landing light on the front gear
    if name == "GearFront":
        add_cyl(bm, (0, sgn * (d + 0.03), -0.6), (0, sgn * (d + 0.08), -0.6), 0.07, EMIT, segs=12)
    ob = obj_from_bm(name, bm, location=H)
    bevel(ob, width=0.008, segs=1, angle=40)
    ob["retract_deg"] = retract_deg
    ob["axis"] = "x"
    # bay cutter (world space): covers the door footprint
    bm_c = bmesh.new()
    s0, s1 = -0.15, door_len + 0.04
    ya = H.y + (s0 if retract_deg > 0 else -s0)
    yb = H.y + (s1 if retract_deg > 0 else -s1)
    yc = (ya + yb) / 2
    zlo = belly_fn(0, yc) - 0.4
    add_box(bm_c, (0, yc, (zlo + H.z + 0.28) / 2), (door_hw * 2 + 0.03, abs(yb - ya), (H.z + 0.28 - zlo)), DARK)
    cut = obj_from_bm(name + "_BayCut", bm_c)
    cut.location.x = H.x
    return ob, cut


def build_hatch_and_cutters(fuselage):
    belly = fuse_belly_z(0, HATCH_Y0)
    # hatch slab = fuselage ∩ box
    hatch = fuselage.copy()
    hatch.data = fuselage.data.copy()
    hatch.name = "Hatch"
    bpy.context.scene.collection.objects.link(hatch)
    zmax = fuse_belly_z(0, (HATCH_Y0 + HATCH_Y1) / 2) + 0.16
    bm = bmesh.new()
    add_box(bm, (0, (HATCH_Y0 + HATCH_Y1) / 2, (zmax - 3.0) / 2), (HATCH_HALF_W * 2, HATCH_Y1 - HATCH_Y0, zmax + 3.0), TRIM)
    hcut = obj_from_bm("HatchIsect", bm)
    boolean(hatch, hcut, 'INTERSECT')
    remove(hcut)
    # walkway ribs
    bmr = bmesh.new()
    for i in range(9):
        y = lerp(HATCH_Y0 + 0.35, HATCH_Y1 - 0.25, i / 8)
        add_box(bmr, (0, y, zmax + 0.012), (HATCH_HALF_W * 1.6, 0.06, 0.03), DARK)
    for sx in (-1, 1):
        add_box(bmr, (sx * (HATCH_HALF_W - 0.06), (HATCH_Y0 + HATCH_Y1) / 2, zmax + 0.03),
                (0.06, HATCH_Y1 - HATCH_Y0 - 0.2, 0.06), EMIT)
    ribs = obj_from_bm("HatchRibs", bmr)
    bevel(hatch, width=0.012, segs=2, angle=35)
    hatch = join([hatch, ribs], "Hatch")
    hinge = Vector((0, HATCH_Y0 + 0.03, belly + 0.08))
    hatch.data.transform(Matrix.Translation(-hinge))
    hatch.location = hinge
    # open angle: front-bottom edge touches the ground
    L = HATCH_Y1 - HATCH_Y0 - 0.03
    t = 0.1
    drop = hinge.z - GROUND_Z
    best = 0
    for d10 in range(0, 900):
        a = math.radians(d10 / 10)
        if L * math.sin(a) + t * math.cos(a) >= drop:
            best = d10 / 10
            break
    hatch["open_deg"] = -best
    hatch["axis"] = "x"
    # pocket cutter
    bmp = bmesh.new()
    ztop = belly + 0.62
    add_box(bmp, (0, (HATCH_Y0 + HATCH_Y1) / 2, (ztop + belly - 0.5) / 2),
            (HATCH_HALF_W * 2 + 0.04, HATCH_Y1 - HATCH_Y0 + 0.03, ztop - belly + 0.5), DARK)
    pocket = obj_from_bm("PocketCut", bmp)
    return hatch, pocket, best


def build_cockpit_cutter():
    bm = bmesh.new()
    rings = []
    ys = [lerp(CANOPY_Y0 + 0.25, CANOPY_Y1 - 0.55, i / 14) for i in range(15)]
    for y in ys:
        hw = max(CW(y) - 0.1, 0.12)
        rings.append(superellipse_ring(0, 1.2, hw, 1.12, 4.0, y, count=24))
    loft(bm, rings, DARK)
    return obj_from_bm("CockpitCut", bm)


# ----------------------------------------------------------------------------------------------
# Vertex data: R = convex edge, G = cavity, B = ambient visibility (1 = open)
# ----------------------------------------------------------------------------------------------
def bake_vertex_data(objs):
    random.seed(SEED)
    # world-space BVH of everything
    verts_all, polys_all = [], []
    for ob in objs:
        mw = ob.matrix_world
        base = len(verts_all)
        verts_all.extend(mw @ v.co for v in ob.data.vertices)
        polys_all.extend([base + i for i in p.vertices] for p in ob.data.polygons)
    bvh = BVHTree.FromPolygons(verts_all, polys_all, epsilon=0.0)
    dirs = []
    n_rays = 20
    for i in range(n_rays):  # cosine-weighted hemisphere (z-up)
        u, v = (i + 0.5) / n_rays, (i * 0.618034) % 1.0
        r = math.sqrt(u)
        phi = 2 * math.pi * v
        dirs.append(Vector((r * math.cos(phi), r * math.sin(phi), math.sqrt(max(0.0, 1 - u)))))
    maxd = 1.6
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
        # one smoothing pass
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
# Main
# ----------------------------------------------------------------------------------------------
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = argv[0] if argv else "assets/models/ship.glb"
    blend_out = None
    if "--blend" in argv:
        blend_out = argv[argv.index("--blend") + 1]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    MATERIALS.extend(make_materials())

    fus = build_fuselage()
    hatch, pocket, hatch_deg = build_hatch_and_cutters(fus)

    body = fus
    for part in (build_wings(), build_nacelles(), build_deck(), build_fins(), build_spine()):
        boolean(body, part, 'UNION')
        remove(part)
    # cutouts
    cock = build_cockpit_cutter()
    boolean(body, cock, 'DIFFERENCE')
    remove(cock)
    boolean(body, pocket, 'DIFFERENCE')
    remove(pocket)

    gf_h = Vector((0, GEAR_FRONT_Y, fuse_belly_z(0, GEAR_FRONT_Y) + GEAR_HINGE_DEPTH))
    gear_f, cut_f = build_gear("GearFront", gf_h, -90.0, fuse_belly_z, 0.34, 0.30)
    gears = [gear_f]
    cuts = [cut_f]
    for side, nm in ((1, "GearRearR"), (-1, "GearRearL")):
        h = Vector((NAC_X * side, GEAR_REAR_Y, nac_belly_z(0, GEAR_REAR_Y) + GEAR_HINGE_DEPTH))
        g, c = build_gear(nm, h, 90.0, lambda x, y, s=side: nac_belly_z(x, y), 0.42, 0.36)
        gears.append(g)
        cuts.append(c)
    for c in cuts:
        boolean(body, c, 'DIFFERENCE')
        remove(c)
    bevel(body)
    body.name = "Hull"

    noz = build_nozzles()
    bevel(noz, width=0.012, segs=2, angle=35)
    det = build_details()
    bevel(det, width=0.006, segs=1, angle=40)
    pods = build_cannon_pods()
    bevel(pods, width=0.01, segs=1, angle=35)
    cockpit = build_cockpit_interior()
    bevel(cockpit, width=0.01, segs=1, angle=40)
    hull = join([body, noz, det, pods, cockpit], "Hull")

    canopy = build_canopy()

    meshes = [hull, canopy, hatch] + gears
    for ob in meshes:
        finalize_normals(ob, sharp_deg=20.0 if ob.name == "Canopy" else 46.0)
        smart_uv(ob)
    bake_vertex_data(meshes)

    # ---------------- markers ----------------
    for side, nm in ((1, "EngineExhaust_R"), (-1, "EngineExhaust_L")):
        empty(nm, (NAC_X * side, NAC_REAR_Y - NOZZLE_LEN - 0.05, NAC_Z), direction=(0, -1, 0),
              extras={"radius": round(NA(NAC_REAR_Y) * 0.72, 3), "kind": "main"})
    empty("EngineExhaust_C", (0, TAIL_Y - 0.55, 0.22), direction=(0, -1, 0), extras={"radius": 0.38, "kind": "aux"})
    for (p, n), nm in zip(rcs_points(), RCS_NAMES):
        empty(nm, Vector(p) + Vector(n).normalized() * 0.05, direction=n, size=0.15)
    for nm, p in nav_points().items():
        empty(nm, p, size=0.1)
    empty("PilotSeat", (0, 3.9, 0.36), size=0.3)
    empty("PilotEye", (0, 3.8, 1.12), size=0.15)
    ramp_tip_y = HATCH_Y0 + (HATCH_Y1 - HATCH_Y0) * math.cos(math.radians(hatch_deg))
    empty("ExitPoint", (0, ramp_tip_y + 0.9, GROUND_Z), size=0.5)
    empty("GroundPoint", (0, 0, GROUND_Z), size=0.5)
    cam_pos = Vector((0, -19.0, 4.6))
    look = (Vector((0, 2.0, 0.6)) - cam_pos).normalized()
    empty("CameraChase", cam_pos, direction=look, size=0.6)

    # stats
    tris = 0
    for ob in meshes:
        ob.data.calc_loop_triangles()
        tris += len(ob.data.loop_triangles)
        print("[ship] %-12s tris=%d" % (ob.name, len(ob.data.loop_triangles)))
    print("[ship] TOTAL tris=%d  hatch_open=%.1f deg" % (tris, -hatch_deg))

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
