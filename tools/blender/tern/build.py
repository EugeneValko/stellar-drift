"""Build the ST-7 Tern.

    blender -b --factory-startup -P tools/blender/tern/build.py -- [--stage=blockout|ship] [--out=build/tern]
            [--views=front34,rear34,side,top] [--res=960x540] [--samples=48] [--clay] [--blend] [--cols=2]
"""
import os
import sys
import time

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path[:0] = [HERE, os.path.join(HERE, "parts")]

import design   # noqa: E402
import kit      # noqa: E402
import mats     # noqa: E402
import studio   # noqa: E402
from kit import V  # noqa: E402


def options():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in argv if a.startswith("--"))


def blockout(col):
    objs = []
    glass = mats.get("glass_dark")
    for name, bm in design.bodies(3).items():
        if name == "fuselage":   # rough canopy preview
            poly = design.CANOPY
            for f in bm.faces:
                c = f.calc_center_median()
                inside = all(((poly[(i + 1) % 4][0] - poly[i][0]) * (c.z - poly[i][1]) -
                              (poly[(i + 1) % 4][1] - poly[i][1]) * (c.y - poly[i][0])) <= 0 for i in range(4))
                if inside:
                    f.material_index = 1
        m = "metal_dark" if name.startswith("spike") else "paint_white"
        objs.append(kit.to_obj(name, bm, col, [mats.get(m), glass], smooth=40.0, recalc=False))
    return objs


def main():
    opt = options()
    t0 = time.time()
    out = os.path.abspath(opt.get("out", os.path.join(ROOT, "build", "tern")))
    res = tuple(int(v) for v in opt.get("res", "960x540").split("x"))
    studio.reset()
    studio.setup_cycles(res=res, samples=int(opt.get("samples", 48)))
    col = kit.collection("Tern")
    stage = opt.get("stage", "ship")
    if stage == "blockout":
        objs = blockout(col)
    else:
        import ship
        objs = ship.build(col, opt)
    print("BUILD %.1fs, %d objects" % (time.time() - t0, len(objs)))
    lo, hi = kit.bbox_world(objs)
    lo.z = min(lo.z, design.GROUND_Z)
    studio.world()
    studio.studio_rig(lo, hi)
    if "clay" in opt:
        studio.clay_override(True)
    if "blend" in opt:
        os.makedirs(out, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "tern_%s.blend" % stage))
    views = opt.get("views", "front34,rear34,side,top").split(",")
    if "focus" in opt:   # frame only a sub-box: x0,y0,z0,x1,y1,z1
        f = [float(v) for v in opt["focus"].split(",")]
        lo, hi = V(f[:3]), V(f[3:])
    if views != ["none"]:
        studio.render_views(os.path.join(out, opt.get("tag", stage)), lo, hi, views, lens=float(opt.get("lens", 85)),
                            margin=float(opt.get("margin", 1.06)), cols=int(opt.get("cols", 2)))
    print("DONE %.1fs size %s" % (time.time() - t0, tuple(round(v, 2) for v in (hi - lo))))


main()
