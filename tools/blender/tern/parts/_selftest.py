"""Toolkit self-test: material swatches + a panelized subdivision blob."""
import math

import bmesh

import kit
import mats
from kit import V


def demo():
    col = kit.collection("SelfTest")
    names = ["paint_white", "paint_dark", "paint_accent", "metal_dark", "metal_steel", "metal_chrome", "metal_heat",
             "rubber", "glass_dark", "ceramic", "metal_brass", "inner_dark"]
    objs = []
    for i, n in enumerate(names):
        bm = kit.box((0.5, 0.5, 0.5), bevel=0.02)
        kit.cylinder(0.14, 0.25, 0.42, 32, chamfer=0.01, bm=bm)
        kit.torus(0.19, 0.03, 32, 10, bm=bm, mx=kit.T(0, 0, 0.27))
        ob = kit.to_obj("sw_" + n, bm, col, [mats.get(n)])
        ob.location = ((i % 6) * 0.75 - 1.9, 3.2 - (i // 6) * 0.75, 0.25)
        objs.append(ob)

    # panelized blob: capsule-ish loft, subdivided
    rings = []
    for k in range(9):
        y = -2.0 + k * 0.5
        s = 0.35 + 0.65 * math.sin(math.pi * (k + 0.6) / 9.2)
        rings.append([V((s * 1.2 * math.cos(a), y, 0.6 + s * 0.6 * math.sin(a))) for a in
                      [math.tau * j / 12 for j in range(12)]])
    bm, _ = kit.loft(rings)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    tmp = kit.to_obj("blob_cage", bm, col, smooth=None)
    kit.mod_subsurf(tmp, 3)
    kit.apply_mods(tmp)
    bm = kit.bm_from_obj(tmp)
    under = bm.copy()
    import bpy
    bpy.data.objects.remove(tmp)

    pz = kit.Panelizer(bm)
    for y in (-1.2, -0.4, 0.4, 1.2):
        pz.plane((0, y, 0), (0, 1, 0))
    pz.plane((0, 0, 0.6), (0, 0, 1))
    pz.plane((0, 0, 0), (1, 0, 0))
    pz.base = lambda C, N: (np_floor(C[:, 1] / 0.8 + 10) * 8 + (C[:, 2] > 0.6) * 2 + (C[:, 0] > 0)).astype(int)
    top = kit.frame((0, 0, 0), (0, 0, 1), (1, 0, 0))
    pz.region(top, kit.chamfer_rect2(0.7, 1.0, 0.12, 0.0, 0.3), depth=(0.6, 5), paint=2, name="hatch", gap=0.01)
    pz.region(top, kit.chamfer_rect2(0.5, 0.5, 0.08, 0.0, -0.9), depth=(0.6, 5), paint=1, offset=0.012, name="plate")
    side = kit.frame((0, 0, 0.6), (1, 0, 0), (0, 1, 0))
    pz.region(side, kit.rect2(0.9, 0.22, 0.0, 0.05), depth=(0.0, 5), remove=True, name="vent")
    pz.region(side, kit.ngon2(12, 0.16, 0, -1.0, 0.0), depth=(0.0, 5), paint=3, name="port", gap=0.008)
    pz.run()
    print("PANEL LOG", pz.log)
    skin, un = kit.skin_objects("blob", bm, col, [mats.get("hull_paint")], under=under, under_mat=mats.get("inner_dark"))
    objs += [skin, un]
    return objs


def np_floor(a):
    import numpy as np
    return np.floor(a)


def demo_swatches():
    return demo()[:12]


def demo_blob():
    return demo()[12:]


def demo_zoom():
    demo()
    bm = kit.box((0.9, 0.7, 0.3), center=(0.25, 0.45, 1.1))
    ob = kit.to_obj("zoom_box", bm)
    ob.hide_render = True
    return [ob]
