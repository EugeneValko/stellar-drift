"""Glowing crystal formations (Ignis / Vex) and ice shards (Glacia).

Run:
    blender -b -P tools/blender/crystals.py -- assets/models/crystals.glb

Objects (pivot at ground contact):
  crystal_cluster_a_lod0  ~9 hexagonal crystals radiating from a rocky base (~2 m)
  crystal_cluster_b_lod0  5 large crystals (~4 m)
  ice_shard_a_lod0        cluster of tall irregular ice blades (~5 m)
  ice_shard_b_lod0        low wide shard field (~2 m)
  ice_spire_lod0          penitente-like group of tall, thick ice blades leaning one way (4-10 m)
Material slots: crystal, ice, rock (base). Vertex colour: r = AO, g = position along the crystal
(0 base -> 1 tip; drives the glow gradient), b = per-crystal random, a = 1.
"""
import bmesh
import bpy
import math
import os
import random
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from flora_common import MeshBuilder, Vector, export_glb, out_path, reset_scene
from mathutils import Matrix

UP = Vector((0, 0, 1))


def frame(d):
    d = d.normalized()
    ref = Vector((1, 0, 0)) if abs(d.z) > 0.9 else UP
    u = d.cross(ref).normalized()
    return u, d.cross(u).normalized()


def prism(mb, base, d, length, r, sides, mat, rnd, tip_len=0.35, irregular=0.0, chip=0.0, ao_base=0.4):
    """Faceted crystal: n-gon prism + pyramidal tip. Flat facets (per-face normals)."""
    u, v = frame(d)
    rid = rnd.random()
    radii = [r * (1 + rnd.uniform(-irregular, irregular)) for _ in range(sides)]
    angs = [2 * math.pi * k / sides + rnd.uniform(-irregular, irregular) * 0.6 for k in range(sides)]
    body = length * (1 - tip_len)
    tip = base + d * length + (u * rnd.uniform(-1, 1) + v * rnd.uniform(-1, 1)) * r * chip
    ring0 = [base - d * 0.15 + (u * math.cos(a) + v * math.sin(a)) * rr * 0.92 for a, rr in zip(angs, radii)]
    ring1 = [base + d * body + (u * math.cos(a) + v * math.sin(a)) * rr for a, rr in zip(angs, radii)]
    g_body = body / length
    for k in range(sides):
        k2 = (k + 1) % sides
        a, b, c, e = ring0[k], ring0[k2], ring1[k2], ring1[k]
        n = (b - a).cross(e - a).normalized()
        ia, ib, ic, ie = mb.vert(a), mb.vert(b), mb.vert(c), mb.vert(e)
        mb.face([ia, ib, ic, ie], [(0, 0), (1, 0), (1, g_body), (0, g_body)],
                [(ao_base, 0.0, rid, 1), (ao_base, 0.0, rid, 1), (1, g_body, rid, 1), (1, g_body, rid, 1)],
                [n] * 4, mat)
        n2 = (c - e).cross(tip - e).normalized()
        it = mb.vert(tip)
        ie2, ic2 = mb.vert(e), mb.vert(c)
        mb.face([ie2, ic2, it], [(0, g_body), (1, g_body), (0.5, 1)],
                [(1, g_body, rid, 1), (1, g_body, rid, 1), (1, 1, rid, 1)], [n2] * 3, mat)


def rock_base(mb, rnd, radius, height, sides=9):
    """Low rubble mound the crystals grow out of."""
    rings = [(radius, 0.0 - 0.1), (radius * 0.75, height * 0.7), (radius * 0.3, height)]
    vs = []
    for (r, z) in rings:
        ring = []
        for s in range(sides):
            a = 2 * math.pi * s / sides + rnd.uniform(-0.15, 0.15)
            rr = r * rnd.uniform(0.8, 1.1)
            ring.append(Vector((math.cos(a) * rr, math.sin(a) * rr, z * rnd.uniform(0.8, 1.15))))
        vs.append(ring)
    top = Vector((0, 0, height * 1.05))
    for i in range(len(rings) - 1):
        for s in range(sides):
            s2 = (s + 1) % sides
            q = [vs[i][s], vs[i][s2], vs[i + 1][s2], vs[i + 1][s]]
            n = (q[1] - q[0]).cross(q[3] - q[0]).normalized()
            ao = 0.45 if i == 0 else 0.7
            mb.face([mb.vert(p) for p in q], [(0, 0), (1, 0), (1, 1), (0, 1)],
                    [(ao, 0, 0.5, 1), (ao, 0, 0.5, 1), (0.85, 0, 0.5, 1), (0.85, 0, 0.5, 1)], [n] * 4, "rock")
    for s in range(sides):
        s2 = (s + 1) % sides
        q = [vs[-1][s], vs[-1][s2], top]
        n = (q[1] - q[0]).cross(q[2] - q[0]).normalized()
        mb.face([mb.vert(p) for p in q], [(0, 0), (1, 0), (0.5, 1)], [(0.85, 0, 0.5, 1)] * 3, [n] * 3, "rock")


def crystal_cluster(seed, n, len_r, r_scale, spread_deg, base_r):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    rock_base(mb, rnd, base_r, base_r * 0.35)
    for k in range(n):
        a = rnd.uniform(0, 2 * math.pi)
        tilt = math.radians(rnd.uniform(0, spread_deg)) if k else math.radians(rnd.uniform(0, 8))
        d = Vector((math.cos(a) * math.sin(tilt), math.sin(a) * math.sin(tilt), math.cos(tilt)))
        L = rnd.uniform(*len_r) * (1.0 if k else 1.25) * (1 - 0.4 * tilt / math.radians(90))
        base = Vector((math.cos(a), math.sin(a), 0)) * base_r * 0.45 * rnd.random() + UP * base_r * 0.1
        prism(mb, base, d, L, L * r_scale * rnd.uniform(0.8, 1.2), 6, "crystal", rnd,
              tip_len=rnd.uniform(0.18, 0.3), irregular=0.08)
    return mb


def ice_cluster(seed, n, len_r, spread_deg, field_r):
    rnd = random.Random(seed)
    mb = MeshBuilder()
    for k in range(n):
        a = rnd.uniform(0, 2 * math.pi)
        rr = field_r * math.sqrt(rnd.random())
        base = Vector((math.cos(a) * rr, math.sin(a) * rr, 0))
        out = base.normalized() if rr > 0.05 else Vector((1, 0, 0))
        tilt = math.radians(rnd.uniform(5, spread_deg))
        d = (UP * math.cos(tilt) + out * math.sin(tilt)).normalized()
        L = rnd.uniform(*len_r) * (1 - 0.5 * rr / max(field_r, 1e-3))
        prism(mb, base, d, L, L * rnd.uniform(0.09, 0.16), rnd.choice([4, 5, 5, 6]), "ice", rnd,
              tip_len=rnd.uniform(0.25, 0.5), irregular=0.3, chip=0.6, ao_base=0.6)
    return mb


def ice_spires(seed, n=8, len_r=(4.0, 10.0), field_r=2.6, lean_deg=10):
    """Penitente-like group: tall, thick, tapering ice blades all leaning the same way (sun-carved)."""
    rnd = random.Random(seed)
    mb = MeshBuilder()
    lean_a = rnd.uniform(0, 2 * math.pi)
    lean = Vector((math.cos(lean_a), math.sin(lean_a), 0))
    for k in range(n):
        a = rnd.uniform(0, 2 * math.pi)
        rr = field_r * math.sqrt(rnd.random()) if k else 0.0
        base = Vector((math.cos(a) * rr, math.sin(a) * rr, 0))
        tilt = math.radians(rnd.uniform(lean_deg * 0.5, lean_deg * 1.3))
        d = (UP * math.cos(tilt) + lean * math.sin(tilt)).normalized()
        L = rnd.uniform(*len_r) * (1 - 0.45 * rr / max(field_r, 1e-3))
        prism(mb, base, d, L, L * rnd.uniform(0.12, 0.18), rnd.choice([4, 5, 5, 6]), "ice", rnd,
              tip_len=rnd.uniform(0.45, 0.7), irregular=0.35, chip=0.8, ao_base=0.55)
    return mb


def main():
    out = out_path("assets/models/crystals.glb")
    reset_scene()
    order = ["crystal", "ice", "rock"]
    crystal_cluster(5, 10, (0.7, 1.9), 0.12, 55, 0.9).build("crystal_cluster_a_lod0", order)
    crystal_cluster(9, 5, (2.2, 4.0), 0.11, 35, 1.3).build("crystal_cluster_b_lod0", order)
    ice_cluster(13, 9, (2.0, 5.5), 28, 1.4).build("ice_shard_a_lod0", order)
    ice_cluster(17, 12, (0.6, 2.0), 45, 1.8).build("ice_shard_b_lod0", order)
    ice_spires(23).build("ice_spire_lod0", order)
    export_glb(os.path.abspath(out))


main()
