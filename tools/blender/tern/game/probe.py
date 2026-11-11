"""Inspect the built high-poly Tern: objects, meshes, triangle counts, materials (debug helper)."""
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
TERN = os.path.dirname(HERE)
sys.path[:0] = [TERN, os.path.join(TERN, "parts")]

import bpy  # noqa: E402
import kit  # noqa: E402
import ship  # noqa: E402
import studio  # noqa: E402

studio.reset()
col = kit.collection("Tern")
objs = ship.build(col, {})
bpy.context.view_layer.update()


def tris(me):
    return sum(len(p.vertices) - 2 for p in me.polygons)


users = defaultdict(list)
for ob in col.objects:
    if ob.type == "MESH":
        users[ob.data.name].append(ob.name)
print("==== OBJECTS (non-instanced)")
tot = 0
for ob in sorted(col.objects, key=lambda o: o.name):
    if ob.type != "MESH":
        continue
    t = tris(ob.data)
    tot += t
    if len(users[ob.data.name]) == 1:
        print("OBJ %-34s mesh=%-28s tris=%7d mats=%s" % (ob.name, ob.data.name, t, [m.name for m in ob.data.materials]))
print("==== INSTANCED MESHES")
for me, names in sorted(users.items()):
    if len(names) > 1:
        m = bpy.data.meshes[me]
        print("MESH %-28s x%-3d tris=%6d mats=%s  e.g. %s" % (me, len(names), tris(m), [x.name for x in m.materials], names[:3]))
print("TOTAL tris", tot)
print("==== TEMPLATES")
for ob in bpy.data.collections["TernTemplates"].objects:
    print("TPL %-30s tris=%6d props=%s" % (ob.name, tris(ob.data), {k: ob[k] for k in ob.keys()}))
print("==== MATERIALS")
for m in bpy.data.materials:
    kinds = sorted({n.bl_idname for n in m.node_tree.nodes}) if m.node_tree else []
    print("MAT %-28s users=%d %s" % (m.name, m.users, kinds))
