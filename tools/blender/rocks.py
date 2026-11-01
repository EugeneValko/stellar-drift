"""Rocks for every planet: boulders, slabs, clusters, pebbles, volcanic rocks and basalt columns.

Run:
    blender -b -P tools/blender/rocks.py -- assets/models/rocks.glb

Objects (pivot at ground contact, ~1 m nominal size unless noted; scaled per instance in Godot):
  boulder_a_lod0/1   rounded weathered boulder
  boulder_b_lod0/1   angular faceted boulder (convex hull + noise)
  boulder_c_lod0/1   flat slab
  rock_cluster_lod0/1  3-5 rocks + pebbles (~3 m footprint)
  pebbles_lod0       scattered small stones (ground detail, ~1.5 m footprint)
  volcanic_a_lod0/1  jagged porous lava rock
  volcanic_b_lod0/1  tall spiky lava spire
  basalt_a_lod0/1    basalt column cluster (~5 m wide, columns up to 4 m): bevelled, chipped tops
  basalt_b_lod0/1    broken low basalt "pavement" with a few standing columns
  scree_lod0/1       angular talus stones (~4 m footprint) for scree aprons / rock-fall
  tor_lod0/1         stacked, fractured block outcrop (~2.5 m tall)
Material slots: rock, basalt. Vertex colour: r = baked AO, g = up-facing "top" mask (basalt column
tops, weathered ledges), b = variant random, a = 1.
"""
import bmesh
import bpy
import math
import os
import random
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from flora_common import Vector, bake_ao, export_glb, material, out_path, reset_scene, tri_count
from mathutils import noise


def hull_rock(rnd, npts=28, scale=(1, 1, 0.7), noise_amp=0.08, noise_freq=2.2, sharp=0.0,
              pits=0.0, subdiv=2, flat_bottom=0.15):
    bm = bmesh.new()
    pts = []
    for i in range(npts):
        z = rnd.uniform(-1, 1)
        a = rnd.uniform(0, 2 * math.pi)
        r = math.sqrt(1 - z * z)
        rr = rnd.uniform(0.82, 1.0)
        pts.append(Vector((math.cos(a) * r * scale[0], math.sin(a) * r * scale[1], z * scale[2])) * rr)
    for p in pts:
        bm.verts.new(p)
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    for _ in range(subdiv):
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=1, use_grid_fill=True)
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
    bm.normal_update()
    for v in bm.verts:
        p = v.co
        n = noise.fractal(p * noise_freq + off, 0.5, 2.0, 4, noise_basis='PERLIN_ORIGINAL')
        d = n * noise_amp
        if sharp > 0:
            vor = noise.voronoi(p * noise_freq * 1.3 + off, distance_metric='DISTANCE', exponent=2.5)
            d += (vor[0][1] - vor[0][0]) * sharp * 0.25 - sharp * 0.05
        if pits > 0:
            vor = noise.voronoi(p * noise_freq * 3.0 + off * 2.0, distance_metric='DISTANCE', exponent=2.5)
            d -= max(0.0, 0.25 - vor[0][0]) * pits
        v.co = p + v.normal * d
    # sit on the ground: flatten the bottom
    zmin = min(v.co.z for v in bm.verts)
    cut = zmin + (max(v.co.z for v in bm.verts) - zmin) * flat_bottom
    for v in bm.verts:
        if v.co.z < cut:
            v.co.z = cut + (v.co.z - cut) * 0.15
    zmin = min(v.co.z for v in bm.verts)
    for v in bm.verts:
        v.co.z -= zmin + 0.04 * scale[2]   # slightly embedded
    return bm


def bm_to_obj(bm, name, mat="rock"):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(material(mat))
    for p in me.polygons:
        p.use_smooth = True
    return ob


def decimate(ob, target):
    tc = tri_count(ob)
    if tc <= target:
        return
    mod = ob.modifiers.new("dec", 'DECIMATE')
    mod.ratio = target / tc
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    ob.select_set(False)


def finish(ob, variant, ao_dist=0.8, ao_strength=1.1):
    me = ob.data
    col = me.color_attributes.new("Col", 'FLOAT_COLOR', 'CORNER')
    me.color_attributes.active_color = col
    me.calc_loop_triangles()
    for poly in me.polygons:
        top = max(0.0, min(1.0, (poly.normal.z - 0.55) / 0.35))
        for li in poly.loop_indices:
            col.data[li].color = (1.0, top, variant, 1.0)
    bake_ao(ob, channel=0, rays=20, dist=ao_dist, strength=ao_strength)
    print("[asset] %-22s %5d tris" % (ob.name, tri_count(ob)))


def copy_obj(ob, name):
    o2 = ob.copy()
    o2.data = ob.data.copy()
    o2.name = name
    o2.data.name = name
    bpy.context.scene.collection.objects.link(o2)
    return o2


def make_lods(name, bm_fn, t0, t1, variant, ao_dist=0.8):
    ob = bm_to_obj(bm_fn(), name + "_lod0")
    decimate(ob, t0)
    if t1 > 0:
        o1 = copy_obj(ob, name + "_lod1")
        decimate(o1, t1)
        finish(o1, variant, ao_dist)
    finish(ob, variant, ao_dist)


def merge_bms(parts):
    """parts: list of (bm, offset Vector, scale float, rot_z float) -> one bmesh."""
    from mathutils import Matrix
    out = bmesh.new()
    for bm, off, s, rz in parts:
        me = bpy.data.meshes.new("tmp")
        bm.to_mesh(me)
        bm.free()
        me.transform(Matrix.Translation(off) @ Matrix.Rotation(rz, 4, 'Z') @ Matrix.Scale(s, 4))
        out.from_mesh(me)
        bpy.data.meshes.remove(me)
    return out


def basalt(rnd, radius=2.6, hmax=4.0, pavement=False, lod=0):
    """Hexagonal columns on a hex lattice; heights from a sloped noise field. Tops are bevelled
    (inset chamfer ring), some corners chipped off, some columns broken / leaning."""
    bm = bmesh.new()
    sp = 0.62
    a = sp / math.sqrt(3) * 0.95   # hex circumradius (small gap)
    rows = int(radius / sp) + 2
    off = Vector((rnd.uniform(0, 50), rnd.uniform(0, 50), 0))
    tilt_dir = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0)).normalized()
    lean_dir = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), 0)).normalized()
    for j in range(-rows, rows + 1):
        for i in range(-rows, rows + 1):
            cx = (i + 0.5 * (j & 1)) * sp
            cy = j * sp * math.sqrt(3) / 2
            c = Vector((cx, cy, 0))
            d = c.length / radius
            if d > 1.0 + rnd.uniform(-0.15, 0.1):
                continue
            n = noise.noise(c * 0.6 + off)
            if pavement:
                h = 0.22 + 0.28 * rnd.random() + (2.2 * rnd.random() if rnd.random() < 0.12 else 0.0)
            else:
                h = hmax * (1.0 - d * 0.75) * (0.75 + 0.35 * n) + c.dot(tilt_dir) * 0.35
                if rnd.random() < 0.18:
                    h *= rnd.uniform(0.3, 0.7)   # broken column
            h = max(0.18, h)
            tilt = Vector((rnd.uniform(-0.12, 0.12), rnd.uniform(-0.12, 0.12)))
            if rnd.random() < 0.25:
                tilt *= 2.5                       # snapped, slanted top
            ar = a * rnd.uniform(0.9, 1.0)
            rot = rnd.uniform(-0.06, 0.06)
            lean = lean_dir * (h * 0.03 * rnd.random()) if not pavement else Vector((0, 0, 0))
            bev = min(0.06, h * 0.2) * rnd.uniform(0.6, 1.3)
            bot, mid, top = [], [], []
            for k in range(6):
                ang = math.pi / 6 + k * math.pi / 3 + rot
                dirk = Vector((math.cos(ang), math.sin(ang), 0))
                q = c + dirk * ar * rnd.uniform(0.97, 1.03)
                dz = (q.x - c.x) * tilt.x + (q.y - c.y) * tilt.y
                chip = 0.0
                if lod == 0 and rnd.random() < 0.22:
                    chip = rnd.uniform(0.06, 0.22)   # chipped corner
                bot.append(bm.verts.new(Vector((q.x, q.y, -0.3))))
                qm = q + lean
                mid.append(bm.verts.new(Vector((qm.x, qm.y, h + dz - bev - chip))))
                qt = c + lean + dirk * (ar - bev * 1.2 - chip * 0.6)
                top.append(bm.verts.new(Vector((qt.x, qt.y, h + dz - chip * 0.4))))
            for k in range(6):
                k2 = (k + 1) % 6
                bm.faces.new([bot[k], bot[k2], mid[k2], mid[k]])
                bm.faces.new([mid[k], mid[k2], top[k2], top[k]])     # chamfer
            ctr = bm.verts.new(c + lean + Vector((0, 0, h + rnd.uniform(-0.02, 0.03))))
            for k in range(6):
                bm.faces.new([top[k], top[(k + 1) % 6], ctr])
    bm.normal_update()
    return bm


def angular(rnd, scale=(1, 0.8, 0.6)):
    return hull_rock(rnd, 10, scale, 0.015, 3.0, sharp=0.5, subdiv=0, flat_bottom=0.2)


def main():
    out = out_path("assets/models/rocks.glb")
    reset_scene()
    seed = [1000]

    def R():
        seed[0] += 17
        return random.Random(seed[0])

    make_lods("boulder_a", lambda: hull_rock(R(), 40, (1, 0.9, 0.75), 0.07, 1.6, subdiv=2), 520, 120, 0.1)
    make_lods("boulder_b", lambda: hull_rock(R(), 14, (1, 0.85, 0.8), 0.035, 2.5, sharp=0.6, subdiv=2),
              480, 110, 0.35)
    make_lods("boulder_c", lambda: hull_rock(R(), 24, (1.2, 1.0, 0.38), 0.05, 2.0, subdiv=2,
                                             flat_bottom=0.25), 420, 100, 0.6)

    def cluster():
        rnd = R()
        parts = []
        for k, (x, y, s) in enumerate([(0, 0, 1.0), (0.85, 0.35, 0.6), (-0.6, 0.6, 0.5), (0.3, -0.8, 0.45),
                                       (-0.9, -0.4, 0.32)]):
            parts.append((hull_rock(rnd, 18, (1, 0.9, 0.75), 0.05, 2.0, sharp=0.4, subdiv=1),
                          Vector((x, y, 0)), s, rnd.uniform(0, 6.28)))
        for k in range(7):
            a = rnd.uniform(0, 6.28)
            r = rnd.uniform(0.9, 1.6)
            parts.append((hull_rock(rnd, 9, (1, 0.8, 0.6), 0.02, 3.0, subdiv=0),
                          Vector((math.cos(a) * r, math.sin(a) * r, 0)), rnd.uniform(0.08, 0.16), 0))
        return merge_bms(parts)
    make_lods("rock_cluster", cluster, 900, 220, 0.8, ao_dist=1.2)

    def pebbles():
        rnd = R()
        parts = []
        for k in range(14):
            a = rnd.uniform(0, 6.28)
            r = 0.75 * math.sqrt(rnd.random())
            parts.append((hull_rock(rnd, 9, (1, 0.85, 0.55), 0.02, 3.0, subdiv=0),
                          Vector((math.cos(a) * r, math.sin(a) * r, 0)), rnd.uniform(0.05, 0.14),
                          rnd.uniform(0, 6.28)))
        return merge_bms(parts)
    make_lods("pebbles", pebbles, 260, 0, 0.5, ao_dist=0.2)

    make_lods("volcanic_a", lambda: hull_rock(R(), 22, (1, 0.9, 0.7), 0.06, 2.6, sharp=0.8, pits=0.5,
                                              subdiv=2), 600, 140, 0.2)
    make_lods("volcanic_b", lambda: hull_rock(R(), 18, (0.55, 0.5, 1.6), 0.07, 2.2, sharp=1.0, pits=0.4,
                                              subdiv=2, flat_bottom=0.05), 560, 130, 0.7)

    for nm, kw, var in (("basalt_a", {}, 0.3), ("basalt_b", {"radius": 3.0, "pavement": True}, 0.7)):
        sd = seed[0] + 17
        seed[0] = sd
        ob = bm_to_obj(basalt(random.Random(sd), lod=0, **kw), nm + "_lod0", "basalt")
        finish(ob, var, ao_dist=1.2, ao_strength=1.0)
        ob = bm_to_obj(basalt(random.Random(sd), lod=1, **kw), nm + "_lod1", "basalt")
        finish(ob, var, ao_dist=1.2, ao_strength=1.0)

    def scree():
        rnd = R()
        parts = []
        for k in range(26):
            a = rnd.uniform(0, 6.28)
            r = 2.0 * math.sqrt(rnd.random())
            s = rnd.uniform(0.07, 0.32) * (1.25 - 0.4 * r / 2.0)
            parts.append((angular(rnd, (1, rnd.uniform(0.6, 0.95), rnd.uniform(0.4, 0.75))),
                          Vector((math.cos(a) * r, math.sin(a) * r, 0)), s, rnd.uniform(0, 6.28)))
        return merge_bms(parts)
    make_lods("scree", scree, 700, 200, 0.45, ao_dist=0.5)

    def tor():
        rnd = R()
        parts = []
        z = 0.0
        for k in range(4):
            sx = rnd.uniform(0.75, 1.15) * (1.0 - k * 0.12)
            hh = rnd.uniform(0.35, 0.6)
            b = hull_rock(rnd, 16, (sx, sx * rnd.uniform(0.7, 0.95), hh), 0.025, 2.4, sharp=0.35, subdiv=1,
                          flat_bottom=0.3)
            parts.append((b, Vector((rnd.uniform(-0.15, 0.15), rnd.uniform(-0.15, 0.15), z)), 1.0,
                          rnd.uniform(0, 6.28)))
            z += hh * 1.25
        for k in range(5):
            a = rnd.uniform(0, 6.28)
            r = rnd.uniform(1.0, 1.7)
            parts.append((angular(rnd), Vector((math.cos(a) * r, math.sin(a) * r, 0)), rnd.uniform(0.15, 0.35), 0))
        return merge_bms(parts)
    make_lods("tor", tor, 900, 240, 0.9, ao_dist=1.0)
    for o in bpy.data.objects:
        for p in o.data.polygons:
            p.use_smooth = o.data.materials[0].name != "basalt"
    export_glb(os.path.abspath(out))


main()
