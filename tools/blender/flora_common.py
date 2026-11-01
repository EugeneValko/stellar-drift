"""Shared helpers for the procedural scatter assets (flora_*.py, rocks.py, crystals.py).

Geometry is accumulated in a MeshBuilder (positions + per-corner uv / colour / normal / material),
then turned into a Blender object with explicit custom normals (foliage cards get "volume" normals
bent away from the crown centre, which is what makes cards read as soft foliage in Godot).

Axis convention: build in Blender space (+Z up); the glTF exporter (+Y up) maps (x, y, z) -> (x, z, -y),
so Z here becomes Godot +Y. Every asset has its pivot at the ground contact point (origin, z = 0).

Vertex colour ("Col", FLOAT_COLOR, corner domain, exported linear as COLOR_0) is *data*, not colour:
  foliage / bark : r = sway weight (0 at the base, 1 at the top), g = flutter (0 at stem, 1 at leaf tip),
                   b = ambient occlusion (1 = open), a = branch phase (0..1 random per branch)
  grass / flower : r = height along blade (0..1), g = flutter, b = AO, a = blade random
  rock / crystal : r = AO / cavity, g = 'top' / tip glow, b = variant random, a = 1
UV (Blender v = 0 at the stem, 1 at the tip; glTF flips v, so in Godot t = 1 - UV.y).
"""
import bpy
import math
import random
import sys
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree


def out_path(default):
    argv = sys.argv
    if "--" in argv:
        rest = argv[argv.index("--") + 1:]
        if rest:
            return rest[0]
    return default


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


_MATS = {}


def material(name, color=(0.5, 0.5, 0.5, 1.0)):
    """Plain material slot; Godot replaces it by name (see src/planets/scatter/scatter_assets.gd)."""
    if name in _MATS:
        return _MATS[name]
    m = bpy.data.materials.new(name)
    m.diffuse_color = color
    _MATS[name] = m
    return m


class MeshBuilder:
    def __init__(self):
        self.v = []          # Vector positions
        self.faces = []      # (indices, uvs, cols, nrms, mat_name)

    def vert(self, p):
        self.v.append(Vector(p))
        return len(self.v) - 1

    def face(self, idx, uvs, cols, nrms, mat):
        self.faces.append((list(idx), list(uvs), list(cols), [Vector(n).normalized() for n in nrms], mat))

    def tri_count(self):
        return sum(len(f[0]) - 2 for f in self.faces)

    def extend(self, other, xform=None):
        base = len(self.v)
        rot = xform.to_3x3() if xform else None
        for p in other.v:
            self.v.append(xform @ p if xform else p.copy())
        for idx, uvs, cols, nrms, mat in other.faces:
            n2 = [(rot @ n).normalized() for n in nrms] if rot else nrms
            self.faces.append(([i + base for i in idx], uvs, cols, n2, mat))

    def build(self, name, mat_order):
        me = bpy.data.meshes.new(name)
        me.from_pydata([tuple(p) for p in self.v], [], [f[0] for f in self.faces])
        mats = [m for m in mat_order if any(f[4] == m for f in self.faces)]
        for m in mats:
            me.materials.append(material(m))
        uv = me.uv_layers.new(name="UVMap")
        col = me.color_attributes.new("Col", 'FLOAT_COLOR', 'CORNER')
        me.color_attributes.active_color = col
        normals = []
        for fi, poly in enumerate(me.polygons):
            idx, uvs, cols, nrms, mat = self.faces[fi]
            poly.material_index = mats.index(mat)
            poly.use_smooth = True
            for k, li in enumerate(poly.loop_indices):
                uv.data[li].uv = uvs[k]
                col.data[li].color = cols[k]
                normals.append(tuple(nrms[k]))
        me.normals_split_custom_set(normals)
        me.update()
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        print("[asset] %-22s %5d tris" % (name, self.tri_count()))
        return ob


# ------------------------------------------------------------------------------------------
# Geometry primitives
# ------------------------------------------------------------------------------------------

def frames_along(pts):
    """Parallel-transport frames (tangent, normal, binormal) along a polyline."""
    n = len(pts)
    tans = []
    for i in range(n):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, n - 1)]
        tans.append((b - a).normalized())
    up = Vector((0, 0, 1))
    ref = Vector((1, 0, 0)) if abs(tans[0].dot(up)) > 0.9 else up
    nrm = tans[0].cross(ref).normalized()
    out = []
    for i in range(n):
        t = tans[i]
        nrm = (nrm - t * nrm.dot(t)).normalized()
        out.append((t, nrm, t.cross(nrm).normalized()))
    return out


def tube(mb, pts, radii, sides, mat, colfn, uv_v_scale=1.0, cap=False, phase=0.0, seam_rot=0.0,
         rad_noise=None):
    """Generalised cylinder along pts. colfn(t, p) -> (r, g, b, a)."""
    fr = frames_along(pts)
    rings = []
    length = 0.0
    vcoord = []
    for i, p in enumerate(pts):
        if i > 0:
            length += (p - pts[i - 1]).length
        vcoord.append(length)
    total = max(length, 1e-4)
    for i, p in enumerate(pts):
        t, nn, bn = fr[i]
        ring = []
        for s in range(sides):
            a = seam_rot + 2.0 * math.pi * s / sides
            d = nn * math.cos(a) + bn * math.sin(a)
            r = radii[i] * (rad_noise(i, s) if rad_noise else 1.0)
            ring.append((mb.vert(p + d * r), d))
        rings.append(ring)
    for i in range(len(pts) - 1):
        c0 = colfn(vcoord[i] / total, pts[i])
        c1 = colfn(vcoord[i + 1] / total, pts[i + 1])
        for s in range(sides):
            s2 = (s + 1) % sides
            u0 = s / sides
            u1 = (s + 1) / sides
            v0 = vcoord[i] / uv_v_scale
            v1 = vcoord[i + 1] / uv_v_scale
            a, b, c, d = rings[i][s], rings[i][s2], rings[i + 1][s2], rings[i + 1][s]
            mb.face([a[0], b[0], c[0], d[0]], [(u0, v0), (u1, v0), (u1, v1), (u0, v1)],
                    [c0, c0, c1, c1], [a[1], b[1], c[1], d[1]], mat)
    if cap:
        tip = mb.vert(pts[-1] + fr[-1][0] * radii[-1] * 0.5)
        c1 = colfn(1.0, pts[-1])
        last = rings[-1]
        for s in range(sides):
            s2 = (s + 1) % sides
            mb.face([last[s][0], last[s2][0], tip], [(0, 1), (1, 1), (0.5, 1)], [c1] * 3,
                    [last[s][1], last[s2][1], fr[-1][0]], mat)
    return total


def strip(mb, spine, sides_vec, widths, mat, colfn, nrmfn, u_off=0.0):
    """Card strip along a spine: spine[i] +- sides_vec[i] * widths[i] / 2.
    colfn(t) -> colour, nrmfn(t, p, side) -> normal (side in -1..1). UV u across (0..1), v along."""
    n = len(spine)
    L = [0.0]
    for i in range(1, n):
        L.append(L[-1] + (spine[i] - spine[i - 1]).length)
    tot = max(L[-1], 1e-4)
    rows = []
    for i in range(n):
        t = L[i] / tot
        w = widths[i] * 0.5
        a = spine[i] - sides_vec[i] * w
        b = spine[i] + sides_vec[i] * w
        rows.append((mb.vert(a), mb.vert(b), t, a, b))
    for i in range(n - 1):
        a0, b0, t0, pa0, pb0 = rows[i]
        a1, b1, t1, pa1, pb1 = rows[i + 1]
        mb.face([a0, b0, b1, a1], [(0, t0), (1, t0), (1, t1), (0, t1)],
                [colfn(t0), colfn(t0), colfn(t1), colfn(t1)],
                [nrmfn(t0, pa0, -1), nrmfn(t0, pb0, 1), nrmfn(t1, pb1, 1), nrmfn(t1, pa1, -1)], mat)


def card(mb, base, along, side, length, width, mat, col_base, col_tip, nrm, taper=1.0):
    """Flat quad from `base` along `along` (unit) with width along `side` (unit)."""
    sv = side.normalized() * width * 0.5
    tip = base + along.normalized() * length
    a = mb.vert(base - sv * taper)
    b = mb.vert(base + sv * taper)
    c = mb.vert(tip + sv)
    d = mb.vert(tip - sv)
    if callable(nrm):
        ns = [nrm(base - sv), nrm(base + sv), nrm(tip + sv), nrm(tip - sv)]
    else:
        ns = [nrm] * 4
    mb.face([a, b, c, d], [(0, 0), (1, 0), (1, 1), (0, 1)], [col_base, col_base, col_tip, col_tip], ns, mat)


def bezier(p0, p1, p2, p3, n):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append(p0 * u * u * u + p1 * 3 * u * u * t + p2 * 3 * u * t * t + p3 * t * t * t)
    return out


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def rot_z(a):
    return Matrix.Rotation(a, 4, 'Z')


# ------------------------------------------------------------------------------------------
# Ambient occlusion baked into a colour channel (ray cast against the object + ground plane)
# ------------------------------------------------------------------------------------------

def bake_ao(ob, channel=0, rays=24, dist=1.5, ground=True, strength=1.0, seed=3):
    """Hemisphere AO per corner (vertex position + corner normal), written into colour `channel`
    (multiplied with the existing value)."""
    me = ob.data
    bvh = BVHTree.FromObject(ob, bpy.context.evaluated_depsgraph_get())
    rnd = random.Random(seed)
    dirs = []
    for i in range(rays):
        z = rnd.random()
        a = rnd.random() * 2 * math.pi
        r = math.sqrt(max(0.0, 1 - z * z))
        dirs.append(Vector((math.cos(a) * r, math.sin(a) * r, z)))
    col = me.color_attributes["Col"]
    cache = {}
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            n = Vector(me.corner_normals[li].vector)
            key = (vi, round(n.x, 2), round(n.y, 2), round(n.z, 2))
            if key not in cache:
                p = me.vertices[vi].co
                rot = n.to_track_quat('Z', 'Y').to_matrix()
                hit = 0.0
                for d in dirs:
                    w = rot @ d
                    o = p + n * 0.01
                    h = bvh.ray_cast(o, w, dist)
                    blocked = h[0] is not None
                    if not blocked and ground and w.z < 0:
                        blocked = (o.z / -w.z) < dist
                    if blocked:
                        hd = h[3] if h[0] is not None else dist
                        hit += 1.0 - 0.5 * hd / dist
                cache[key] = max(0.0, 1.0 - strength * hit / rays)
            c = list(col.data[li].color)
            c[channel] *= cache[key]
            col.data[li].color = c


def export_glb(path):
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True, export_apply=True,
                              export_extras=True, export_vertex_color='ACTIVE', export_normals=True,
                              export_tangents=False, export_materials='EXPORT', export_cameras=False,
                              export_lights=False, export_image_format='NONE')
    print("[asset] exported", path)


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)
