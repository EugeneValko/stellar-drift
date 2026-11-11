"""Low-poly hull bodies for the game Tern: subdivision-level LODs, cage-aligned UV islands, cut-outs, mirroring.

Every LOD is built from the same SubD cages as the hero model (design.py); only the subdivision level changes.
UV islands follow cage edge loops (face layers li / lj), so their borders exist at every level: LOD0 is unwrapped
and packed once, every LOD (LOD0 included, after its cuts) samples its UVs from that uncut reference per island.
"""
import math

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform

import common as C
import design as D
import kit
import ship

# body name -> (atlas, body id)
BODIES = {
    "fuselage": ("A", 0), "cheek_R": ("A", 1), "spike_R": ("A", 2),
    "pod_R": ("B", 3), "wing_R": ("B", 4), "fin_R": ("B", 5), "tip_R": ("B", 6),
}
# subdivision level per LOD
LEVELS = {
    0: {"fuselage": 3, "cheek_R": 2, "spike_R": 2, "pod_R": 2, "wing_R": 2, "fin_R": 2, "tip_R": 2},
    1: {"fuselage": 2, "cheek_R": 1, "spike_R": 1, "pod_R": 1, "wing_R": 1, "fin_R": 1, "tip_R": 1},
    2: {"fuselage": 1, "cheek_R": 0, "spike_R": 0, "pod_R": 0, "wing_R": 1, "fin_R": 0, "tip_R": 0},
}


def raw(name, level):
    if name == "fuselage":
        return D.fuselage(level)
    fn = {"cheek_R": D.cheek, "spike_R": D.spike, "pod_R": D.nacelle, "wing_R": D.wing, "fin_R": D.fin,
          "tip_R": D.tip_pod}[name]
    return fn(level, 1)


def _island(name, i, j):
    """UV island id from the cage span (li = i) and ring position (lj = j)."""
    if i < 0:
        return 1 if i == -1 else 2                        # caps
    if name == "fuselage":
        grp = {0: 0, 11: 0, 1: 1, 2: 1, 9: 2, 10: 2, 3: 3, 4: 3, 7: 4, 8: 4, 5: 5, 6: 5}[j]
        seg = 0 if i <= 3 else (1 if i <= 7 else 2)
        return 10 + grp * 3 + seg
    if name == "pod_R":
        part = 0 if i <= 2 else (1 if i <= 5 else 2)     # duct / lip / outer skin
        return 10 + part * 2 + (0 if j <= 7 else 1)
    if name in ("wing_R", "fin_R"):
        surf = 0 if j <= 3 else (1 if j == 4 else 2)     # upper / blunt trailing edge / lower
        seg = 0 if (name == "fin_R" or i <= 1) else 1
        return 10 + surf * 2 + seg
    if name == "spike_R":
        return 10 + (0 if j <= 5 else 1)
    return 10 + (0 if j <= 3 else 1)                     # tip pod, cheek (8 around)


def _drop(name, i):
    """Cage caps that sit inside other bodies (or under the nozzle) are deleted."""
    return ((name == "pod_R" and i == -2) or (name == "wing_R" and i in (-1, -2)) or (name == "fin_R" and i == -1)
            or (name == "spike_R" and i == -2))


def body_bm(name, level):
    bm = raw(name, level)
    li = bm.faces.layers.int["li"]
    lj = bm.faces.layers.int["lj"]
    dead = [f for f in bm.faces if _drop(name, f[li])]
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")
    isl = bm.faces.layers.int.get("isl") or bm.faces.layers.int.new("isl")
    body = bm.faces.layers.int.get("body") or bm.faces.layers.int.new("body")
    for f in bm.faces:
        f[isl] = _island(name, f[li], f[lj])
        f[body] = BODIES[name][1]
        f.material_index = 0
        f.smooth = True
    return bm


def mark_seams(bm):
    isl = bm.faces.layers.int["isl"]
    body = bm.faces.layers.int["body"]
    for e in bm.edges:
        lf = e.link_faces
        e.seam = len(lf) != 2 or (lf[0][isl], lf[0][body]) != (lf[1][isl], lf[1][body])


# ------------------------------------------------------------------------------------------
# reference UVs (LOD0, uncut)
# ------------------------------------------------------------------------------------------
def unwrap_atlas(atlas, col, margin=0.0035):
    """Join the atlas bodies at LOD0 level, unwrap on cage-aligned seams, equalise and pack. Returns the object."""
    bm = bmesh.new()
    for name, (a, _bid) in BODIES.items():
        if a != atlas:
            continue
        b = body_bm(name, LEVELS[0][name])
        me = bpy.data.meshes.new("tmp")
        b.to_mesh(me)
        b.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    mark_seams(bm)
    ob = C.mesh_obj("REF_" + atlas, bm, col)
    bm.free()
    ob.data.uv_layers.new(name="UVMap")
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    vl.objects.active = ob
    ob.select_set(True)
    ts = bpy.context.scene.tool_settings
    ts.use_uv_select_sync = True
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.unwrap(method="ANGLE_BASED", margin=0.0, fill_holes=True)
    bpy.ops.uv.average_islands_scale()
    bpy.ops.uv.pack_islands(rotate=True, rotate_method="ANY", scale=True, margin_method="FRACTION", margin=margin,
                            shape_method="CONCAVE")
    bpy.ops.object.mode_set(mode="OBJECT")
    return ob


def texel_density(ob, size=C.TEX):
    """Average texels per metre of a UV-mapped mesh object (world space)."""
    me = ob.data
    uv = me.uv_layers.active.data
    a3 = auv = 0.0
    mw = ob.matrix_world
    for p in me.polygons:
        a3 += p.area
        pts = [uv[k].uv for k in p.loop_indices]
        s = 0.0
        for k in range(len(pts)):
            x0, y0 = pts[k]
            x1, y1 = pts[(k + 1) % len(pts)]
            s += x0 * y1 - x1 * y0
        auv += abs(s) * 0.5
    sc = mw.to_scale()
    a3 *= abs(sc.x * sc.y * sc.z) ** (2.0 / 3.0)
    return math.sqrt(auv * size * size / max(a3, 1e-9)), auv


class UVRef:
    """Per (body, island) BVH of the reference mesh, used to sample UVs for any LOD / cut variant."""

    def __init__(self, ob):
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        uvl = bm.loops.layers.uv.active
        isl = bm.faces.layers.int["isl"]
        body = bm.faces.layers.int["body"]
        groups = {}
        for f in bm.faces:
            groups.setdefault((f[body], f[isl]), []).append(f)
        self.trees = {}
        for key, faces in groups.items():
            co, polys, uvs = [], [], []
            for f in faces:
                base = len(co)
                tri_uv = []
                for lp in f.loops:
                    co.append(lp.vert.co.copy())
                    tri_uv.append(Vector((lp[uvl].uv.x, lp[uvl].uv.y, 0.0)))
                polys.append((base, base + 1, base + 2))
                uvs.append(tri_uv)
            self.trees[key] = (BVHTree.FromPolygons(co, polys), co, polys, uvs)
        bm.free()

    def apply(self, bm):
        uvl = bm.loops.layers.uv.get("UVMap") or bm.loops.layers.uv.new("UVMap")
        isl = bm.faces.layers.int["isl"]
        body = bm.faces.layers.int["body"]
        miss = 0
        for f in bm.faces:
            t = self.trees.get((f[body], f[isl]))
            if t is None:
                miss += 1
                continue
            tree, co, polys, uvs = t
            for lp in f.loops:
                loc, _n, idx, _d = tree.find_nearest(lp.vert.co)
                if idx is None:
                    miss += 1
                    continue
                a, b, c = polys[idx]
                u = barycentric_transform(loc, co[a], co[b], co[c], *uvs[idx])
                lp[uvl].uv = (u.x, u.y)
        return miss


# ------------------------------------------------------------------------------------------
# cut-outs (canopy glazing, gear-bay openings) with the exact outlines of ship.py
# ------------------------------------------------------------------------------------------
GLASS, HULL, REMOVE = 1, 0, -1


def cut_regions(name, bays=True):
    regs = []
    if name == "fuselage":
        flank = ship.p_out(1)
        regs.append((flank, D.CANOPY, -2, GLASS))
        for q in ([(4.70, 0.2), (4.80, 0.2), (4.40, 1.75), (4.30, 1.75)],
                  [(3.22, 0.2), (3.31, 0.2), (3.21, 1.75), (3.12, 1.75)]):
            regs.append((flank, q, -2, HULL))
        regs.append((ship.p_top(), kit.rect2(0.085, 1.80, 0.0, 2.36), 0.15, HULL))
        if bays:
            gx, gy = D.GEAR_NOSE
            regs.append((ship.p_bot(), kit.rect2(0.62, 1.50, gx, gy), 0.15, REMOVE))
    elif name == "pod_R" and bays:
        gx, gy = D.GEAR_MAIN
        regs.append((ship.p_bot(1), kit.rect2(0.66, 1.60, gx, gy), 0.5, REMOVE))
    return regs


def apply_cuts(bm, regs):
    if not regs:
        return
    pz = kit.Panelizer(bm, gap=0.0)
    rr = []
    for proj, pts, facing, action in regs:
        rr.append((pz.region(proj.mx, proj.poly(pts), facing=facing), action))
    bm.normal_update()
    for r, _a in rr:                                    # Panelizer step 2 (exact outline bisection) only
        Cn, Nn = pz._arrays()
        sel = pz._mask(r, Cn, Nn, grow=pz.margin, loose=True)
        faces = [f for f, s in zip(bm.faces, sel) if s]
        n = len(r.poly)
        for i in range(n):
            ax, ay = r.poly[i]
            bx, by = r.poly[(i + 1) % n]
            co = r.mx @ Vector((ax, ay, 0.0))
            no = (r.mx.to_3x3() @ Vector((by - ay, -(bx - ax), 0.0))).normalized()
            faces = [f for f in pz._bisect(faces, co, no) if f.is_valid]
    bm.normal_update()
    Cn, Nn = pz._arrays()
    act = [None] * len(Cn)
    for r, a in rr:                                     # later regions override earlier ones
        m = pz._mask(r, Cn, Nn)
        for k in range(len(act)):
            if m[k]:
                act[k] = a
    bm.faces.ensure_lookup_table()
    dead = []
    for f, a in zip(bm.faces[:], act):
        if a == REMOVE:
            dead.append(f)
        elif a == GLASS:
            f.material_index = 1
        elif a == HULL:
            f.material_index = 0
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")


def mirror_bm(bm):
    m = bm.copy()
    bmesh.ops.scale(m, vec=(-1.0, 1.0, 1.0), verts=m.verts[:])
    bmesh.ops.reverse_faces(m, faces=m.faces[:])
    m.normal_update()
    return m


def lod_bodies(lod, refs, bays=True):
    """name -> triangulated bmesh with UVs (port bodies mirrored). material_index 1 = glazing."""
    out = {}
    for name, (atlas, _bid) in BODIES.items():
        bm = body_bm(name, LEVELS[lod][name])
        apply_cuts(bm, cut_regions(name, bays))
        miss = refs[atlas].apply(bm)
        if miss:
            print("UV MISS", name, lod, miss)
        mark_seams(bm)
        C.triangulate(bm)
        bm.normal_update()
        out[name] = bm
        if name != "fuselage":
            out[name.replace("_R", "_L")] = mirror_bm(bm)
    return out


def assemble(bms, names, col, obname, mat_of=None, keep_glass=True, only_glass=False):
    """Merge body bmeshes into one mesh object (smooth, sharp only on hard seams).
    mat_of(name) -> material index for hull faces; glazing faces get index 2 (or are dropped)."""
    acc = bmesh.new()
    for n in names:
        b = bms[n].copy()
        kill = []
        for f in b.faces:
            if f.material_index == 1:
                if not keep_glass and not only_glass:
                    kill.append(f)
                f.material_index = 2
            else:
                if only_glass:
                    kill.append(f)
                f.material_index = mat_of(n) if mat_of else 0
        if kill:
            bmesh.ops.delete(b, geom=kill, context="FACES")
        me = bpy.data.meshes.new("tmp")
        b.to_mesh(me)
        b.free()
        acc.from_mesh(me)
        bpy.data.meshes.remove(me)
    ob = C.mesh_obj(obname, acc, col)
    acc.free()
    C.smooth_with_sharp(ob.data, 50.0, seam_only=True)
    return ob


def body_bvh(bm):
    return BVHTree.FromBMesh(bm)
