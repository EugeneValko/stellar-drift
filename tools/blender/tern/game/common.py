"""Shared helpers for the game-ready Tern pipeline (paths, options, mesh utilities)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TERN = os.path.dirname(HERE)
ROOT = os.path.abspath(os.path.join(TERN, "..", "..", ".."))
for p in (HERE, os.path.join(TERN, "parts"), TERN):
    if p not in sys.path:
        sys.path.insert(0, p)

import bmesh  # noqa: E402
import bpy  # noqa: E402

BUILD = os.path.join(ROOT, "build", "tern", "game")
ASSETS = os.path.join(ROOT, "assets", "models", "tern")
TEX = 4096


def options():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


def tris(me):
    return sum(len(p.vertices) - 2 for p in me.polygons)


def ensure_dirs():
    os.makedirs(BUILD, exist_ok=True)
    os.makedirs(ASSETS, exist_ok=True)
    gd = os.path.join(ROOT, "build", "tern", ".gdignore")
    if not os.path.exists(gd):
        open(gd, "w").close()


def mesh_obj(name, bm, col, mats=()):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    for m in mats:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    col.objects.link(ob)
    return ob


def triangulate(bm):
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")


def smooth_with_sharp(me, angle_deg=None, seam_only=False):
    """All faces smooth; edges sharper than angle (optionally only those that are UV seams) marked sharp."""
    import math
    me.shade_smooth()
    if angle_deg is None:
        return
    bm = bmesh.new()
    bm.from_mesh(me)
    lim = math.radians(angle_deg)
    for e in bm.edges:
        sharp = False
        if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > lim:
            sharp = (not seam_only) or e.seam
        e.smooth = not sharp
    for f in bm.faces:
        f.smooth = True
    bm.to_mesh(me)
    bm.free()


def no_rays(ob):
    """Invisible for every Cycles ray type (low-poly bake targets must not occlude the AO of the high-poly)."""
    for k in ("visible_camera", "visible_diffuse", "visible_glossy", "visible_transmission", "visible_volume_scatter",
              "visible_shadow"):
        setattr(ob, k, False)
