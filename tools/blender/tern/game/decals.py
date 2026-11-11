"""Decals for the game Tern: one RGBA atlas (colour baked in RGB, weathered mask in alpha) and thin conforming
quads rebuilt on the LOW surface from the placement data of ship.Body.decal()."""
import math
import os

import bmesh
import bpy
import numpy as np
from mathutils import Vector

import bake
import common as C
import ship

ATLAS = 2048
LIFT = 0.004
BIG = {"txt_st7", "txt_07", "emblem"}           # the only decals kept at LOD2
SMALL_W = 0.35                                    # LOD1 drops decals narrower than this


def collect(bodies):
    """[(body name, proj, pt, width, image, rot, colour, nx, ny)] from the captured ship.Body objects."""
    out = []
    for b in bodies:
        for d in b.decals:
            out.append((b.name,) + tuple(d))
    return out


def _noise(h, w, seed, cell):
    rng = np.random.default_rng(seed)
    gh, gw = h // cell + 2, w // cell + 2
    g = rng.random((gh, gw)).astype(np.float32)
    yy = np.linspace(0, gh - 1.001, h)
    xx = np.linspace(0, gw - 1.001, w)
    y0, x0 = yy.astype(int), xx.astype(int)
    fy, fx = (yy - y0)[:, None], (xx - x0)[None, :]
    fy, fx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    a = g[y0][:, x0]
    b = g[y0][:, x0 + 1]
    c = g[y0 + 1][:, x0]
    d = g[y0 + 1][:, x0 + 1]
    return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy


def build_atlas(entries, path):
    """Shelf-pack every (image, colour) pair. Returns {(image, colour): (u0, v0, u1, v1)}."""
    keys = []
    for e in entries:
        k = (e[4], tuple(round(c, 4) for c in e[6]))
        if k not in keys:
            keys.append(k)
    srcs = {}
    for img_name, _c in keys:
        if img_name not in srcs:
            im = bpy.data.images.load(os.path.join(ship.DECAL_DIR, img_name + ".png"), check_existing=True)
            w, h = im.size
            a = np.empty(w * h * 4, dtype=np.float32)
            im.pixels.foreach_get(a)
            srcs[img_name] = a.reshape(h, w, 4)
    # scale every source so that 1 m of decal width gets the same pixel count, capped by the atlas
    ppm = 700.0
    widths = {}
    for e in entries:
        widths[e[4]] = max(widths.get(e[4], 0.0), e[3])
    items = []
    for k in keys:
        src = srcs[k[0]]
        h0, w0 = src.shape[:2]
        w = int(min(w0, max(64, widths[k[0]] * ppm)))
        h = max(16, int(round(w * h0 / w0)))
        items.append((k, w, h))
    items.sort(key=lambda t: -t[2])
    atlas = np.zeros((ATLAS, ATLAS, 4), dtype=np.float32)
    pad = 24
    x = y = shelf = 0
    rects = {}
    for k, w, h in items:
        if x + w + pad > ATLAS:
            x, y = 0, y + shelf + pad
            shelf = 0
        if y + h > ATLAS:
            raise RuntimeError("decal atlas overflow")
        src = srcs[k[0]]
        h0, w0 = src.shape[:2]
        ys = (np.arange(h) * h0 / h).astype(int)
        xs = (np.arange(w) * w0 / w).astype(int)
        # box-filter downsample (average of the source block) for clean small labels
        sy, sx = max(1, h0 // h), max(1, w0 // w)
        acc = np.zeros((h, w), dtype=np.float32)
        for dy in range(sy):
            for dx in range(sx):
                acc += src[np.clip(ys + dy, 0, h0 - 1)][:, np.clip(xs + dx, 0, w0 - 1), 3]
        mask = acc / (sy * sx)
        seed = sum(ord(ch) for ch in k[0])
        chips = np.clip((_noise(h, w, seed, 4) - 0.06) / 0.12, 0, 1)
        fade = 0.80 + 0.30 * (_noise(h, w, seed + 7, 60) - 0.5)
        alpha = np.clip(mask * chips * fade / 0.85, 0, 1)
        col = np.array(k[1], dtype=np.float32)
        block = atlas[y:y + h, x:x + w]
        block[..., :3] = bake.srgb(col)[None, None, :]
        block[..., 3] = alpha
        # bleed the colour into the padding so mip-mapping never pulls in black
        atlas[max(0, y - pad // 2):y + h + pad // 2, max(0, x - pad // 2):x + w + pad // 2, :3] = bake.srgb(col)
        atlas[y:y + h, x:x + w, 3] = alpha
        rects[k] = ((x + 0.5) / ATLAS, (y + 0.5) / ATLAS, (x + w - 0.5) / ATLAS, (y + h - 0.5) / ATLAS)
        x += w + pad
        shelf = max(shelf, h)
    bake.write_png(path, atlas)
    return rects


def build_quads(entries, rects, bvhs, lod, col, mat):
    """Conforming decal grids on the low surface of one LOD. bvhs: body name -> BVHTree of that LOD's body."""
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.new("UVMap")
    step = {0: 0.05, 1: 0.12, 2: 0.25}[lod]
    kept = 0
    for (bname, proj, pt, width, image, rot, color, nx, ny) in entries:
        if lod == 2 and image not in BIG:
            continue
        if lod == 1 and width < SMALL_W and image not in BIG:
            continue
        bvh = bvhs.get(bname)
        if bvh is None:
            continue
        h = width / ship._aspect(image)
        nx = max(2, int(math.ceil(width / step)))
        ny = max(1, int(math.ceil(h / step)))
        u0, v0, u1, v1 = rects[(image, tuple(round(c, 4) for c in color))]
        cx, cy = proj.fn(pt)
        ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))
        zax = proj.mx.to_3x3() @ Vector((0, 0, 1))
        grid = {}
        for j in range(ny + 1):
            for i in range(nx + 1):
                a, c = (i / nx - 0.5) * width, (j / ny - 0.5) * h
                o = proj.mx @ Vector((cx + a * ca - c * sa, cy + a * sa + c * ca, 60.0))
                loc, nrm, _i, _d = bvh.ray_cast(o, -zax)
                if loc is None:
                    continue
                if nrm.dot(zax) < 0:     # hit a back face: flip so the lift goes outwards
                    nrm = -nrm
                grid[(i, j)] = (bm.verts.new(loc + nrm * LIFT), (u0 + (u1 - u0) * i / nx, v0 + (v1 - v0) * j / ny))
        for j in range(ny):
            for i in range(nx):
                q = [grid.get(k) for k in ((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1))]
                if None in q:
                    continue
                f = bm.faces.new([v for v, _ in q])
                f.normal_update()
                if f.normal.dot(zax) < 0:
                    f.normal_flip()
                for lp in f.loops:
                    for v, t in q:
                        if v is lp.vert:
                            lp[uvl].uv = t
        kept += 1
    C.triangulate(bm)
    me = bpy.data.meshes.new("Decals")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    ob = bpy.data.objects.new("Decals", me)
    col.objects.link(ob)
    me.shade_smooth()
    print("DECALS lod%d: %d decals, %d tris" % (lod, kept, C.tris(me)))
    return ob
