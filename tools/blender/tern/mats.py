"""Material library for the Tern ship (Cycles, fully procedural, object-space - no UVs needed).

    import mats
    m = mats.get("metal_dark")

All "surface" materials share one node group (TernSurface) that adds: rounded-edge shading (Bevel node),
paint chipping on convex edges, grime in cavities, vertical streaks, per-panel tone variation and micro bump.
"""
import bpy

# ------------------------------------------------------------------------------------------
# palette (linear RGB)
# ------------------------------------------------------------------------------------------
PAINTS = [  # index = "paint" face attribute on the hull skin
    ("primary",   (0.640, 0.630, 0.600), 0.36, 0.0, 0.35),   # 0 warm pearl white
    ("secondary", (0.060, 0.064, 0.072), 0.42, 0.0, 0.15),   # 1 graphite
    ("accent",    (0.640, 0.105, 0.010), 0.38, 0.0, 0.35),   # 2 signal orange
    ("bare",      (0.420, 0.410, 0.400), 0.34, 1.0, 0.0),    # 3 bare alloy
    ("hazard",    (0.750, 0.480, 0.030), 0.45, 0.0, 0.1),    # 4 hazard yellow
    ("antiglare", (0.018, 0.019, 0.021), 0.62, 0.0, 0.0),    # 5 matt black
    ("light",     (0.500, 0.500, 0.490), 0.40, 0.0, 0.25),   # 6 mid grey
    ("heat",      (0.230, 0.215, 0.200), 0.30, 1.0, 0.0),    # 7 heat shield alloy
]
CHIP = (0.30, 0.31, 0.33)


class NB:
    """Tiny node-tree builder."""

    def __init__(self, tree):
        self.t = tree
        self.col = 0

    def new(self, typ, **kw):
        n = self.t.nodes.new(typ)
        self.col += 1
        n.location = (self.col * 190, -40 * (self.col % 7))
        for k, v in kw.items():
            setattr(n, k, v)
        return n

    def set(self, sock, val):
        if val is None:
            return
        if isinstance(val, bpy.types.NodeSocket):
            self.t.links.new(val, sock)
        else:
            try:
                sock.default_value = val
            except (TypeError, ValueError):
                sock.default_value = tuple(val) + (1.0,) * (len(sock.default_value) - len(tuple(val)))

    @staticmethod
    def sock(node, ident, out=False):
        for s in (node.outputs if out else node.inputs):
            if s.identifier == ident:
                return s
        raise KeyError(ident + " not in " + str([s.identifier for s in (node.outputs if out else node.inputs)]))

    def math(self, op, a, b=None, c=None, clamp=False):
        n = self.new("ShaderNodeMath", operation=op, use_clamp=clamp)
        self.set(n.inputs[0], a)
        self.set(n.inputs[1], b)
        self.set(n.inputs[2], c)
        return n.outputs[0]

    def mixc(self, fac, a, b, blend="MIX"):
        n = self.new("ShaderNodeMix", data_type="RGBA", blend_type=blend)
        self.set(self.sock(n, "Factor_Float"), fac)
        self.set(self.sock(n, "A_Color"), a)
        self.set(self.sock(n, "B_Color"), b)
        return self.sock(n, "Result_Color", True)

    def mixf(self, fac, a, b):
        n = self.new("ShaderNodeMix", data_type="FLOAT")
        self.set(self.sock(n, "Factor_Float"), fac)
        self.set(self.sock(n, "A_Float"), a)
        self.set(self.sock(n, "B_Float"), b)
        return self.sock(n, "Result_Float", True)

    def noise(self, vec, scale, detail=3.0, rough=0.5, distortion=0.0, color=False):
        n = self.new("ShaderNodeTexNoise")
        self.set(n.inputs["Vector"], vec)
        self.set(n.inputs["Scale"], scale)
        self.set(n.inputs["Detail"], detail)
        self.set(n.inputs["Roughness"], rough)
        self.set(n.inputs["Distortion"], distortion)
        return n.outputs[1 if color else 0]

    def ramp(self, fac, stops, interp="LINEAR"):
        n = self.new("ShaderNodeValToRGB")
        cr = n.color_ramp
        cr.interpolation = interp
        while len(cr.elements) > 1:
            cr.elements.remove(cr.elements[-1])
        for k, (pos, colr) in enumerate(stops):   # elements re-sort on position change: add one at a time
            e = cr.elements[0] if k == 0 else cr.elements.new(pos)
            e.position = pos
            e.color = tuple(colr) + ((1.0,) if len(colr) == 3 else ())
        self.set(n.inputs[0], fac)
        return n.outputs[0]

    def mapping(self, vec, scale=(1, 1, 1), loc=(0, 0, 0), rot=(0, 0, 0)):
        n = self.new("ShaderNodeMapping")
        self.set(n.inputs["Vector"], vec)
        n.inputs["Scale"].default_value = scale
        n.inputs["Location"].default_value = loc
        n.inputs["Rotation"].default_value = rot
        return n.outputs[0]

    def smooth(self, x, lo, hi):
        n = self.new("ShaderNodeMapRange", interpolation_type="SMOOTHSTEP")
        self.set(n.inputs["Value"], x)
        n.inputs["From Min"].default_value = lo
        n.inputs["From Max"].default_value = hi
        return n.outputs[0]


def _gsock(ng, name, kind, io, default=None, lo=None, hi=None):
    s = ng.interface.new_socket(name=name, in_out=io, socket_type=kind)
    if default is not None:
        s.default_value = default
    if lo is not None:
        s.min_value, s.max_value = lo, hi
    return s


# ------------------------------------------------------------------------------------------
# shared surface group
# ------------------------------------------------------------------------------------------
def surface_group():
    ng = bpy.data.node_groups.get("TernSurface")
    if ng is not None:
        return ng
    ng = bpy.data.node_groups.new("TernSurface", "ShaderNodeTree")
    _gsock(ng, "Color", "NodeSocketColor", "INPUT", (0.6, 0.6, 0.6, 1))
    _gsock(ng, "Roughness", "NodeSocketFloat", "INPUT", 0.4, 0, 1)
    _gsock(ng, "Metallic", "NodeSocketFloat", "INPUT", 0.0, 0, 1)
    _gsock(ng, "Coat", "NodeSocketFloat", "INPUT", 0.0, 0, 1)
    _gsock(ng, "Wear", "NodeSocketFloat", "INPUT", 0.5, 0, 2)
    _gsock(ng, "Grime", "NodeSocketFloat", "INPUT", 0.5, 0, 2)
    _gsock(ng, "Chip Color", "NodeSocketColor", "INPUT", CHIP + (1,))
    _gsock(ng, "Chip Metallic", "NodeSocketFloat", "INPUT", 0.85, 0, 1)
    _gsock(ng, "Micro", "NodeSocketFloat", "INPUT", 1.0, 0, 4)
    _gsock(ng, "Bevel", "NodeSocketFloat", "INPUT", 0.004, 0, 1)
    _gsock(ng, "Emission", "NodeSocketColor", "INPUT", (0, 0, 0, 1))
    _gsock(ng, "Emission Strength", "NodeSocketFloat", "INPUT", 0.0, 0, 1e6)
    _gsock(ng, "BSDF", "NodeSocketShader", "OUTPUT")
    b = NB(ng)
    gi = b.new("NodeGroupInput")
    go = b.new("NodeGroupOutput")
    I = gi.outputs
    tc = b.new("ShaderNodeTexCoord").outputs["Object"]
    geo = b.new("ShaderNodeNewGeometry")

    # noise fields
    n_big = b.noise(tc, 0.45, 3.0, 0.5)
    n_mid = b.noise(tc, 5.0, 6.0, 0.62)
    n_chip = b.noise(tc, 60.0, 4.0, 0.72)
    n_micro = b.noise(tc, 260.0, 2.0, 0.5)
    island = geo.outputs["Random Per Island"]

    # convex-edge mask: rays shot into the surface hit the neighbouring face only near an edge
    ao_in = b.new("ShaderNodeAmbientOcclusion", inside=True, only_local=True, samples=4)
    ao_in.inputs["Distance"].default_value = 0.013
    edge = b.smooth(b.math("SUBTRACT", 1.0, ao_in.outputs["AO"], clamp=True), 0.22, 0.60)
    thr = b.math("SUBTRACT", 1.0, b.math("MULTIPLY", I["Wear"], 0.62))
    flakes = b.new("ShaderNodeMapRange", interpolation_type="SMOOTHSTEP")
    b.set(flakes.inputs["Value"], n_chip)
    b.set(flakes.inputs["From Min"], b.math("SUBTRACT", thr, 0.07))
    b.set(flakes.inputs["From Max"], b.math("ADD", thr, 0.07))
    chip = b.math("MULTIPLY", edge, flakes.outputs[0], clamp=True)

    # proximity to any edge / panel border (rounded-normal deviation): where grime collects
    bev_w = b.new("ShaderNodeBevel", samples=4)
    bev_w.inputs["Radius"].default_value = 0.10
    dotn = b.new("ShaderNodeVectorMath", operation="DOT_PRODUCT")
    b.set(dotn.inputs[0], bev_w.outputs[0])
    b.set(dotn.inputs[1], geo.outputs["Normal"])
    prox = b.math("POWER", b.math("MULTIPLY", b.math("SUBTRACT", 1.0, dotn.outputs["Value"]), 7.0, clamp=True), 0.6)
    seam_dirt = b.math("MULTIPLY", prox, b.math("MULTIPLY_ADD", n_mid, 1.4, 0.15))

    # cavity grime
    ao = b.new("ShaderNodeAmbientOcclusion", samples=5)
    ao.inputs["Distance"].default_value = 0.22
    cav = b.math("SUBTRACT", 1.0, ao.outputs["AO"], clamp=True)
    cav = b.math("POWER", cav, 1.4)
    grime_n = b.math("MULTIPLY_ADD", n_mid, 1.3, 0.25)
    dirt = b.math("ADD", b.math("MULTIPLY", cav, grime_n), b.math("MULTIPLY", seam_dirt, 0.62))
    dirt = b.math("MULTIPLY", dirt, b.math("MULTIPLY", I["Grime"], 1.5), clamp=True)

    # vertical streaks on side walls
    streak_v = b.mapping(tc, scale=(6.0, 6.0, 0.16))
    s = b.noise(streak_v, 1.0, 5.0, 0.62)
    s = b.smooth(s, 0.50, 0.80)
    nz = b.new("ShaderNodeSeparateXYZ")
    b.set(nz.inputs[0], geo.outputs["Normal"])
    side = b.math("SUBTRACT", 1.0, b.math("ABSOLUTE", nz.outputs[2]), clamp=True)
    streak = b.math("MULTIPLY", b.math("MULTIPLY", s, side), b.math("MULTIPLY", I["Grime"], 0.50))
    # broad blotchy soiling
    blotch = b.math("MULTIPLY", b.smooth(n_big, 0.42, 0.85), b.math("MULTIPLY", I["Grime"], 0.26))
    dirt_all = b.math("ADD", b.math("ADD", dirt, streak), blotch, clamp=True)

    # fine scratches (two crossing directions)
    sc1 = b.smooth(b.noise(b.mapping(tc, scale=(1.3, 85.0, 85.0), rot=(0.0, 0.0, 0.5)), 1.0, 2.0, 0.5), 0.66, 0.74)
    sc2 = b.smooth(b.noise(b.mapping(tc, scale=(95.0, 1.6, 95.0), rot=(0.4, 0.0, 0.0)), 1.0, 2.0, 0.5), 0.68, 0.75)
    scratch = b.math("MULTIPLY", b.math("MAXIMUM", sc1, sc2), b.math("MULTIPLY", I["Wear"], 0.9), clamp=True)

    # colour
    tone = b.math("MULTIPLY_ADD", b.math("SUBTRACT", island, 0.5), 0.11, 1.0)   # per panel
    tone = b.math("MULTIPLY", tone, b.math("MULTIPLY_ADD", b.math("SUBTRACT", n_mid, 0.5), 0.09, 1.0))
    hsv = b.new("ShaderNodeHueSaturation")
    b.set(hsv.inputs["Color"], I["Color"])
    b.set(hsv.inputs["Value"], tone)
    col = b.mixc(b.math("MULTIPLY", dirt_all, 0.72), hsv.outputs[0], (0.045, 0.038, 0.030, 1.0))
    col = b.mixc(b.math("MULTIPLY", scratch, 0.10), col, (0.55, 0.55, 0.55, 1.0))
    col = b.mixc(chip, col, I["Chip Color"])

    # roughness / metallic / coat
    r = b.math("ADD", I["Roughness"], b.math("MULTIPLY", b.math("SUBTRACT", n_mid, 0.5), 0.22))
    r = b.math("ADD", r, b.math("MULTIPLY", b.math("SUBTRACT", n_big, 0.5), 0.12))
    r = b.math("ADD", r, b.math("MULTIPLY", b.math("SUBTRACT", island, 0.5), 0.08))
    r = b.math("ADD", r, b.math("MULTIPLY", dirt_all, 0.38))
    r = b.math("ADD", r, b.math("MULTIPLY", scratch, 0.14))
    r = b.mixf(chip, r, 0.36)
    r = b.math("MAXIMUM", b.math("MINIMUM", r, 1.0), 0.04)
    met = b.mixf(chip, I["Metallic"], I["Chip Metallic"])
    keep = b.math("MULTIPLY", b.math("SUBTRACT", 1.0, chip), b.math("SUBTRACT", 1.0, dirt_all))
    coat = b.math("MULTIPLY", I["Coat"], keep)

    # normals: rounded edges + micro orange-peel + chip step
    bev = b.new("ShaderNodeBevel", samples=6)
    b.set(bev.inputs["Radius"], I["Bevel"])
    bump = b.new("ShaderNodeBump")
    b.set(bump.inputs["Height"], b.math("ADD", b.math("MULTIPLY", n_micro, 0.35), b.math("MULTIPLY", chip, -1.0)))
    b.set(bump.inputs["Strength"], b.math("MULTIPLY", I["Micro"], 0.22))
    bump.inputs["Distance"].default_value = 0.0012
    b.set(bump.inputs["Normal"], bev.outputs[0])

    p = b.new("ShaderNodeBsdfPrincipled")
    b.set(p.inputs["Base Color"], col)
    b.set(p.inputs["Roughness"], r)
    b.set(p.inputs["Metallic"], met)
    b.set(p.inputs["Coat Weight"], coat)
    p.inputs["Coat Roughness"].default_value = 0.12
    b.set(p.inputs["Normal"], bump.outputs[0])
    b.set(p.inputs["Emission Color"], I["Emission"])
    b.set(p.inputs["Emission Strength"], I["Emission Strength"])
    ng.links.new(p.outputs[0], go.inputs["BSDF"])
    return ng


def _mat(name):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.node_tree.nodes.clear()
    b = NB(m.node_tree)
    out = b.new("ShaderNodeOutputMaterial")
    return m, b, out


def surface(name, color, rough=0.4, metallic=0.0, coat=0.0, wear=0.5, grime=0.5, micro=1.0, bevel=0.004,
            chip=CHIP, chip_metal=0.85, emission=None, strength=0.0):
    """Generic TernSurface material."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m, b, out = _mat(name)
    g = b.new("ShaderNodeGroup", node_tree=surface_group())
    vals = {"Color": tuple(color) + (1.0,), "Roughness": rough, "Metallic": metallic, "Coat": coat, "Wear": wear,
            "Grime": grime, "Micro": micro, "Bevel": bevel, "Chip Color": tuple(chip) + (1.0,),
            "Chip Metallic": chip_metal, "Emission Strength": strength}
    if emission is not None:
        vals["Emission"] = tuple(emission) + (1.0,)
    for k, v in vals.items():
        g.inputs[k].default_value = v
    m.node_tree.links.new(g.outputs[0], out.inputs["Surface"])
    m.diffuse_color = tuple(color) + (1.0,)
    return m


def emissive(name, color, strength):
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m, b, out = _mat(name)
    e = b.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = tuple(color) + (1.0,)
    e.inputs["Strength"].default_value = strength
    m.node_tree.links.new(e.outputs[0], out.inputs["Surface"])
    m.diffuse_color = tuple(color) + (1.0,)
    return m


def hull_paint(name="hull_paint"):
    """Hull skin: paint slot per face comes from the integer face attribute "paint" (see PAINTS)."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m, b, out = _mat(name)
    att = b.new("ShaderNodeAttribute", attribute_name="paint")
    n = len(PAINTS)
    fac = b.math("DIVIDE", b.math("ADD", att.outputs[2], 0.5), float(n))
    col = b.ramp(fac, [(i / n, PAINTS[i][1]) for i in range(n)], "CONSTANT")
    rough = b.ramp(fac, [(i / n, (PAINTS[i][2],) * 3) for i in range(n)], "CONSTANT")
    metal = b.ramp(fac, [(i / n, (PAINTS[i][3],) * 3) for i in range(n)], "CONSTANT")
    coat = b.ramp(fac, [(i / n, (PAINTS[i][4],) * 3) for i in range(n)], "CONSTANT")
    g = b.new("ShaderNodeGroup", node_tree=surface_group())
    b.set(g.inputs["Color"], col)
    b.set(g.inputs["Roughness"], rough)
    b.set(g.inputs["Metallic"], metal)
    b.set(g.inputs["Coat"], coat)
    g.inputs["Wear"].default_value = 0.62
    g.inputs["Grime"].default_value = 0.58
    g.inputs["Bevel"].default_value = 0.004
    m.node_tree.links.new(g.outputs[0], out.inputs["Surface"])
    m.diffuse_color = PAINTS[0][1] + (1.0,)
    return m


def glass(name="glass_dark"):
    """Dark tinted canopy glass: a deep glossy mirror that lets only a little of the interior through."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m, b, out = _mat(name)
    p = b.new("ShaderNodeBsdfPrincipled")
    p.inputs["Base Color"].default_value = (0.004, 0.006, 0.009, 1.0)
    p.inputs["Roughness"].default_value = 0.025
    p.inputs["IOR"].default_value = 1.55
    p.inputs["Specular IOR Level"].default_value = 0.9
    p.inputs["Coat Weight"].default_value = 1.0
    p.inputs["Coat Roughness"].default_value = 0.012
    p.inputs["Coat IOR"].default_value = 1.8
    p.inputs["Coat Tint"].default_value = (0.72, 0.85, 1.0, 1.0)
    tr = b.new("ShaderNodeBsdfTransparent")
    tr.inputs["Color"].default_value = (0.55, 0.72, 0.90, 1.0)
    lw = b.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.30
    fac = b.math("MULTIPLY", b.math("SUBTRACT", 1.0, lw.outputs["Facing"]), 0.16)   # see-through only head-on
    mix = b.new("ShaderNodeMixShader")
    b.set(mix.inputs[0], fac)
    m.node_tree.links.new(p.outputs[0], mix.inputs[1])
    m.node_tree.links.new(tr.outputs[0], mix.inputs[2])
    m.node_tree.links.new(mix.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (0.02, 0.03, 0.04, 1.0)
    return m


def heat_metal(name="metal_heat", axis=2, start=0.0, length=1.0):
    """Titanium with heat tint (straw -> purple -> blue) running along a local object axis:
    0 = cold end at `start`, fully tinted at `start + length`."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    m, b, out = _mat(name)
    tc = b.new("ShaderNodeTexCoord").outputs["Object"]
    sep = b.new("ShaderNodeSeparateXYZ")
    b.set(sep.inputs[0], tc)
    t = b.math("DIVIDE", b.math("SUBTRACT", sep.outputs[axis], start), length)
    wob = b.noise(tc, 9.0, 4.0, 0.6)
    t = b.math("ADD", t, b.math("MULTIPLY", b.math("SUBTRACT", wob, 0.5), 0.22), clamp=True)
    col = b.ramp(t, [(0.0, (0.33, 0.32, 0.31)), (0.35, (0.36, 0.30, 0.20)), (0.58, (0.30, 0.14, 0.20)),
                     (0.78, (0.10, 0.13, 0.32)), (1.0, (0.05, 0.06, 0.09))])
    g = b.new("ShaderNodeGroup", node_tree=surface_group())
    b.set(g.inputs["Color"], col)
    g.inputs["Roughness"].default_value = 0.30
    g.inputs["Metallic"].default_value = 1.0
    g.inputs["Wear"].default_value = 0.2
    g.inputs["Grime"].default_value = 0.8
    g.inputs["Micro"].default_value = 0.6
    m.node_tree.links.new(g.outputs[0], out.inputs["Surface"])
    m.diffuse_color = (0.3, 0.25, 0.3, 1.0)
    return m


# ------------------------------------------------------------------------------------------
# named library
# ------------------------------------------------------------------------------------------
_LIB = {
    # painted panels (same paint as the hull slots)
    "paint_white":   lambda n: surface(n, PAINTS[0][1], 0.36, 0.0, 0.35, 0.55, 0.5),
    "paint_dark":    lambda n: surface(n, PAINTS[1][1], 0.42, 0.0, 0.15, 0.55, 0.5),
    "paint_accent":  lambda n: surface(n, PAINTS[2][1], 0.38, 0.0, 0.35, 0.55, 0.5),
    "paint_hazard":  lambda n: surface(n, PAINTS[4][1], 0.45, 0.0, 0.10, 0.60, 0.6),
    "paint_grey":    lambda n: surface(n, PAINTS[6][1], 0.40, 0.0, 0.25, 0.55, 0.5),
    # metals
    "metal_dark":    lambda n: surface(n, (0.105, 0.108, 0.115), 0.40, 1.0, 0.0, 0.35, 0.7, chip=(0.42, 0.42, 0.43)),
    "metal_steel":   lambda n: surface(n, (0.420, 0.415, 0.405), 0.30, 1.0, 0.0, 0.10, 0.6),
    "metal_alu":     lambda n: surface(n, (0.640, 0.640, 0.650), 0.26, 1.0, 0.0, 0.05, 0.4),
    "metal_chrome":  lambda n: surface(n, (0.800, 0.800, 0.810), 0.07, 1.0, 0.0, 0.0, 0.15, micro=0.0),
    "metal_brass":   lambda n: surface(n, (0.620, 0.420, 0.170), 0.30, 1.0, 0.0, 0.1, 0.5),
    "metal_soot":    lambda n: surface(n, (0.022, 0.021, 0.020), 0.70, 0.8, 0.0, 0.1, 1.0),
    "metal_heat":    lambda n: heat_metal(n),
    # misc
    "inner_dark":    lambda n: surface(n, (0.020, 0.021, 0.023), 0.55, 0.6, 0.0, 0.0, 0.8, micro=0.5),
    "rubber":        lambda n: surface(n, (0.012, 0.012, 0.013), 0.78, 0.0, 0.0, 0.0, 0.9, micro=2.0),
    "plastic_black": lambda n: surface(n, (0.020, 0.020, 0.022), 0.45, 0.0, 0.0, 0.1, 0.4),
    "ceramic":       lambda n: surface(n, (0.035, 0.036, 0.040), 0.22, 0.0, 0.5, 0.0, 0.5),
    "glass_dark":    lambda n: glass(n),
    "lens_clear":    lambda n: surface(n, (0.75, 0.80, 0.85), 0.03, 0.0, 1.0, 0.0, 0.1, micro=0.0),
    # emissives (strength in W/m2-ish; tuned for the studio exposure)
    "emit_engine":   lambda n: emissive(n, (0.25, 0.62, 1.0), 60.0),
    "emit_engine_hot": lambda n: emissive(n, (0.80, 0.93, 1.0), 220.0),
    "emit_cyan":     lambda n: emissive(n, (0.15, 0.80, 1.0), 14.0),
    "emit_white":    lambda n: emissive(n, (1.0, 0.96, 0.90), 30.0),
    "emit_red":      lambda n: emissive(n, (1.0, 0.03, 0.02), 18.0),
    "emit_green":    lambda n: emissive(n, (0.03, 1.0, 0.12), 14.0),
    "emit_amber":    lambda n: emissive(n, (1.0, 0.42, 0.04), 16.0),
    "hull_paint":    lambda n: hull_paint(n),
}


def get(name):
    """Fetch (creating on first use) a library material by name."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    if name not in _LIB:
        raise KeyError("unknown material '%s'; have: %s" % (name, ", ".join(sorted(_LIB))))
    return _LIB[name](name)


def names():
    return sorted(_LIB)
