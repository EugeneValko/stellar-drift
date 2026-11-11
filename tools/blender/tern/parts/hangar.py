"""Hangar bay presentation environment for the Tern beauty renders.

    import hangar
    res = hangar.build_hangar(col, ground_z=-2.6, size=64.0, height=17.0, lights=1.0)
    res["objects"], res["lights"]

Square hall `size` x `size` (inner wall faces at +-size/2), `height` tall, floor at z = ground_z.
The ship stands at the origin (nose +Y). The +Y wall holds the big closed hangar door.
Keep-clear zone: nothing is placed inside |x| < 9 m and |y| < 10 m (floor paint only).
Everything is procedural (object-space shaders, no UVs, no images) and deterministic.
Exception to the PARTS_GUIDE "one object" rule: the hall is a handful of joined objects
(floor, 4 walls, ceiling, emissive light objects, props).
"""
import math
import random

import bmesh
import bpy

import kit
import mats
from kit import V, T, R

NB = mats.NB


# ------------------------------------------------------------------------------------------
# materials
# ------------------------------------------------------------------------------------------
def _surf(name, color, rough, metallic=0.0, coat=0.0, wear=0.3, grime=0.6, micro=0.6, bevel=0.015):
    return mats.surface(name, color, rough, metallic, coat, wear, grime, micro=micro, bevel=bevel)


_LOCAL = {
    # walls: dark blue-grey painted steel, low contrast
    "wall":     lambda: _surf("hg_wall", (0.040, 0.047, 0.058), 0.58, 0.0, 0.05, 0.20, 0.70, bevel=0.02),
    "wall2":    lambda: _surf("hg_wall2", (0.050, 0.058, 0.070), 0.52, 0.0, 0.08, 0.30, 0.60, bevel=0.015),
    "panel":    lambda: _surf("hg_panel", (0.060, 0.068, 0.080), 0.48, 0.0, 0.10, 0.35, 0.55, bevel=0.015),
    "frame":    lambda: _surf("hg_frame", (0.030, 0.034, 0.041), 0.46, 0.25, 0.0, 0.45, 0.70, bevel=0.02),
    "hatch":    lambda: _surf("hg_hatch", (0.085, 0.090, 0.095), 0.45, 0.0, 0.10, 0.55, 0.60, bevel=0.012),
    "door":     lambda: _surf("hg_door", (0.072, 0.078, 0.086), 0.46, 0.0, 0.10, 0.50, 0.60, bevel=0.02),
    "concrete": lambda: _surf("hg_concrete", (0.055, 0.055, 0.054), 0.80, 0.0, 0.0, 0.0, 0.85, micro=1.5,
                              bevel=0.02),
    "grate":    lambda: _surf("hg_grate", (0.028, 0.029, 0.031), 0.50, 0.8, 0.0, 0.40, 0.80, bevel=0.01),
    "ceiling":  lambda: _surf("hg_ceiling", (0.024, 0.026, 0.030), 0.62, 0.0, 0.0, 0.10, 0.60, bevel=0.02),
    "pipe_teal": lambda: _surf("hg_pipe_teal", (0.022, 0.045, 0.048), 0.40, 0.0, 0.15, 0.40, 0.60, bevel=0.01),
    "pipe_ochre": lambda: _surf("hg_pipe_ochre", (0.090, 0.062, 0.020), 0.42, 0.0, 0.15, 0.40, 0.60, bevel=0.01),
    "stripe":   lambda: _stripe_mat("hg_stripe"),
    "floor":    lambda: _floor_mat("hg_floor"),
}


def _mat(key):
    if key in _LOCAL:
        return _LOCAL[key]()
    return mats.get(key)


def _emit_mat(name, color, strength):
    """Emission material whose strength is (re)set on every call (the `lights` multiplier)."""
    m = bpy.data.materials.get(name) or mats.emissive(name, color, strength)
    e = next(n for n in m.node_tree.nodes if n.type == "EMISSION")
    e.inputs["Strength"].default_value = strength
    return m


def _stripe_mat(name, period=0.62):
    """Yellow / black 45-degree hazard stripes in object space (x + y + z), on the shared surface group."""
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    b = NB(nt)
    out = b.new("ShaderNodeOutputMaterial")
    tc = b.new("ShaderNodeTexCoord").outputs["Object"]
    sep = b.new("ShaderNodeSeparateXYZ")
    b.set(sep.inputs[0], tc)
    t = b.math("DIVIDE", b.math("ADD", b.math("ADD", sep.outputs[0], sep.outputs[1]), sep.outputs[2]), period)
    tw = b.math("ABSOLUTE", b.math("SUBTRACT", b.math("FRACT", t), 0.5))
    s = b.smooth(tw, 0.235, 0.265)
    col = b.mixc(s, (0.54, 0.34, 0.025, 1.0), (0.016, 0.016, 0.018, 1.0))
    g = b.new("ShaderNodeGroup", node_tree=mats.surface_group())
    b.set(g.inputs["Color"], col)
    vals = {"Roughness": 0.48, "Metallic": 0.0, "Coat": 0.05, "Wear": 0.75, "Grime": 0.75, "Micro": 0.8,
            "Bevel": 0.015}
    for k, v in vals.items():
        g.inputs[k].default_value = v
    nt.links.new(g.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (0.4, 0.3, 0.05, 1.0)
    return m


def _floor_mat(name):
    """Dark sealed concrete / resin deck with slab joints, damp polished patches, stains, tyre marks,
    speckle and worn painted markings (landing circle, ticks, hazard chevron square, guide lines, boxes).
    Object space = world XY (the floor object sits at the origin, z offset only)."""
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    b = NB(nt)
    out = b.new("ShaderNodeOutputMaterial")
    M = b.math
    tc = b.new("ShaderNodeTexCoord").outputs["Object"]
    sep = b.new("ShaderNodeSeparateXYZ")
    b.set(sep.inputs[0], tc)
    x, y = sep.outputs[0], sep.outputs[1]
    P = b.mapping(tc, loc=(0.0, 0.0, 0.37))          # noise domain, off the lattice plane

    def mul(a, c):
        return M("MULTIPLY", a, c)

    def add(a, c):
        return M("ADD", a, c)

    def sub(a, c):
        return M("SUBTRACT", a, c)

    def ab(a):
        return M("ABSOLUTE", a)

    def mx(*a):
        r = a[0]
        for c in a[1:]:
            r = M("MAXIMUM", r, c)
        return r

    def gt(v, c, aa=0.006):
        return b.smooth(v, c - aa, c + aa)

    def lt(v, c, aa=0.006):
        return sub(1.0, b.smooth(v, c - aa, c + aa))

    def band(d, hw, aa=0.006):            # 1 where |d| < hw (d already >= 0)
        return lt(d, hw, aa)

    def between(v, a, c, aa=0.006):
        return mul(gt(v, a, aa), lt(v, c, aa))

    def inv(a):
        return sub(1.0, a)

    ax, ay = ab(x), ab(y)

    # ---- noise fields ------------------------------------------------------------------
    n_big = b.noise(P, 0.045, 3.0, 0.5)
    n_mid = b.noise(P, 0.6, 5.0, 0.6)
    n_fine = b.noise(P, 7.0, 4.0, 0.6)
    n_micro = b.noise(P, 90.0, 2.0, 0.5)

    # ---- slab joints (4 m grid) ------------------------------------------------------------
    def jdist(c):
        f = M("FRACT", M("DIVIDE", c, 4.0))
        return mul(sub(0.5, ab(sub(f, 0.5))), 4.0)
    j = M("MINIMUM", jdist(x), jdist(y))
    jw = add(0.0095, mul(sub(n_fine, 0.5), 0.006))
    # soft step with a variable edge: 1 - clamp((j - jw) / 0.005 + 0.5)
    groove = M("SUBTRACT", 1.0, M("ADD", M("DIVIDE", sub(j, jw), 0.005), 0.5, clamp=True), clamp=True)
    joint_dirt = mul(band(j, 0.05, 0.06), add(0.4, mul(n_mid, 0.6)))
    cmb = b.new("ShaderNodeCombineXYZ")
    b.set(cmb.inputs[0], M("FLOOR", M("DIVIDE", x, 4.0)))
    b.set(cmb.inputs[1], M("FLOOR", M("DIVIDE", y, 4.0)))
    wn = b.new("ShaderNodeTexWhiteNoise", noise_dimensions="3D")
    b.set(wn.inputs["Vector"], cmb.outputs[0])
    srand = wn.outputs["Value"]

    # ---- dirt / stains / dust / speckle -------------------------------------------------
    dust = b.smooth(b.noise(P, 0.11, 5.0, 0.6), 0.56, 0.80)
    P2 = b.mapping(tc, loc=(13.1, -7.7, 2.9))
    stain = b.smooth(b.noise(P2, 0.33, 6.0, 0.62, distortion=0.8), 0.62, 0.76)
    sp_light = b.smooth(b.noise(P, 48.0, 1.0, 0.5), 0.70, 0.74)
    sp_dark = b.smooth(b.noise(P2, 33.0, 1.0, 0.5), 0.70, 0.75)

    # tyre / skid marks: iso-contours of strongly stretched noise, in sparse patches
    def tyre(rot_z, sx, sy, off, lane):
        v = b.mapping(tc, loc=off, rot=(0.0, 0.0, rot_z))
        v = b.mapping(v, scale=(sx, sy, 1.0))
        tn = b.noise(v, 1.0, 1.0, 0.5)
        mark = lt(ab(sub(tn, 0.5)), 0.045, 0.02)
        patch = b.smooth(b.noise(b.mapping(tc, loc=off), 0.09, 2.0, 0.5), 0.46, 0.62)
        return mul(mul(mark, patch), lane)
    lane = lt(ax, 7.5, 2.5)
    tyre_a = tyre(0.04, 0.55, 0.035, (3.3, 1.1, 5.0), lane)
    tyre_b = tyre(0.62, 0.50, 0.04, (-7.0, 4.4, 2.0), 0.6)
    tyres = mx(tyre_a, tyre_b)
    tyres = mul(tyres, add(0.55, mul(n_fine, 0.45)))

    # ---- damp / polished patches -> roughness ----------------------------------------------
    wetn = add(mul(b.noise(P, 0.065, 4.0, 0.55), 0.62), mul(b.noise(P2, 0.42, 4.0, 0.55), 0.38))
    wet = b.smooth(wetn, 0.45, 0.56)

    # ---- painted markings -------------------------------------------------------------------
    cxy = b.new("ShaderNodeCombineXYZ")
    b.set(cxy.inputs[0], x)
    b.set(cxy.inputs[1], y)
    vl = b.new("ShaderNodeVectorMath", operation="LENGTH")
    b.set(vl.inputs[0], cxy.outputs[0])
    r = vl.outputs["Value"]

    ring = band(ab(sub(r, 9.5)), 0.14)
    inner = band(ab(sub(r, 4.2)), 0.06)
    cross = mx(mul(band(ay, 0.09), between(ax, 5.4, 8.7)), mul(band(ax, 0.09), between(ay, 5.4, 8.7)))
    theta = M("ARCTAN2", y, x)
    seg = math.tau / 72.0
    arc = mul(mul(ab(sub(M("FRACT", add(M("DIVIDE", theta, seg), 0.5)), 0.5)), seg), r)
    ticks = mul(band(arc, 0.025), between(r, 9.70, 10.02))
    seg2 = math.tau / 12.0
    arc2 = mul(mul(ab(sub(M("FRACT", add(M("DIVIDE", theta, seg2), 0.5)), 0.5)), seg2), r)
    ticks2 = mul(band(arc2, 0.05), between(r, 9.70, 10.35))

    # hazard chevron square border at +-13 m
    msq = M("MAXIMUM", ax, ay)
    v = sub(msq, 13.0)
    hb = band(ab(v), 0.30)
    side_x = M("GREATER_THAN", ax, ay)
    u = b.mixf(side_x, x, y)
    t = M("DIVIDE", add(u, mul(ab(v), 1.2)), 0.95)
    tw = ab(sub(M("FRACT", t), 0.5))
    yel_s = b.smooth(tw, 0.235, 0.265)
    haz_y = mul(hb, yel_s)
    haz_k = mul(hb, inv(yel_s))
    haz_edge = mul(band(ab(sub(ab(v), 0.40)), 0.035), 1.0)

    # guide lines along Y
    outside = gt(ay, 13.6)
    dash = gt(ab(sub(M("FRACT", M("DIVIDE", y, 3.0)), 0.5)), 0.2)
    centre_line = mx(mul(mul(band(ax, 0.075), dash), outside), mul(band(ax, 0.075), between(ay, 9.85, 12.55)))
    edge_lines = mul(band(ab(sub(ax, 5.0)), 0.07), outside)
    stop_bar = mul(band(ab(sub(ay, 15.6)), 0.16), lt(ax, 5.0))
    walkway = band(ab(sub(msq, 29.4)), 0.07)

    # box markings without text, mirrored into the four quadrants around (18, 10.5)
    lx, ly = sub(ax, 18.0), sub(ay, 10.5)
    dbox = M("MAXIMUM", sub(ab(lx), 1.55), sub(ab(ly), 0.85))
    box_o = band(ab(dbox), 0.05)
    blk = lt(M("MAXIMUM", sub(ab(add(lx, 0.85)), 0.42), sub(ab(ly), 0.58)), 0.0)
    bars = mx(*[lt(M("MAXIMUM", sub(ab(sub(lx, bx)), 0.09), sub(ab(ly), 0.5)), 0.0) for bx in (0.05, 0.50, 0.95)])
    # a second, larger bay plate on the -Y lane
    lx2, ly2 = ab(sub(x, 0.0)), ab(add(y, 21.0))
    d2 = M("MAXIMUM", sub(lx2, 3.2), sub(ly2, 1.2))
    plate = mx(band(ab(d2), 0.06), lt(M("MAXIMUM", sub(ab(sub(lx2, 1.6)), 0.7), sub(ly2, 0.75)), 0.0))

    white = mx(ring, inner, cross, ticks, ticks2, edge_lines, stop_bar, box_o, blk, bars, haz_edge, plate)
    yellow = mx(haz_y, centre_line, walkway)
    black = haz_k

    # paint wear mask (1 = paint intact)
    wear_n = add(mul(b.noise(P, 0.85, 8.0, 0.62), 0.7), mul(n_fine, 0.3))
    keep = b.smooth(wear_n, 0.36, 0.50)
    keep = mul(keep, inv(mul(tyres, 0.8)))
    keep = mul(keep, inv(mul(sp_dark, 0.7)))
    p_w = mul(white, mul(keep, 0.92))
    p_y = mul(yellow, mul(keep, 0.92))
    p_k = mul(black, mul(keep, 0.92))
    paint = mx(p_w, p_y, p_k)

    # ---- colour -----------------------------------------------------------------------------
    f = mul(add(0.82, mul(srand, 0.36)), add(0.78, mul(n_big, 0.44)))
    f = mul(f, add(0.9, mul(n_mid, 0.2)))
    f = mul(f, add(1.0, mul(dust, 0.55)))
    f = mul(f, add(1.0, mul(sp_light, 0.9)))
    f = mul(f, inv(mul(groove, 0.85)))
    base = b.mixc(1.0, (0.040, 0.042, 0.046, 1.0), f, "MULTIPLY")
    col = b.mixc(p_w, base, (0.50, 0.49, 0.45, 1.0))
    col = b.mixc(p_y, col, (0.48, 0.29, 0.018, 1.0))
    col = b.mixc(p_k, col, (0.011, 0.011, 0.012, 1.0))
    g = mul(inv(mul(stain, 0.45)), inv(mul(tyres, 0.65)))
    g = mul(g, inv(mul(joint_dirt, 0.35)))
    g = mul(g, inv(mul(sp_dark, 0.5)))
    col = b.mixc(1.0, col, g, "MULTIPLY")

    # ---- roughness --------------------------------------------------------------------------
    rr = b.mixf(wet, 0.56, 0.07)
    rr = add(rr, mul(sub(n_fine, 0.5), 0.10))
    rr = add(rr, mul(sub(srand, 0.5), 0.07))
    rr = add(rr, mul(dust, 0.14))
    rr = sub(rr, mul(stain, 0.05))
    rr = add(rr, mul(tyres, 0.12))
    rr = add(rr, mul(groove, 0.30))
    pr = add(b.mixf(wet, 0.40, 0.20), mul(sub(n_fine, 0.5), 0.08))
    rr = b.mixf(paint, rr, pr)
    rr = M("MAXIMUM", M("MINIMUM", rr, 0.85), 0.05)

    # ---- normal -----------------------------------------------------------------------------
    h = add(mul(paint, 0.25), mul(groove, -1.0))
    h = add(h, mul(n_micro, 0.10))
    h = add(h, mul(sp_dark, -0.15))
    bump = b.new("ShaderNodeBump")
    b.set(bump.inputs["Height"], h)
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = 0.003

    p = b.new("ShaderNodeBsdfPrincipled")
    b.set(p.inputs["Base Color"], col)
    b.set(p.inputs["Roughness"], rr)
    b.set(p.inputs["Normal"], bump.outputs[0])
    nt.links.new(p.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (0.05, 0.05, 0.055, 1.0)
    return m


# ------------------------------------------------------------------------------------------
# geometry accumulator: one bmesh per material key -> one joined object
# ------------------------------------------------------------------------------------------
class _Acc:
    def __init__(self):
        self.bms = {}

    def bm(self, key):
        if key not in self.bms:
            self.bms[key] = bmesh.new()
        return self.bms[key]

    def transform(self, mx):
        for bm in self.bms.values():
            bmesh.ops.transform(bm, matrix=mx, verts=bm.verts[:])

    def build(self, name, col, smooth=35.0):
        objs = []
        for key, bm in self.bms.items():
            if not bm.verts:
                bm.free()
                continue
            objs.append(kit.to_obj(name + "_" + key, bm, col, [_mat(key)], smooth=smooth))
        self.bms = {}
        return kit.join(objs, name) if objs else None


def _box(bm, size, center, bev=0.02, segs=1, mx=None):
    bev = min(bev, 0.45 * min(size))
    kit.box(size, center=center, bevel=bev, segs=segs, bm=bm, mx=mx)


def _beam(bm, p0, p1, w, h, bev=0.01, xhint=(0, 0, 1)):
    """Box of section w x h along the segment p0 -> p1."""
    p0, p1 = V(p0), V(p1)
    d = p1 - p0
    xh = V(xhint)
    if abs(d.normalized().dot(xh)) > 0.95:
        xh = V((1, 0, 0)) if abs(d.normalized().x) < 0.9 else V((0, 1, 0))
    mx = kit.frame((p0 + p1) / 2, d, xh)
    _box(bm, (w, h, d.length), (0, 0, 0), bev, 1, mx)


def _catmull(pts, n=8):
    pts = [V(p) for p in pts]
    ext = [pts[0] * 2 - pts[1]] + pts + [pts[-1] * 2 - pts[-2]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(n):
            t = k / n
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t +
                              (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    out.append(pts[-1])
    return out


# ------------------------------------------------------------------------------------------
# walls (built in the +Y wall frame: u along the wall = world x, d = distance into the room,
# z above the floor; then rotated about Z for the other three walls)
# ------------------------------------------------------------------------------------------
COL_STEP = 6.0
DOOR_HALF = 17.0      # clear opening half width
DOOR_H = 13.0


def _wall(acc, lacc, half, H, G, k, door, rng):
    clip = (k % 2 == 1)          # X walls stop short of the corners (the Y walls own them)

    def B(key, u0, u1, d0, d1, z0, z1, bev=0.02, segs=1, full=False):
        if clip and not full:
            lim = half - max(d1, 0.0) - 0.01
            u0, u1 = max(u0, -lim), min(u1, lim)
        if u1 - u0 < 0.02 or d1 - d0 < 1e-4 or z1 - z0 < 1e-4:
            return
        _box(acc.bm(key), (u1 - u0, d1 - d0, z1 - z0), ((u0 + u1) / 2, half - (d0 + d1) / 2, G + (z0 + z1) / 2),
             bev, segs)

    def L(u0, u1, d0, d1, z0, z1):
        if clip:
            lim = half - d1 - 0.01
            u0, u1 = max(u0, -lim), min(u1, lim)
        _box(lacc.bm("strip"), (u1 - u0, d1 - d0, z1 - z0), ((u0 + u1) / 2, half - (d0 + d1) / 2, G + (z0 + z1) / 2),
             0.004, 1)

    def P(u, d, z):
        return V((u, half - d, G + z))

    def in_door(u0, u1, pad=0.0):
        return door and u1 > -(DOOR_HALF + 2.0 + pad) and u0 < DOOR_HALF + 2.0 + pad

    # back skin (dark, overlaps the corners and the ceiling) -------------------------------
    sk = half + 0.5 if not clip else half
    B("wall", -sk, sk, -0.45, 0.0, -0.1, H + 0.35, 0.0, full=True)

    cols = [-half + 2.0 + COL_STEP * i for i in range(int((2 * half - 4.0) / COL_STEP + 1.5))]
    cols = [c for c in cols if abs(c) <= half - 1.5]

    # horizontal spans (outside the door) -------------------------------------------------
    spans = [(-half, half)]
    if door:
        spans = [(-half, -(DOOR_HALF + 2.0)), (DOOR_HALF + 2.0, half)]

    for (a, c) in spans:
        full = not clip
        B("concrete", a, c, -0.02, 0.30, 0.0, 0.36, 0.03, full=False)
        # top ring beam + upper band
        B("frame", a, c, -0.02, 0.85, 15.35, 16.30, 0.04, full=full)
        B("wall2", a, c, -0.02, 0.10, 16.36, H - 0.02, 0.02)
        # catwalk deck at 8 m
        B("grate", a, c, -0.02, 1.30, 7.85, 8.00, 0.01, full=full)
        B("frame", a, c, 1.22, 1.32, 7.70, 8.06, 0.012, full=full)
        B("frame", a, c, 1.26, 1.30, 8.06, 8.18, 0.006, full=full)
        # stringer under the deck
        B("frame", a, c, 0.95, 1.20, 7.55, 7.85, 0.015, full=full)
        # railing (all walls stop at the corner post)
        ra, rc = max(a, -(half - 1.27)), min(c, half - 1.27)
        if door:
            ra = a if a > 0 else ra
            rc = c if c < 0 else rc
            if a > 0:
                ra = a + 0.1
            else:
                rc = c - 0.1
        bm = acc.bm("metal_dark")
        for zr, rr in ((9.10, 0.030), (8.62, 0.022)):
            kit.tube([P(ra, 1.25, zr), P(rc, 1.25, zr)], rr, segs=12, bm=bm)
        npost = max(1, int(round((rc - ra) / 1.5)))
        for i in range(npost + 1):
            uu = ra + (rc - ra) * i / npost
            kit.cylinder(0.028, G + 8.18, G + 9.10, 12, chamfer=0.004, bm=bm, mx=T(uu, half - 1.25, 0.0))
        # cable tray under the catwalk
        zt = 7.25 if k % 2 == 0 else 6.85
        ta, tc_ = (a, c)
        B("metal_dark", ta, tc_, 0.12, 0.56, zt, zt + 0.03, 0.006, full=full)
        B("metal_dark", ta, tc_, 0.12, 0.15, zt, zt + 0.13, 0.006, full=full)
        B("metal_dark", ta, tc_, 0.53, 0.56, zt, zt + 0.13, 0.006, full=full)
        lim = half if not clip else half - 0.57
        for j, dd in enumerate((0.20, 0.27, 0.34, 0.41, 0.48)):
            rr = 0.035 if j % 2 == 0 else 0.028
            key = "rubber" if j != 2 else "pipe_ochre"
            kit.tube([P(max(ta, -lim), dd, zt + 0.03 + rr), P(min(tc_, lim), dd, zt + 0.03 + rr)], rr, segs=12,
                     bm=acc.bm(key))
        # pipes
        rows = ((3.55, 0.10, 0.42, "metal_dark"), (3.92, 0.14, 0.50, "pipe_teal")) if k % 2 == 0 else \
            ((4.62, 0.10, 0.42, "metal_dark"), (4.98, 0.13, 0.50, "pipe_teal"))
        for (zp, rp, dp, key) in rows:
            pa = a if not (door and a > 0) else a - 0.6
            pc = c if not (door and c < 0) else c + 0.6
            kit.tube([P(pa, dp, zp), P(pc, dp, zp)], rp, segs=20, bm=acc.bm(key))
            for uc in cols:
                if uc < a or uc > c:
                    continue
                for s in (-0.7, 0.7):
                    kit.cylinder(rp + 0.035, -0.045, 0.045, 24, chamfer=0.01, bm=acc.bm("metal_dark"),
                                 mx=kit.frame(P(uc + s, dp, zp), (1, 0, 0), (0, 0, 1)))
            # supports mid-bay
            for uc in cols:
                um = uc + COL_STEP / 2
                if um < a + 0.5 or um > c - 0.5:
                    continue
                B("metal_dark", um - 0.06, um + 0.06, -0.02, dp + 0.05, zp - rp - 0.07, zp - rp, 0.01)
                kit.torus(rp + 0.012, 0.012, 24, 6, bm=acc.bm("metal_dark"),
                          mx=kit.frame(P(um, dp, zp), (1, 0, 0), (0, 0, 1)))

    # columns -----------------------------------------------------------------------------
    for uc in cols:
        if door and abs(uc) <= DOOR_HALF + 1.5:
            continue
        B("frame", uc - 0.45, uc + 0.45, -0.02, 0.75, 0.0, H, 0.04, full=True)
        B("frame", uc - 0.60, uc + 0.60, 0.72, 0.90, 0.60, H - 0.02, 0.03, full=True)
        B("stripe", uc - 0.75, uc + 0.75, -0.02, 1.05, 0.0, 0.62, 0.03, full=True)
        for zs in (4.35, 11.05, 14.3):
            B("frame", uc - 0.68, uc + 0.68, 0.86, 0.96, zs, zs + 0.34, 0.015, full=True)
        # catwalk bracket
        _beam(acc.bm("frame"), P(uc, 0.88, 6.55), P(uc, 1.15, 7.58), 0.16, 0.16, 0.012, xhint=(1, 0, 0))

    # bays --------------------------------------------------------------------------------
    edges = [-half] + [e for uc in cols for e in (uc - 0.6, uc + 0.6)] + [half]
    bays = [(edges[i], edges[i + 1]) for i in range(0, len(edges), 2)]
    for bi, (a, c) in enumerate(bays):
        if in_door(a, c):
            continue
        w = c - a
        if w < 0.3:
            continue
        n = 2 if w > 3.0 else 1
        gap = 0.05
        pw = (w - gap * (n + 1)) / n
        variant = rng.random()
        for i in range(n):
            u0 = a + gap + i * (pw + gap)
            u1 = u0 + pw
            # wainscot armour panels with ribs
            B("panel", u0, u1, -0.02, 0.12, 0.40, 2.95, 0.03)
            for zr in (1.15, 2.10):
                B("frame", u0 + 0.16, u1 - 0.16, 0.10, 0.17, zr, zr + 0.09, 0.02)
            # recessed panels (frame + inset)
            z0, z1, fw = 4.45, 7.62, 0.20
            B("panel", u0, u1, -0.02, 0.16, z0, z0 + fw, 0.025)
            B("panel", u0, u1, -0.02, 0.16, z1 - fw, z1, 0.025)
            B("panel", u0, u0 + fw, -0.02, 0.16, z0 + fw, z1 - fw, 0.025)
            B("panel", u1 - fw, u1, -0.02, 0.16, z0 + fw, z1 - fw, 0.025)
            if (variant < 0.30 and i == 0) and pw > 1.5:
                # louvred vent
                B("inner_dark", u0 + fw, u1 - fw, -0.02, 0.03, z0 + fw, z1 - fw, 0.0)
                nsl = 12
                for s in range(nsl):
                    zz = z0 + fw + 0.12 + s * (z1 - z0 - 2 * fw - 0.24) / (nsl - 1)
                    _beam(acc.bm("frame"), P(u0 + fw + 0.02, 0.07, zz), P(u1 - fw - 0.02, 0.07, zz), 0.03, 0.16,
                          0.006, xhint=(0, 1, 0))
            else:
                B("wall2", u0 + fw, u1 - fw, -0.02, 0.06, z0 + fw, z1 - fw, 0.02)
                if variant > 0.72 and i == n - 1 and pw > 1.5:
                    # service hatch with handles
                    hu = (u0 + u1) / 2
                    B("hatch", hu - 0.45, hu + 0.45, 0.04, 0.11, 5.1, 6.6, 0.02)
                    for hz in (5.55, 6.15):
                        B("metal_steel", hu + 0.22, hu + 0.30, 0.10, 0.16, hz, hz + 0.18, 0.01)
            # upper big panels
            B("panel", u0, u1, -0.02, 0.08, 11.45, 13.30, 0.03)
            B("panel", u0, u1, -0.02, 0.08, 13.36, 15.25, 0.03)
        # band behind pipes
        B("wall2", a + 0.03, c - 0.03, -0.02, 0.05, 3.30, 4.36, 0.015)
        # light strips in housings
        for zl in (3.0, 11.1):
            B("frame", a, c, -0.02, 0.20, zl, zl + 0.24, 0.02)
            if w > 1.0:
                L(a + 0.15, c - 0.15, 0.18, 0.205, zl + 0.095, zl + 0.145)
        # downlight under the catwalk deck (pools of light on the wainscot)
        if w > 3.0:
            um = (a + c) / 2
            B("metal_dark", um - 0.55, um + 0.55, 0.60, 0.92, 7.74, 7.86, 0.01)
            _box(lacc.bm("down"), (0.9, 0.24, 0.02), P(um, 0.76, 7.735), 0.004)
        # ribbed zone between catwalk and upper panels
        B("frame", a, c, -0.02, 0.12, 8.05, 8.20, 0.015)
        B("frame", a, c, -0.02, 0.12, 10.90, 11.05, 0.015)
        nr = max(1, int(w / 0.5))
        for q in range(nr):
            uq = a + (q + 0.5) * w / nr
            B("panel", uq - 0.045, uq + 0.045, -0.02, 0.09, 8.20, 10.90, 0.015)
        # junction box with conduit on some bays
        if 0.45 < variant < 0.72 and w > 3.0:
            ju = a + w * 0.3
            B("paint_dark", ju - 0.30, ju + 0.30, 0.10, 0.36, 1.25, 2.05, 0.02)
            B("metal_dark", ju - 0.33, ju + 0.33, 0.33, 0.38, 1.20, 2.10, 0.01)
            kit.tube([P(ju, 0.24, 2.05), P(ju, 0.24, 3.0)], 0.03, segs=12, bm=acc.bm("metal_dark"))

    # vertical drop pipe with valve, one per wall -----------------------------------------
    cand = [bb for bb in bays if (bb[1] - bb[0]) > 3.0 and not in_door(*bb)]
    if cand:
        a, c = cand[(k * 3 + 1) % len(cand)]
        u = a + (c - a) * 0.72
        bmq = acc.bm("pipe_teal")
        kit.tube([P(u, -0.02, 6.9), P(u, 0.40, 6.9), P(u, 0.40, 1.05)], 0.085, segs=20, bm=bmq, fillet=0.25)
        B("metal_dark", u - 0.28, u + 0.28, -0.02, 0.55, 0.36, 1.05, 0.03)
        for zf in (1.12, 6.0):
            kit.cylinder(0.12, G + zf - 0.04, G + zf + 0.04, 24, chamfer=0.01, bm=acc.bm("metal_dark"),
                         mx=T(u, half - 0.40, 0))
        kit.cylinder(0.022, -0.30, 0.0, 12, bm=acc.bm("metal_steel"), mx=kit.frame(P(u, 0.40, 1.65), (0, -1, 0)))
        kit.cylinder(0.11, -0.10, 0.10, 24, chamfer=0.01, bm=acc.bm("metal_dark"),
                     mx=kit.frame(P(u, 0.40, 1.65), (0, -1, 0)))
        kit.torus(0.17, 0.02, 32, 8, bm=acc.bm("paint_accent"), mx=kit.frame(P(u, 0.70, 1.65), (0, -1, 0)))
        for s in range(3):
            a_ = math.tau * s / 3
            _beam(acc.bm("metal_dark"), P(u, 0.70, 1.65),
                  P(u + 0.16 * math.cos(a_), 0.70, 1.65 + 0.16 * math.sin(a_)), 0.02, 0.02, 0.004, xhint=(0, 1, 0))

    if door:
        _door(acc, lacc, half, H, G)


def _door(acc, lacc, half, H, G):
    """Huge closed hangar door on the +Y wall (world frame)."""
    dh, w = DOOR_HALF, DOOR_H

    def B(key, x0, x1, d0, d1, z0, z1, bev=0.02, segs=1):
        _box(acc.bm(key), (x1 - x0, d1 - d0, z1 - z0), ((x0 + x1) / 2, half - (d0 + d1) / 2, G + (z0 + z1) / 2),
             bev, segs)

    # jambs and header
    for s in (-1, 1):
        x0, x1 = sorted((s * dh, s * (dh + 2.0)))
        B("frame", x0, x1, -0.02, 1.50, 0.0, w + 1.8, 0.05)
        B("frame", x0 - 0.12, x1 + 0.12, 1.40, 1.60, 0.0, w + 1.8, 0.03)
        B("stripe", x0 - 0.14, x1 + 0.14, -0.02, 1.64, 0.0, 2.2, 0.03)
        # guide rail
        xr = s * (dh - 0.25)
        B("metal_dark", xr - 0.18, xr + 0.18, -0.02, 0.75, 0.0, w + 0.2, 0.02)
        # control panel on the jamb face
        xc = s * (dh + 1.0)
        B("paint_dark", xc - 0.35, xc + 0.35, 1.60, 1.72, 1.20, 2.00, 0.015)
        for i, (key, zz) in enumerate((("emit_green", 1.82), ("emit_red", 1.82), ("emit_amber", 1.82))):
            xx = xc - 0.18 + i * 0.18
            B(key, xx - 0.035, xx + 0.035, 1.72, 1.735, zz - 0.035, zz + 0.035, 0.004)
        B("plastic_black", xc - 0.25, xc + 0.25, 1.72, 1.74, 1.32, 1.66, 0.006)
    B("frame", -(dh + 2.0), dh + 2.0, -0.02, 1.40, w, w + 1.8, 0.05)
    B("frame", -(dh + 2.1), dh + 2.1, 1.30, 1.55, w - 0.15, w + 0.15, 0.03)
    B("stripe", -dh, dh, 1.30, 1.48, w + 0.25, w + 0.62, 0.02)
    # header motor housings
    for xm in (-11.0, 0.0, 11.0):
        B("paint_dark", xm - 1.2, xm + 1.2, 1.40, 1.85, w + 0.75, w + 1.65, 0.04)
        B("metal_dark", xm - 1.0, xm + 1.0, 1.84, 1.90, w + 0.95, w + 1.45, 0.01)
    # door leaves: 6 vertical leaves x 6 horizontal segments
    nl, ns = 6, 6
    lw = 2 * dh / nl
    seg_h = (w - 1.0) / ns
    for i in range(nl):
        x0 = -dh + i * lw + 0.03
        x1 = x0 + lw - 0.06
        dd = 0.55 if i % 2 == 0 else 0.42     # leaves staggered on two tracks
        # bumper with hazard stripes at the bottom edge
        B("stripe", x0, x1, 0.10, dd + 0.10, 0.02, 0.95, 0.03)
        B("rubber", x0 + 0.02, x1 - 0.02, 0.12, dd + 0.08, 0.0, 0.06, 0.01)
        for j in range(ns):
            z0 = 1.0 + j * seg_h + 0.025
            z1 = z0 + seg_h - 0.05
            B("door", x0, x1, 0.10, dd, z0, z1, 0.04)
            # inset raised plate + horizontal stiffener
            B("door", x0 + 0.30, x1 - 0.30, dd - 0.02, dd + 0.05, z0 + 0.28, z1 - 0.28, 0.03)
            B("frame", x0 + 0.10, x1 - 0.10, dd - 0.02, dd + 0.08, z0 + 0.06, z0 + 0.16, 0.02)
        # vertical edge stiffeners
        for xe in (x0 + 0.10, x1 - 0.10):
            B("frame", xe - 0.07, xe + 0.07, dd - 0.02, dd + 0.10, 1.0, w - 0.05, 0.02)
        # small viewing ports on the middle height of every second leaf
        if i % 2 == 1:
            xm = (x0 + x1) / 2
            for zz in (6.3,):
                B("frame", xm - 0.5, xm + 0.5, dd + 0.04, dd + 0.12, zz - 0.28, zz + 0.28, 0.03)
                B("glass_dark", xm - 0.40, xm + 0.40, dd + 0.08, dd + 0.13, zz - 0.18, zz + 0.18, 0.01)
    # amber beacons
    for xb, zb, db in ((-15.0, w + 1.2, 1.40), (-5.5, w + 1.2, 1.40), (5.5, w + 1.2, 1.40), (15.0, w + 1.2, 1.40),
                       (-(dh + 1.0), 3.0, 1.60), (dh + 1.0, 3.0, 1.60)):
        o = V((xb, half - db, G + zb))
        mxb = kit.frame(o, (0, -1, 0), (1, 0, 0))
        kit.cylinder(0.16, 0.0, 0.10, 24, chamfer=0.012, bm=acc.bm("metal_dark"), mx=mxb)
        prof = [(0.11, 0.10)] + [(0.11 * math.cos(a), 0.10 + 0.13 * math.sin(a)) for a in
                                 [math.pi / 2 * q / 6 for q in range(1, 7)]]
        prof[-1] = (0.0, prof[-1][1])
        kit.lathe(prof + [(0.0, 0.10)], 24, bm=lacc.bm("emit_amber"), mx=mxb)
        kit.torus(0.112, 0.012, 24, 6, bm=acc.bm("metal_dark"), mx=mxb @ T(0, 0, 0.16))


# ------------------------------------------------------------------------------------------
# ceiling
# ------------------------------------------------------------------------------------------
def _ceiling(acc, lacc, half, H, G):
    top = G + H
    _box(acc.bm("ceiling"), (2 * half + 1.0, 2 * half + 1.0, 0.4), (0, 0, top + 0.2), 0.0)
    # purlins along Y
    x = -half + 2.0
    while x < half - 1.0:
        _box(acc.bm("frame"), (0.22, 2 * half, 0.30), (x, 0, top - 0.15), 0.02)
        x += 4.0
    # trusses along X
    for yc in (-24.0, -16.0, -8.0, 0.0, 8.0, 16.0, 24.0):
        bm = acc.bm("frame")
        zt, zb = top - 0.44, top - 1.86
        _box(bm, (2 * half, 0.30, 0.28), (0, yc, zt), 0.025)
        _box(bm, (2 * half, 0.30, 0.28), (0, yc, zb), 0.025)
        n = int(2 * half / 4.0)
        for i in range(n + 1):
            xi = -half + i * 4.0
            if abs(xi) < half - 0.1:
                _beam(bm, (xi, yc, zb + 0.14), (xi, yc, zt - 0.14), 0.16, 0.16, 0.012, xhint=(1, 0, 0))
            if i < n:
                xa, xb = (xi, xi + 4.0) if i % 2 == 0 else (xi + 4.0, xi)
                _beam(bm, (xa, yc, zb + 0.12), (xb, yc, zt - 0.12), 0.14, 0.14, 0.012, xhint=(0, 1, 0))
        # bearing plates on the X walls
        for s in (-1, 1):
            _box(acc.bm("metal_dark"), (0.5, 0.7, 2.0), (s * (half - 0.25), yc, top - 1.15), 0.03)
    # big ventilation ducts along Y
    for xd in (-20.0, 20.0):
        zd = top - 2.65
        kit.tube([(xd, -half, zd), (xd, half, zd)], 0.55, segs=32, bm=acc.bm("metal_steel"), caps=False)
        y = -half + 4.0
        while y < half - 1.0:
            kit.cylinder(0.60, -0.06, 0.06, 32, chamfer=0.015, bm=acc.bm("metal_dark"),
                         mx=kit.frame((xd, y, zd), (0, 1, 0)))
            _box(acc.bm("metal_dark"), (0.08, 0.10, 2.1), (xd - 0.65, y, top - 1.62), 0.01)
            _box(acc.bm("metal_dark"), (0.08, 0.10, 2.1), (xd + 0.65, y, top - 1.62), 0.01)
            _box(acc.bm("metal_dark"), (1.45, 0.12, 0.08), (xd, y, zd - 0.62), 0.01)
            y += 8.0
    # light panels 4 x 4 (1.6 x 5 m emissive, segmented by two bars)
    for xc in (-12.0, -4.0, 4.0, 12.0):
        for yc in (-12.0, -4.0, 4.0, 12.0):
            zb = top - 1.95
            _box(acc.bm("paint_dark"), (1.95, 5.35, 0.24), (xc, yc, zb + 0.12), 0.03)
            _box(lacc.bm("ceil_light"), (1.60, 5.00, 0.03), (xc, yc, zb - 0.005), 0.004)
            for yb in (-5.0 / 6, 5.0 / 6):
                _box(acc.bm("metal_dark"), (1.66, 0.07, 0.04), (xc, yc + yb, zb - 0.02), 0.008)
            for sx in (-0.7, 0.7):
                for sy in (-2.1, 2.1):
                    kit.cylinder(0.018, zb + 0.24, top - 0.30 + 0.30, 8, bm=acc.bm("metal_steel"),
                                 mx=T(xc + sx, yc + sy, 0))


# ------------------------------------------------------------------------------------------
# props
# ------------------------------------------------------------------------------------------
def _crate(acc, size, body, center=(0, 0, 0), rot=0.0):
    sx, sy, sz = size
    m = T(*center) @ R("Z", rot)

    def bx(key, sz_, c, bev, segs=1):
        _box(acc.bm(key), sz_, c, bev, segs, mx=m)

    bx(body, (sx - 0.06, sy - 0.06, sz - 0.04), (0, 0, sz / 2), 0.03, 2)
    for zb in (0.045, sz / 2, sz - 0.045):
        bx("metal_dark", (sx, sy, 0.07), (0, 0, zb), 0.012)
    for ix in (-1, 1):
        for iy in (-1, 1):
            bx("metal_dark", (0.10, 0.10, sz), (ix * (sx / 2 - 0.05), iy * (sy / 2 - 0.05), sz / 2), 0.012)
    for s in (-1, 1):
        for q in (-0.22, 0.22):
            bx("metal_dark", (0.06, 0.03, sz - 0.2), (q * sx, s * (sy / 2 - 0.005), sz / 2), 0.008)
            bx("metal_dark", (0.03, 0.06, sz - 0.2), (s * (sx / 2 - 0.005), q * sy, sz / 2), 0.008)
        bx("metal_steel", (0.10, 0.04, 0.12), (0.0, s * (sy / 2 + 0.01), sz - 0.17), 0.01)
    # text-free ID plate
    bx("paint_grey", (0.28, 0.012, 0.16), (-0.30 * sx, -(sy / 2 - 0.022), sz * 0.72), 0.003)


def _props_crates(acc):
    _crate(acc, (1.2, 1.2, 1.2), "paint_dark", (0, 0, 0), 0)
    _crate(acc, (1.2, 1.2, 1.2), "paint_grey", (1.32, 0.08, 0), 4)
    _crate(acc, (1.2, 1.2, 1.2), "paint_accent", (0.62, 0.06, 1.205), 11)
    _crate(acc, (2.4, 1.2, 1.0), "paint_dark", (0.3, 1.55, 0), -3)


def _props_cart(acc):
    bm = acc.bm("paint_dark")
    L, W = 1.30, 0.65
    for ix in (-1, 1):
        for iy in (-1, 1):
            x, y = ix * (L / 2 - 0.06), iy * (W / 2 - 0.05)
            _box(bm, (0.04, 0.04, 0.80), (x, y, 0.55), 0.008)
            kit.cylinder(0.075, -0.02, 0.02, 24, chamfer=0.008, bm=acc.bm("rubber"),
                         mx=T(x, y, 0.075) @ R("Y", 90))
            _box(acc.bm("metal_dark"), (0.06, 0.08, 0.10), (x, y, 0.15), 0.008)
    for zs in (0.20, 0.58, 0.94):
        _box(acc.bm("metal_dark"), (L, W, 0.03), (0, 0, zs), 0.008)
        for s in (-1, 1):
            _box(bm, (L, 0.025, 0.06), (0, s * (W / 2 - 0.012), zs + 0.04), 0.006)
    kit.tube([(-L / 2 + 0.06, -0.25, 0.95), (-L / 2 - 0.12, -0.25, 1.02), (-L / 2 - 0.12, 0.25, 1.02),
              (-L / 2 + 0.06, 0.25, 0.95)], 0.016, segs=12, bm=acc.bm("metal_steel"), fillet=0.06)
    # tool cabinet on the lower shelf
    ca = acc.bm("paint_accent")
    _box(ca, (0.70, 0.52, 0.34), (0.22, 0, 0.385), 0.015)
    for i in range(3):
        z = 0.27 + i * 0.105
        _box(acc.bm("metal_dark"), (0.66, 0.012, 0.09), (0.22, -0.265, z), 0.004)
        _box(acc.bm("metal_steel"), (0.30, 0.025, 0.018), (0.22, -0.28, z + 0.02), 0.004)
    # things on top
    kit.cylinder(0.07, 0.955, 1.25, 24, chamfer=0.01, bm=acc.bm("metal_steel"), mx=T(0.35, 0.12, 0))
    _box(acc.bm("plastic_black"), (0.42, 0.26, 0.16), (-0.2, 0.05, 1.035), 0.015)
    _box(acc.bm("paint_hazard"), (0.20, 0.14, 0.10), (-0.25, -0.18, 1.005), 0.01)


def _props_reel(acc):
    fr = acc.bm("metal_dark")
    for s in (-1, 1):
        x = s * 0.48
        _beam(fr, (x, -0.55, 0.03), (x, 0.0, 1.0), 0.06, 0.06, 0.008, xhint=(1, 0, 0))
        _beam(fr, (x, 0.55, 0.03), (x, 0.0, 1.0), 0.06, 0.06, 0.008, xhint=(1, 0, 0))
        _box(fr, (0.08, 1.30, 0.06), (x, 0, 0.03), 0.01)
        kit.cylinder(0.09, -0.04, 0.04, 24, chamfer=0.008, bm=fr, mx=T(x, 0, 1.0) @ R("Y", 90))
    for s in (-1, 1):
        _box(fr, (1.0, 0.08, 0.06), (0, s * 0.62, 0.03), 0.01)
    kit.cylinder(0.035, -0.55, 0.55, 16, bm=acc.bm("metal_steel"), mx=T(0, 0, 1.0) @ R("Y", 90))
    hz = acc.bm("paint_hazard")
    for s in (-1, 1):
        kit.cylinder(0.72, -0.018, 0.018, 48, chamfer=0.006, bm=hz, mx=T(s * 0.40, 0, 1.0) @ R("Y", 90))
        kit.cylinder(0.18, -0.03, 0.03, 32, chamfer=0.006, bm=fr, mx=T(s * 0.43, 0, 1.0) @ R("Y", 90))
    kit.cylinder(0.25, -0.38, 0.38, 32, bm=fr, mx=T(0, 0, 1.0) @ R("Y", 90))
    rb = acc.bm("rubber")
    for layer, rr in enumerate((0.30, 0.39, 0.48, 0.57)):
        for i in range(8):
            x = -0.335 + i * 0.096 + (0.048 if layer % 2 else 0.0)
            if abs(x) > 0.34:
                continue
            kit.torus(rr, 0.046, 40, 8, bm=rb, mx=T(x, 0, 1.0) @ R("Y", 90))
    # crank
    kit.tube([(0.52, 0, 1.0), (0.60, 0, 1.0), (0.60, 0.0, 1.28), (0.70, 0.0, 1.28)], 0.018, segs=10,
             bm=acc.bm("metal_steel"), fillet=0.03)


def _props_stair(acc):
    """Mobile stair stand: platform 1.65 m, rail top ~2.65 m. Steps climb along local +Y."""
    yb = acc.bm("paint_hazard")
    md = acc.bm("metal_dark")
    hw = 0.48
    y0, y1, zp = -1.35, 0.55, 1.65
    for s in (-1, 1):
        x = s * hw
        _beam(yb, (x, y0, 0.25), (x, y1, zp), 0.06, 0.22, 0.01, xhint=(1, 0, 0))
        _box(yb, (0.07, y1 + 1.45 - y0 - 0.1, 0.10), (x, (y0 + 1.45) / 2, 0.22), 0.01)
        _box(yb, (0.07, 0.07, zp - 0.22), (x, 1.40, 0.22 + (zp - 0.22) / 2), 0.01)
        _box(yb, (0.07, 0.07, zp - 0.22), (x, 0.60, 0.22 + (zp - 0.22) / 2), 0.01)
        _beam(yb, (x, 0.60, 0.30), (x, 1.40, zp - 0.1), 0.05, 0.05, 0.006, xhint=(1, 0, 0))
        for yc in (y0 + 0.05, 1.40):
            kit.cylinder(0.07, -0.025, 0.025, 24, chamfer=0.008, bm=acc.bm("rubber"),
                         mx=T(x, yc, 0.07) @ R("Y", 90))
            _box(md, (0.06, 0.08, 0.12), (x, yc, 0.15), 0.008)
        # handrail
        kit.tube([(x, y0 + 0.15, 0.95), (x, y1, zp + 1.0), (x, 1.42, zp + 1.0), (x, 1.42, zp)], 0.022, segs=12,
                 bm=acc.bm("metal_steel"), fillet=0.12)
        kit.tube([(x, y0 + 0.15, 0.30), (x, y0 + 0.15, 0.95)], 0.022, segs=12, bm=acc.bm("metal_steel"))
        kit.tube([(x, y1 - 0.4, zp - 0.3), (x, y1 - 0.4, zp + 0.68)], 0.018, segs=12, bm=acc.bm("metal_steel"))
    _box(yb, (2 * hw + 0.07, 0.07, 0.10), (0, 1.40, 0.22), 0.01)
    _box(md, (2 * hw + 0.1, 0.90, 0.05), (0, 1.0, zp), 0.01)
    _box(yb, (2 * hw + 0.1, 0.02, 0.12), (0, 1.45, zp + 0.06), 0.004)
    nst = 6
    for i in range(nst):
        t = (i + 0.5) / nst
        y = y0 + (y1 - y0) * t
        z = 0.25 + (zp - 0.25) * t
        _box(md, (2 * hw - 0.06, 0.26, 0.035), (0, y, z), 0.006)


def _props_cone(acc, loc):
    x, y = loc
    _box(acc.bm("rubber"), (0.40, 0.40, 0.035), (x, y, 0.0175), 0.01)
    kit.lathe([(0.0, 0.035), (0.165, 0.035), (0.040, 0.72), (0.030, 0.735), (0.0, 0.735)], 32,
              bm=acc.bm("paint_accent"), mx=T(x, y, 0))
    t0, t1 = (0.36 - 0.035) / 0.685, (0.48 - 0.035) / 0.685
    r0, r1 = 0.165 + (0.040 - 0.165) * t0, 0.165 + (0.040 - 0.165) * t1
    kit.lathe([(r0 + 0.004, 0.36), (r1 + 0.004, 0.48)], 32, bm=acc.bm("paint_white"), mx=T(x, y, 0))


def _props_bollard(acc, loc):
    x, y = loc
    kit.cylinder(0.20, 0.0, 0.03, 32, chamfer=0.008, bm=acc.bm("metal_dark"), mx=T(x, y, 0))
    kit.cylinder(0.11, 0.03, 0.98, 32, chamfer=0.01, bm=acc.bm("paint_hazard"), mx=T(x, y, 0))
    kit.lathe([(0.112, 0.98), (0.10, 1.03), (0.06, 1.07), (0.0, 1.08)], 32, bm=acc.bm("paint_hazard"),
              mx=T(x, y, 0))
    for zb in (0.55, 0.75):
        kit.cylinder(0.114, zb, zb + 0.08, 32, bm=acc.bm("paint_dark"), mx=T(x, y, 0))


def _place(acc, x, y, G, rot):
    acc.transform(T(x, y, G + 0.0005) @ R("Z", rot))


# ------------------------------------------------------------------------------------------
# public
# ------------------------------------------------------------------------------------------
def build_hangar(col=None, ground_z=-2.6, size=64.0, height=17.0, lights=1.0, props=True):
    """Build the hangar bay around the origin. Returns {"objects": [...], "lights": [...]}.
    `lights` scales the emission of the ceiling panels and the wall light strips."""
    G, half, H = ground_z, size / 2.0, height
    rng = random.Random(1907)
    objs, lts = [], []

    # emissive materials (strength scaled by `lights`)
    _LOCAL["ceil_light"] = lambda: _emit_mat("hg_ceiling_light", (0.86, 0.92, 1.0), CEILING_EMIT * lights)
    _LOCAL["down"] = lambda: _emit_mat("hg_downlight", (0.92, 0.96, 1.0), DOWN_EMIT * lights)
    _LOCAL["strip"] = lambda: _emit_mat("hg_wall_strip", (0.72, 0.85, 1.0), STRIP_EMIT * lights)

    # floor
    me = bpy.data.meshes.new("Hangar_Floor")
    h = half + 0.5
    me.from_pydata([(-h, -h, 0.0), (h, -h, 0.0), (h, h, 0.0), (-h, h, 0.0)], [], [(0, 1, 2, 3)])
    me.materials.append(_mat("floor"))
    fl = bpy.data.objects.new("Hangar_Floor", me)
    (col or bpy.context.scene.collection).objects.link(fl)
    fl.location = (0.0, 0.0, G)
    objs.append(fl)

    # walls
    for k in range(4):
        acc, lacc = _Acc(), _Acc()
        _wall(acc, lacc, half, H, G, k, door=(k == 0), rng=rng)
        mrot = R("Z", 90.0 * k)
        acc.transform(mrot)
        lacc.transform(mrot)
        ob = acc.build("Hangar_Wall_%d" % k, col)
        lo = lacc.build("Hangar_WallLights_%d" % k, col)
        objs += [ob, lo]
        lts.append(lo)

    # ceiling
    acc, lacc = _Acc(), _Acc()
    _ceiling(acc, lacc, half, H, G)
    objs.append(acc.build("Hangar_Ceiling", col))
    lo = lacc.build("Hangar_CeilingLights", col)
    objs.append(lo)
    lts.append(lo)

    # landing pad lights around the circle (flush, alternating amber / cyan)
    acc, lacc = _Acc(), _Acc()
    npad, rp = 16, 10.7
    for i in range(npad):
        a = math.tau * (i + 0.5) / npad
        x, y = rp * math.cos(a), rp * math.sin(a)
        kit.ring(0.14, 0.085, 0.0, 0.014, 32, chamfer=0.004, bm=acc.bm("metal_dark"), mx=T(x, y, G))
        kit.cylinder(0.088, 0.0, 0.009, 24, chamfer=0.002, bm=lacc.bm("emit_amber" if i % 2 == 0 else "emit_cyan"),
                     mx=T(x, y, G))
    objs.append(acc.build("Hangar_PadRims", col))
    lo = lacc.build("Hangar_PadLights", col)
    objs.append(lo)
    lts.append(lo)

    if props:
        acc = _Acc()
        _props_crates(acc)
        _place(acc, -19.5, 15.0, G, 25.0)
        objs.append(acc.build("Hangar_Crates", col))
        acc = _Acc()
        _props_cart(acc)
        _place(acc, 16.5, -15.5, G, 32.0)
        objs.append(acc.build("Hangar_Cart", col))
        acc = _Acc()
        _props_reel(acc)
        _place(acc, -15.0, -6.0, G, 90.0)
        # hose from the drum down to the floor and towards the ship
        hp = [V((-14.42, -6.0, G + 0.47)), V((-13.95, -6.0, G + 0.16)), V((-13.6, -6.0, G + 0.046))]
        fp = _catmull([(-13.6, -6.0), (-12.4, -5.6), (-11.6, -4.4), (-11.0, -2.8), (-10.1, -2.4), (-9.55, -3.4),
                       (-9.7, -4.6)], 8)
        pts = hp[:2] + [V((p.x, p.y, G + 0.046)) for p in fp]
        kit.tube(pts, 0.045, segs=12, bm=acc.bm("rubber"), fillet=0.1)
        end, prev = pts[-1], pts[-2]
        dv = (end - prev).normalized()
        kit.cylinder(0.055, 0.0, 0.16, 20, chamfer=0.008, bm=acc.bm("metal_brass"), mx=kit.frame(end, dv))
        kit.cylinder(0.035, 0.16, 0.30, 16, chamfer=0.005, bm=acc.bm("metal_steel"), mx=kit.frame(end, dv))
        objs.append(acc.build("Hangar_HoseReel", col))
        acc = _Acc()
        _props_stair(acc)
        _place(acc, -11.2, 3.2, G, -90.0)
        objs.append(acc.build("Hangar_Stair", col))
        acc = _Acc()
        for loc in ((14.3, -12.2), (18.6, -12.6), (-15.6, 13.0), (-22.3, 12.6)):
            _props_cone(acc, loc)
        for loc in ((-19.6, 29.0), (-16.6, 29.0), (16.6, 29.0), (19.6, 29.0)):
            _props_bollard(acc, loc)
        _place(acc, 0.0, 0.0, G, 0.0)
        objs.append(acc.build("Hangar_Cones", col))

    objs = [o for o in objs if o is not None]
    lts = [o for o in lts if o is not None]
    return {"objects": objs, "lights": lts}


# calibrated emission strengths at lights=1.0 (AgX, exposure 0)
CEILING_EMIT = 4.0
STRIP_EMIT = 5.0
DOWN_EMIT = 30.0


def tri_count(objs):
    n = 0
    for o in objs:
        if o.type == "MESH":
            n += sum(len(p.vertices) - 2 for p in o.data.polygons)
    return n


def demo():
    res = build_hangar(kit.collection("Hangar"))
    print("HANGAR tris", tri_count(res["objects"]))
    return res["objects"]
