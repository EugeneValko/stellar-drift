"""Side-by-side check of the game Tern against the hero model, same studio light and cameras.

    blender -b --factory-startup -P tools/blender/tern/game/verify.py -- --mode=high|lod0|lod1|lod2
            [--shots=front34,rear34,cockpit,engines] [--res=1280x720] [--samples=64]
    blender -b --factory-startup -P tools/blender/tern/game/verify.py -- --sheet=front34,rear34 [--modes=high,lod0]
Output: build/tern/game/verify/<mode>_<shot>.png, sheets cmp_<shot>.png (left high, right game).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

import bpy  # noqa: E402
from mathutils import Vector as V  # noqa: E402

import design as D  # noqa: E402
import kit  # noqa: E402
import studio  # noqa: E402

G = D.GROUND_Z
LO, HI = V((-6.9, -8.0, G)), V((6.9, 7.95, 2.75))
SHOTS = {  # direction, lens, box, margin
    "front34": ((0.86, 1.0, 0.12), 50, None, 0.95),
    "rear34": ((0.78, -1.0, 0.30), 50, None, 0.92),
    "cockpit": ((0.95, 0.80, 0.22), 85, ((-2.1, 1.6, -0.9), (2.1, 7.95, 1.6)), 1.03),
    "engines": ((0.50, -1.0, 0.20), 70, ((-4.7, -8.0, -0.9), (4.7, -4.6, 1.7)), 1.04),
    "belly": ((0.55, 0.75, -0.55), 50, None, 0.95),
    "port34": ((-0.86, 0.9, 0.25), 50, None, 0.95),
    "far1": ((0.86, 1.0, 0.25), 50, None, 3.2),
    "far2": ((0.86, 1.0, 0.25), 50, None, 7.0),
}
OUT = os.path.join(C.BUILD, "verify")


def scene(mode):
    studio.reset()
    col = kit.collection("Tern")
    if mode == "high":
        import ship
        ship.build(col, {})
    else:
        path = os.path.join(C.ASSETS, "tern_%s.gltf" % mode)
        bpy.ops.import_scene.gltf(filepath=path)
    studio.world(top=(0.012, 0.014, 0.018), horizon=(0.045, 0.050, 0.060), strength=1.0)
    studio.studio_rig(LO, HI)


def main():
    opt = C.options()
    os.makedirs(OUT, exist_ok=True)
    if "sheet" in opt:
        modes = opt.get("modes", "high,lod0").split(",")
        for s in opt["sheet"].split(","):
            paths = [os.path.join(OUT, "%s_%s.png" % (m, s)) for m in modes]
            paths = [p for p in paths if os.path.exists(p)]
            if len(paths) > 1:
                studio.contact_sheet(paths, os.path.join(OUT, "cmp_%s_%s.png" % (s, "_".join(modes))), cols=len(paths))
        return
    mode = opt.get("mode", "lod0")
    res = tuple(int(v) for v in opt.get("res", "1280x720").split("x"))
    scene(mode)
    studio.setup_cycles(res=res, samples=int(opt.get("samples", 64)))
    cam = studio.make_camera()
    for s in opt.get("shots", "front34,rear34,cockpit,engines").split(","):
        d, lens, box, margin = SHOTS[s]
        cam.data.lens = lens
        lo, hi = (V(box[0]), V(box[1])) if box else (LO, HI)
        studio.aim_camera(cam, lo, hi, d, margin)
        studio.render(os.path.join(OUT, "%s_%s.png" % (mode, s)))
        print("VERIFY", mode, s)


main()
