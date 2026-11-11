"""Preview of the hangar bay with a stand-in ship.

    blender -b --factory-startup -P tools/blender/tern/parts/hangar_preview.py -- [--res=960x540] [--samples=96]
        [--views=front34,rear34,side_low,top34] [--lights=1.0] [--nokey] [--out=<dir>] [--blend]

Writes build/tern/parts/hangar/<view>.png and sheet.png.
"""
import math
import os
import sys
import time

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
TERN = os.path.dirname(HERE)
ROOT = os.path.abspath(os.path.join(TERN, "..", "..", ".."))
sys.path[:0] = [TERN, HERE]

import bmesh   # noqa: E402
import kit     # noqa: E402
import mats    # noqa: E402
import studio  # noqa: E402
import hangar  # noqa: E402
from mathutils import Vector  # noqa: E402

G = -2.6

# name: (horizontal direction target->eye, horizontal distance, eye height above floor, target, lens)
VIEWS = {
    "front34": ((0.62, 1.0), 26.0, 2.2, (0.0, 0.3, G + 2.0), 50.0),
    "rear34": ((-0.72, -1.0), 26.0, 5.0, (0.0, -0.5, G + 1.8), 50.0),
    "side_low": ((1.0, 0.10), 27.0, 0.8, (0.0, 0.0, G + 2.4), 55.0),
    "top34": ((-0.6, 0.8), 22.0, 12.0, (0.0, 0.0, G + 1.2), 50.0),
}
# debug close-ups (not part of the default set): name -> (eye, target, lens)
DEBUG = {
    "wall": ((-16.0, -8.0, G + 3.5), (-32.0, -2.0, G + 7.5), 28.0),
    "door": ((4.0, 6.0, G + 2.5), (0.0, 32.0, G + 7.0), 24.0),
    "ceiling": ((0.0, -22.0, G + 2.0), (0.0, 4.0, G + 15.0), 24.0),
    "floor": ((13.0, 15.0, G + 1.7), (6.0, 7.0, G), 35.0),
    "plan": ((0.0, -0.5, G + 14.5), (0.0, 0.0, G), 14.0),
    "corner": ((-18.0, 12.0, G + 2.0), (-32.0, 32.0, G + 8.0), 28.0),
}


def stand_in_ship(col):
    white = mats.get("paint_white")
    dark = mats.get("metal_dark")
    rub = mats.get("rubber")
    zc = G + 2.6
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=64, v_segments=32, radius=1.0,
                              matrix=kit.T(0, 0.3, zc) @ kit.S(2.0, 7.5, 1.2))
    for s in (-1, 1):
        kit.cylinder(1.0, -3.5, 3.5, 48, chamfer=0.12, bm=bm, mx=kit.T(s * 3.55, -2.6, G + 2.4) @ kit.R("X", 90))
    kit.box((13.7, 4.2, 0.24), center=(0, -1.6, G + 2.5), bevel=0.08, segs=3, bm=bm)
    hull = kit.to_obj("StandIn_Hull", bm, col, [white], smooth=40)
    bm = bmesh.new()
    pads = bmesh.new()
    for (x, y) in ((0.0, 4.6), (-3.55, -3.2), (3.55, -3.2)):
        ztop = G + (1.6 if x == 0 else 1.5)
        kit.cylinder(0.11, G + 0.08, ztop + 0.3, 24, chamfer=0.01, bm=bm, mx=kit.T(x, y, 0))
        kit.cylinder(0.34, G, G + 0.08, 32, chamfer=0.015, bm=pads, mx=kit.T(x, y, 0))
    gear = kit.to_obj("StandIn_Gear", bm, col, [dark])
    pad = kit.to_obj("StandIn_Pads", pads, col, [rub])
    return [hull, gear, pad]


def place_cam(cam, name):
    if name in DEBUG:
        eye, tgt, lens = DEBUG[name]
        cam.location = Vector(eye)
        cam.rotation_euler = (Vector(tgt) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
        cam.data.lens = lens
        return
    d2, dist, eye, tgt, lens = VIEWS[name]
    d = Vector((d2[0], d2[1], 0.0)).normalized()
    loc = Vector((d.x * dist, d.y * dist, G + eye))
    cam.location = loc
    cam.rotation_euler = (Vector(tgt) - loc).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = lens


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opt = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))
    res = tuple(int(v) for v in opt.get("res", "960x540").split("x"))
    out = os.path.abspath(opt.get("out", os.path.join(ROOT, "build", "tern", "parts", "hangar")))
    os.makedirs(out, exist_ok=True)
    views = opt.get("views", "front34,rear34,side_low,top34").split(",")

    studio.reset()
    studio.setup_cycles(res=res, samples=int(opt.get("samples", 96)))
    col = kit.collection("Hangar")
    t0 = time.time()
    r = hangar.build_hangar(col, ground_z=G, lights=float(opt.get("lights", 1.0)))
    print("HANGAR build %.1fs  objects %d  lights %d  tris %d" % (time.time() - t0, len(r["objects"]),
                                                                  len(r["lights"]), hangar.tri_count(r["objects"])))
    scol = kit.collection("Ship")
    stand_in_ship(scol)
    studio.world(strength=0.25)
    if "nokey" not in opt:
        k = float(opt.get("key", 1.0))
        tgt = (0.0, 0.0, G + 2.4)
        kl = Vector((-9.0, 12.0, G + 10.5))
        rl = Vector((11.0, -14.0, G + 6.5))
        kd = (kl - Vector(tgt)).length
        rd = (rl - Vector(tgt)).length
        studio.area_light("Key", kl, tgt, (6.0, 4.0), 7.0 * kd * kd * k, (1.0, 0.95, 0.88), scol)
        studio.area_light("Rim", rl, tgt, (9.0, 2.5), 9.0 * rd * rd * k, (0.78, 0.88, 1.0), scol)
    cam = studio.make_camera("Cam", 50.0, scol)
    cam.data.clip_end = 300.0
    paths = []
    for v in views:
        place_cam(cam, v)
        t1 = time.time()
        paths.append(studio.render(os.path.join(out, v + ".png")))
        print("RENDER %s %.1fs" % (v, time.time() - t1))
    if len(paths) > 1:
        studio.contact_sheet(paths, os.path.join(out, "sheet.png"), 2)
    if "blend" in opt:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "scene.blend"))
    print("PREVIEW_DONE", out)


main()
