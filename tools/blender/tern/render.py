"""Beauty renders of the ST-7 Tern.

    blender -b --factory-startup -P tools/blender/tern/render.py -- [--scene=hangar|studio] [--shots=hero,rear,...]
            [--res=1920x1080] [--samples=320] [--out=docs/screenshots/tern] [--blend] [--sheet] [--exposure=0]

Shots (hangar): hero, rear, front_low, side, high, engines, cockpit, gear, wing
Shots (studio): top, front, profile, back, belly
"""
import math
import os
import sys
import time

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path[:0] = [HERE, os.path.join(HERE, "parts")]

import design as D   # noqa: E402
import kit           # noqa: E402
import post          # noqa: E402
import ship          # noqa: E402
import studio        # noqa: E402
from kit import V    # noqa: E402

G = D.GROUND_Z
SHIP_LO, SHIP_HI = V((-6.9, -8.0, G)), V((6.9, 7.95, 2.75))

# name: (direction target->eye, lens, focus box or None, margin, f-stop or None)
HANGAR_SHOTS = {
    "hero": ((0.86, 1.0, -0.015), 50, None, 0.90, None),
    "rear": ((0.78, -1.0, 0.30), 50, None, 0.86, None),
    "front_low": ((0.10, 1.0, -0.035), 40, None, 0.97, None),
    "side": ((1.0, -0.06, 0.012), 50, None, 0.98, None),
    "high": ((-0.66, 0.80, 0.40), 35, None, 0.90, None),
    "engines": ((0.50, -1.0, 0.20), 70, ((-4.7, -8.0, -0.9), (4.7, -4.6, 1.7)), 1.04, 5.6),
    "cockpit": ((0.95, 0.80, 0.22), 85, ((-2.1, 1.6, -0.9), (2.1, 7.95, 1.6)), 1.03, 4.0),
    "gear": ((0.80, 1.0, -0.05), 70, ((-1.8, 3.0, G), (2.2, 7.95, 0.3)), 1.05, 4.0),
    "wing": ((1.0, 0.35, 0.30), 70, ((2.2, -6.9, -1.0), (6.9, 1.9, 2.75)), 1.04, 5.6),
}
STUDIO_SHOTS = {
    "top": ((0.0, -0.001, 1.0), 85, None, 1.05, None),
    "front": ((0.0, 1.0, 0.03), 85, None, 1.06, None),
    "profile": ((1.0, 0.0, 0.03), 85, None, 1.05, None),
    "back": ((0.0, -1.0, 0.06), 85, None, 1.06, None),
    "three_quarter": ((0.66, 1.0, 0.34), 85, None, 1.04, None),
}


def options():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


def hangar_scene(col, opt):
    import hangar
    hcol = kit.collection("Hangar")
    hangar.build_hangar(hcol, ground_z=G, lights=float(opt.get("lights", 1.0)), props="noprops" not in opt)
    studio.world(top=(0.004, 0.005, 0.007), horizon=(0.010, 0.011, 0.014), strength=1.0)
    k = float(opt.get("key", 1.0))
    lcol = kit.collection("Lights")
    c = V((0.0, -0.3, -0.2))
    studio.area_light("Key", (11.0, 13.0, 10.5), c, (8.0, 4.5), 4600.0 * k, (1.0, 0.95, 0.88), lcol)
    studio.area_light("Rim", (-11.0, -14.0, 11.5), c, (8.0, 2.6), 4200.0 * k, (0.72, 0.84, 1.0), lcol)
    studio.area_light("RimR", (14.0, -10.0, 9.5), c, (5.0, 2.4), 1700.0 * k, (0.80, 0.90, 1.0), lcol)
    studio.area_light("Fill", (-14.0, 9.0, 4.0), c, (9.0, 6.0), 800.0 * k, (0.85, 0.90, 1.0), lcol)
    studio.area_light("Belly", (0.0, 2.0, G + 0.25), (0.0, 0.0, 0.0), (8.0, 11.0), 150.0 * k, (0.9, 0.95, 1.0), lcol)


def studio_scene(col, opt):
    studio.world(top=(0.012, 0.014, 0.018), horizon=(0.045, 0.050, 0.060), strength=1.0)
    studio.studio_rig(SHIP_LO, SHIP_HI)


def main():
    opt = options()
    t0 = time.time()
    scene_name = opt.get("scene", "hangar")
    shots = HANGAR_SHOTS if scene_name == "hangar" else STUDIO_SHOTS
    names = opt.get("shots", ",".join(shots)).split(",")
    res = tuple(int(v) for v in opt.get("res", "1920x1080").split("x"))
    out = os.path.abspath(opt.get("out", os.path.join(ROOT, "docs", "screenshots", "tern")))
    sc = studio.reset()
    studio.setup_cycles(res=res, samples=int(opt.get("samples", 320)), exposure=float(opt.get("exposure", 0.0)))
    sc = bpy.context.scene
    sc.cycles.adaptive_threshold = float(opt.get("noise", 0.012))
    sc.render.use_persistent_data = True
    col = kit.collection("Tern")
    ship.build(col, opt)
    print("BUILD %.1fs" % (time.time() - t0))
    (hangar_scene if scene_name == "hangar" else studio_scene)(col, opt)
    if "nopost" not in opt:
        post.setup(bloom=float(opt.get("bloom", 0.10)), threshold=float(opt.get("threshold", 2.5)),
                   vignette=float(opt.get("vignette", 0.25)))
    if "blend" in opt:
        os.makedirs(os.path.join(ROOT, "build", "tern"), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT, "build", "tern", "tern_%s.blend" % scene_name))
    cam = studio.make_camera()
    paths = []
    for n in names:
        d, lens, box, margin, fstop = shots[n]
        cam.data.lens = lens
        lo, hi = (V(box[0]), V(box[1])) if box else (SHIP_LO, SHIP_HI)
        studio.aim_camera(cam, lo, hi, d, margin)
        if scene_name == "hangar":   # keep the camera inside the hall and above the floor
            cam.location.z = max(cam.location.z, G + 0.35)
        cam.data.dof.use_dof = fstop is not None
        if fstop is not None:
            cam.data.dof.focus_distance = (cam.location - (lo + hi) / 2).length
            cam.data.dof.aperture_fstop = fstop
        t1 = time.time()
        paths.append(studio.render(os.path.join(out, "tern_%s.png" % n)))
        print("SHOT %s %.1fs cam=%s dist=%.1f" % (n, time.time() - t1, tuple(round(v, 1) for v in cam.location),
                                                  cam.location.length))
    if "sheet" in opt and len(paths) > 1:
        studio.contact_sheet(paths, os.path.join(out, "sheet_%s.png" % scene_name), cols=int(opt.get("cols", 2)))
    print("DONE %.1fs" % (time.time() - t0))


main()
