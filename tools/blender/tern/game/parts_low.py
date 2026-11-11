"""Low-poly versions of the mounted hardware that stays geometry in the game model.

Classification of the hero model's mounted instances (by mesh name), placements of the kept parts (node names of
the glTF), and the decimation of each UNIQUE template mesh (instances keep sharing one mesh).
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector

import common as C
import design as D
import kit

# mesh base name -> (LOD0 triangle budget, min loose-island size [m], bake class)
KEEP = {
    "Nozzle": (16000, 0.030, "mid"),
    "DriftDrive": (11000, 0.025, "mid"),
    "Gear": (5600, 0.022, "mid"),
    "GearBay": (0, 0.0, "bay"),          # rebuilt as an open box
    "GearDoor": (300, 0.030, "mid"),
    "SensorTurret": (3000, 0.015, "mid"),
    "Cannon": (2500, 0.015, "mid"),
    "antenna_blade": (260, 0.004, "fine"),
    "antenna_whip": (180, 0.004, "fine"),
    "nav_light_green": (300, 0.006, "fine"),
    "nav_light_red": (300, 0.006, "fine"),
    "strobe_red": (260, 0.006, "fine"),
    "sensor_dome": (300, 0.006, "fine"),
    "hardpoint": (420, 0.012, "mid"),
}
# LOD1 / LOD2 keep ratios of the LOD0 triangle count (None = dropped at that LOD)
LOD_RATIO = {
    "Nozzle": (0.32, 0.04), "DriftDrive": (0.30, 0.05), "Gear": (0.33, 0.06), "GearBay": (1.0, None),
    "GearDoor": (0.6, None), "SensorTurret": (0.35, 0.05), "Cannon": (0.35, 0.06), "antenna_blade": (0.5, None),
    "antenna_whip": (0.5, None), "nav_light_green": (0.4, None), "nav_light_red": (0.4, None),
    "strobe_red": (0.4, None), "sensor_dome": (0.4, None), "hardpoint": (0.5, None),
}
FITTINGS = {"antenna_blade", "antenna_whip", "nav_light_green", "nav_light_red", "strobe_red", "sensor_dome",
            "hardpoint"}
LENS_MATS = {"sp_lens_glass"}


def base(name):
    return name.split(".")[0].replace("_nolens", "")


def classify(col):
    """Split the hero model's objects: hull skins, kept part instances, flush (baked) fittings, decals, cockpit."""
    out = {"hull": [], "kept": [], "flush": [], "decal": [], "cockpit": [], "other": []}
    for ob in col.objects:
        if ob.type != "MESH":
            continue
        n = ob.name
        if n.startswith("decal_"):
            out["decal"].append(ob)
        elif n.startswith("cockpit_"):
            out["cockpit"].append(ob)
        elif n == "Fasteners":
            out["flush"].append(ob)
        elif base(ob.data.name) in KEEP:
            out["kept"].append(ob)
        elif n.split("_under")[0] in ("fuselage",) or any(n.startswith(p) for p in ("pod_", "wing_", "fin_", "tip_",
                                                                                     "spike_", "cheek_")):
            out["hull"].append(ob)
        else:
            out["flush"].append(ob)
    return out


def node_name(ob):
    """glTF node name of a kept instance (ship space: +X starboard, +Y nose)."""
    b = base(ob.data.name)
    x, y = ob.matrix_world.translation.x, ob.matrix_world.translation.y
    s = "R" if x > 0 else "L"
    if b == "Nozzle":
        return "EngineNozzle_" + s
    if b == "DriftDrive":
        return "DriftDrive"
    if b == "Gear":
        return "GearNose" if y > 0 else "GearMain" + s
    if b == "GearBay":
        return "GearBay_Nose" if y > 0 else "GearBay_Main" + s
    if b == "GearDoor":
        if y > 0:
            return "BayDoor_Nose_" + s
        side = "Out" if (abs(x) > D.GEAR_MAIN[0]) else "In"
        return "BayDoor_Main%s_%s" % (s, side)
    if b == "SensorTurret":
        return "SensorTurret"
    if b == "Cannon":
        return "Cannon_" + s
    return {"antenna_blade": "AntennaBlade", "antenna_whip": "AntennaWhip", "nav_light_green": "NavLight_R",
            "nav_light_red": "NavLight_L", "strobe_red": "Strobe", "sensor_dome": "SensorDome"}.get(b, "Hardpoint_" + s)


def strip_lenses(objs):
    """Clear lenses hide their emitters from the bake rays: swap in mesh copies without the lens faces."""
    done = {}
    for ob in objs:
        me = ob.data
        idx = [i for i, m in enumerate(me.materials) if m is not None and m.name in LENS_MATS]
        if not idx:
            continue
        if me.name not in done:
            m2 = me.copy()
            m2.name = me.name + "_nolens"
            bm = bmesh.new()
            bm.from_mesh(m2)
            bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index in idx], context="FACES")
            bm.to_mesh(m2)
            bm.free()
            done[me.name] = m2
        ob.data = done[me.name]
    return len(done)


# ------------------------------------------------------------------------------------------
def _drop_small(bm, min_size):
    """Delete loose islands whose bounding-box diagonal is below min_size (bolts, rivets, pins)."""
    if min_size <= 0:
        return 0
    seen = set()
    dead = []
    for f0 in bm.faces:
        if f0 in seen:
            continue
        stack = [f0]
        isl = []
        seen.add(f0)
        while stack:
            f = stack.pop()
            isl.append(f)
            for e in f.edges:
                for g in e.link_faces:
                    if g not in seen:
                        seen.add(g)
                        stack.append(g)
        vs = {v for f in isl for v in f.verts}
        lo = Vector((min(v.co.x for v in vs), min(v.co.y for v in vs), min(v.co.z for v in vs)))
        hi = Vector((max(v.co.x for v in vs), max(v.co.y for v in vs), max(v.co.z for v in vs)))
        if (hi - lo).length < min_size:
            dead += isl
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")
    return len(dead)


def decimate(ob, target):
    cur = C.tris(ob.data)
    if target <= 0 or cur <= target:
        return
    m = ob.modifiers.new("Planar", "DECIMATE")
    m.decimate_type = "DISSOLVE"
    m.angle_limit = math.radians(0.5)
    m.delimit = {"NORMAL"}
    kit.apply_mods(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    C.triangulate(bm)
    bm.to_mesh(ob.data)
    bm.free()
    cur = C.tris(ob.data)
    if cur > target:
        m = ob.modifiers.new("Collapse", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = target / cur
        m.use_collapse_triangulate = True
        kit.apply_mods(ob)


def bay_box(length, width, depth, name, col):
    """Open gear-well box: roof at z = 0, opening at z = -depth, faces looking into the cavity."""
    hw, hl = width / 2, length / 2
    bm = bmesh.new()
    nx, ny, nz = 2, 4, 2

    def grid(o, a, b, na, nb):
        vs = [[bm.verts.new(o + a * (i / na) + b * (j / nb)) for i in range(na + 1)] for j in range(nb + 1)]
        for j in range(nb):
            for i in range(na):
                bm.faces.new((vs[j][i], vs[j][i + 1], vs[j + 1][i + 1], vs[j + 1][i]))

    V = Vector
    grid(V((-hw, -hl, 0)), V((2 * hw, 0, 0)), V((0, 2 * hl, 0)), nx, ny)            # roof
    for sx in (-1, 1):
        grid(V((sx * hw, -hl, 0)), V((0, 2 * hl, 0)), V((0, 0, -depth)), ny, nz)     # side walls
    for sy in (-1, 1):
        grid(V((-hw, sy * hl, 0)), V((2 * hw, 0, 0)), V((0, 0, -depth)), nx, nz)     # end walls
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
    centre = V((0, 0, -depth / 2))
    for f in bm.faces:
        f.normal_update()
        if f.normal.dot(centre - f.calc_center_median()) < 0:
            f.normal_flip()
    C.triangulate(bm)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    col.objects.link(ob)
    C.smooth_with_sharp(me, 45.0)
    return ob


BAY_DIMS = {"nose": (1.50, 0.62, 0.45), "main": (1.60, 0.66, 0.40)}


def make_low(src, col):
    """LOD0 low mesh for one unique template (src = its first instance). Returns an object at the instance's
    location/rotation (scale applied into the mesh, so instances can share it)."""
    b = base(src.data.name)
    budget, min_size, _cls = KEEP[b]
    loc, rot, scl = src.matrix_world.decompose()
    name = "low_" + src.data.name
    if b == "GearBay":
        dims = BAY_DIMS["nose" if loc.y > 0 else "main"]
        ob = bay_box(*dims, name, col)
    else:
        me = src.data.copy()
        me.name = name
        me.materials.clear()
        bm = bmesh.new()
        bm.from_mesh(me)
        _drop_small(bm, min_size)
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new(name, me)
        col.objects.link(ob)
        decimate(ob, budget)
    if (scl - Vector((1, 1, 1))).length > 1e-6:
        ob.data.transform(Matrix.Diagonal(scl.to_4d()))
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    C.triangulate(bm)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-6)
    bm.to_mesh(ob.data)
    bm.free()
    C.smooth_with_sharp(ob.data, 40.0)
    ob.matrix_world = Matrix.LocRotScale(loc, rot, None)
    return ob


def unwrap_parts(objs, margin=0.002):
    """Smart-project every unique low part, equalise texel density and pack them all into one atlas (C)."""
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    for o in objs:
        if not o.data.uv_layers:
            o.data.uv_layers.new(name="UVMap")
        o.select_set(True)
    vl.objects.active = objs[0]
    bpy.context.scene.tool_settings.use_uv_select_sync = True
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.0, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.average_islands_scale()
    bpy.ops.uv.pack_islands(rotate=True, rotate_method="ANY", scale=True, margin_method="FRACTION", margin=margin,
                            shape_method="CONCAVE")
    bpy.ops.object.mode_set(mode="OBJECT")
    # seams on UV island borders -> hard edges only where an island border is also a crease
    for o in objs:
        C.smooth_with_sharp(o.data, 40.0)


def lod_copy(ob, ratio, col, suffix, min_size=0.0):
    """Further-decimated copy of a LOD0 low part (UVs are interpolated by the collapse decimator); loose pieces
    smaller than min_size are dropped first."""
    me = ob.data.copy()
    me.name = ob.data.name + suffix
    if min_size > 0:
        n0 = len(me.polygons)
        bm = bmesh.new()
        bm.from_mesh(me)
        _drop_small(bm, min_size)
        bm.to_mesh(me)
        bm.free()
        ratio = min(1.0, ratio * n0 / max(len(me.polygons), 1))
    o2 = bpy.data.objects.new(ob.name + suffix, me)
    col.objects.link(o2)
    o2.matrix_world = ob.matrix_world.copy()
    if ratio < 0.999:
        m = o2.modifiers.new("Collapse", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = ratio
        m.use_collapse_triangulate = True
        kit.apply_mods(o2)
        C.smooth_with_sharp(o2.data, 40.0)
    return o2
