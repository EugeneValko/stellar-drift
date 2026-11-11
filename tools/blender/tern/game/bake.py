"""Bake support: runtime patch of the hero materials (one global mode switch) and the Cycles bake runner.

Mode (value of the node group "GameBakeMode"):
    0  untouched shaders (NORMAL and EMIT passes)
    1  emission = final base colour (the socket feeding Principled "Base Color" - grime / chips / tone included)
    2  emission = ORM: (ambient occlusion, roughness, metallic)
"""
import json
import os

import bpy
import numpy as np

import common as C

AO_DIST = 0.6


def _mode_group():
    ng = bpy.data.node_groups.get("GameBakeMode")
    if ng is None:
        ng = bpy.data.node_groups.new("GameBakeMode", "ShaderNodeTree")
        ng.interface.new_socket(name="Mode", in_out="OUTPUT", socket_type="NodeSocketFloat")
        v = ng.nodes.new("ShaderNodeValue")
        v.name = "MODE"
        v.outputs[0].default_value = 0.0
        out = ng.nodes.new("NodeGroupOutput")
        ng.links.new(v.outputs[0], out.inputs[0])
    return ng


def set_mode(m):
    _mode_group().nodes["MODE"].outputs[0].default_value = float(m)


def _switch(nt, orig_out, col_sock, orm):
    """Insert mode switch after `orig_out` (a shader socket). col_sock: socket or RGB tuple; orm: (ao, r, m) sockets or
    values. Returns the switched shader output socket."""
    n = nt.nodes
    mode = n.new("ShaderNodeGroup")
    mode.node_tree = _mode_group()
    is1 = n.new("ShaderNodeMath")
    is1.operation = "COMPARE"
    is1.inputs[1].default_value = 1.0
    is1.inputs[2].default_value = 0.25
    nt.links.new(mode.outputs[0], is1.inputs[0])
    is2 = n.new("ShaderNodeMath")
    is2.operation = "COMPARE"
    is2.inputs[1].default_value = 2.0
    is2.inputs[2].default_value = 0.25
    nt.links.new(mode.outputs[0], is2.inputs[0])
    e1 = n.new("ShaderNodeEmission")
    e1.inputs["Strength"].default_value = 1.0
    if isinstance(col_sock, bpy.types.NodeSocket):
        nt.links.new(col_sock, e1.inputs["Color"])
    else:
        e1.inputs["Color"].default_value = tuple(col_sock) + (1.0,)
    comb = n.new("ShaderNodeCombineColor")
    for k, v in enumerate(orm):
        if isinstance(v, bpy.types.NodeSocket):
            nt.links.new(v, comb.inputs[k])
        else:
            comb.inputs[k].default_value = v
    e2 = n.new("ShaderNodeEmission")
    e2.inputs["Strength"].default_value = 1.0
    nt.links.new(comb.outputs[0], e2.inputs["Color"])
    m1 = n.new("ShaderNodeMixShader")
    nt.links.new(is1.outputs[0], m1.inputs[0])
    nt.links.new(orig_out, m1.inputs[1])
    nt.links.new(e1.outputs[0], m1.inputs[2])
    m2 = n.new("ShaderNodeMixShader")
    nt.links.new(is2.outputs[0], m2.inputs[0])
    nt.links.new(m1.outputs[0], m2.inputs[1])
    nt.links.new(e2.outputs[0], m2.inputs[2])
    return m2.outputs[0]


def _ao(nt):
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.samples = 16
    ao.inputs["Distance"].default_value = AO_DIST
    return ao.outputs["AO"]


def patch_surface_group(micro=0.35):
    """TernSurface: switchable outputs; the micro orange-peel bump is scaled by `micro` (it only becomes noise at
    ~3 mm texels)."""
    ng = bpy.data.node_groups["TernSurface"]
    if ng.get("game_patched"):
        return
    p = next(nd for nd in ng.nodes if nd.type == "BSDF_PRINCIPLED")
    go = next(nd for nd in ng.nodes if nd.type == "GROUP_OUTPUT")

    def src(name):
        s = p.inputs[name]
        return s.links[0].from_socket if s.is_linked else s.default_value

    col = src("Base Color")
    if not isinstance(col, bpy.types.NodeSocket):
        col = tuple(col)[:3]
    out = _switch(ng, p.outputs[0], col, (_ao(ng), src("Roughness"), src("Metallic")))
    ng.links.new(out, go.inputs["BSDF"])
    bump = next(nd for nd in ng.nodes if nd.type == "BUMP")
    s = bump.inputs["Strength"]
    if s.is_linked:
        mul = ng.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.inputs[1].default_value = micro
        ng.links.new(s.links[0].from_socket, mul.inputs[0])
        ng.links.new(mul.outputs[0], s)
    ng["game_patched"] = 1


def patch_materials(mats):
    """Non-TernSurface materials: emitters -> black albedo, glass -> dark gloss."""
    for m in mats:
        if m is None or not m.use_nodes or m.get("game_patched"):
            continue
        nt = m.node_tree
        out = next((nd for nd in nt.nodes if nd.type == "OUTPUT_MATERIAL"), None)
        if out is None or not out.inputs["Surface"].is_linked:
            continue
        src = out.inputs["Surface"].links[0].from_socket
        kinds = {nd.type for nd in nt.nodes}
        if "GROUP" in kinds and any(nd.type == "GROUP" and nd.node_tree and nd.node_tree.name == "TernSurface"
                                    for nd in nt.nodes):
            m["game_patched"] = 1
            continue                                # handled by the shared group
        if src.node.type == "EMISSION":
            sw = _switch(nt, src, (0.0, 0.0, 0.0), (1.0, 0.35, 0.0))
        elif m.name.startswith("glass"):
            sw = _switch(nt, src, (0.004, 0.006, 0.009), (1.0, 0.05, 0.0))
        else:
            p = next((nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED"), None)
            if p is None:
                continue
            col = tuple(p.inputs["Base Color"].default_value)[:3]
            sw = _switch(nt, src, col, (_ao(nt), p.inputs["Roughness"].default_value,
                                        p.inputs["Metallic"].default_value))
        nt.links.new(sw, out.inputs["Surface"])
        m["game_patched"] = 1


def object_coords_to_attribute(trees):
    """Shaders read 'Object' texture coordinates; a joined bake source has one object space for everything, so every
    TexCoord.Object link is rerouted to the per-vertex attribute 'lco' (original object-space position)."""
    n = 0
    for nt in trees:
        for tc in [nd for nd in nt.nodes if nd.type == "TEX_COORD"]:
            links = list(tc.outputs["Object"].links)
            if not links:
                continue
            at = nt.nodes.new("ShaderNodeAttribute")
            at.attribute_type = "GEOMETRY"
            at.attribute_name = "lco"
            for lk in links:
                nt.links.new(at.outputs["Vector"], lk.to_socket)
                n += 1
    return n


def joined_source(objs, name, col):
    """One mesh for a set of bake sources: Blender casts every bake ray against each selected object separately
    (single-threaded), so ~90 sources cost ~90x. Original object-space positions are kept in attribute 'lco'."""
    import kit
    cps = []
    for o in objs:
        me = o.data.copy()
        co = np.empty(len(me.vertices) * 3, dtype=np.float32)
        me.vertices.foreach_get("co", co)
        a = me.attributes.new("lco", "FLOAT_VECTOR", "POINT")
        a.data.foreach_set("vector", co)
        c = bpy.data.objects.new(o.name + "_j", me)
        col.objects.link(c)
        c.matrix_world = o.matrix_world.copy()
        cps.append(c)
    for c in cps:
        kit.bake_transform(c)
    j = kit.join(cps, name)
    for o in objs:
        o.hide_render = True
    return j


# ------------------------------------------------------------------------------------------
PASSES = {  # pass -> (bake type, mode, init RGBA)
    "color": ("EMIT", 1, (0.0, 0.0, 0.0, 0.0)),
    "orm": ("EMIT", 2, (1.0, 0.5, 0.0, 0.0)),
    "normal": ("NORMAL", 0, (0.5, 0.5, 1.0, 0.0)),
    "emit": ("EMIT", 0, (0.0, 0.0, 0.0, 0.0)),
}


def new_image(name, init, size=None):
    size = size or C.TEX
    img = bpy.data.images.get(name)
    if img is not None:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(name, size, size, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    a = np.empty((size * size, 4), dtype=np.float32)
    a[:] = init
    img.pixels.foreach_set(a.ravel())
    return img


def target_material(img):
    m = bpy.data.materials.new("bake_target")
    m.use_nodes = True
    t = m.node_tree.nodes.new("ShaderNodeTexImage")
    t.image = img
    m.node_tree.nodes.active = t
    return m


def bake_into(img, low, sources, kind, ext, maxd, margin=6, samples=16):
    """Selected-to-active bake of `sources` onto `low` into img (no clear)."""
    sc = bpy.context.scene
    sc.cycles.samples = samples
    bk = sc.render.bake
    bk.use_selected_to_active = True
    bk.cage_extrusion = ext
    bk.max_ray_distance = maxd
    bk.margin = margin
    bk.margin_type = "EXTEND"
    bk.use_clear = False
    bk.target = "IMAGE_TEXTURES"
    bk.normal_space = "TANGENT"
    bk.normal_r, bk.normal_g, bk.normal_b = "POS_X", "POS_Y", "POS_Z"
    mat = target_material(img)
    low.data.materials.clear()
    low.data.materials.append(mat)
    for p in low.data.polygons:
        p.material_index = 0
    vl = bpy.context.view_layer
    for o in vl.objects:
        o.select_set(False)
    for s in sources:
        s.select_set(True)
    low.select_set(True)
    vl.objects.active = low
    bpy.ops.object.bake(type=kind, use_selected_to_active=True, cage_extrusion=ext, max_ray_distance=maxd,
                        margin=margin, margin_type="EXTEND", use_clear=False, target="IMAGE_TEXTURES",
                        normal_space="TANGENT", normal_r="POS_X", normal_g="POS_Y", normal_b="POS_Z")
    low.data.materials.clear()
    bpy.data.materials.remove(mat)


# ------------------------------------------------------------------------------------------
# saving
# ------------------------------------------------------------------------------------------
def srgb(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1.0 / 2.4) - 0.055)


def write_png(path, arr):
    """arr: (H, W, 3|4) float 0..1, already in the target encoding; written byte-exact."""
    h, w, ch = arr.shape
    img = bpy.data.images.new("tmp_save", w, h, alpha=(ch == 4), float_buffer=False)
    img.colorspace_settings.name = "Non-Color"
    full = np.ones((h, w, 4), dtype=np.float32)
    full[..., :ch] = arr
    img.pixels.foreach_set(full.ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def pixels(img):
    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def finish(img, kind, path):
    """Convert a float bake to its 8-bit file; returns metadata (coverage, emission scale)."""
    a = pixels(img)
    cov = float((a[..., 3] > 0.5).mean())
    meta = {"coverage": cov}
    if kind == "color":
        write_png(path, srgb(a[..., :3]))
    elif kind in ("orm", "normal"):
        write_png(path, np.clip(a[..., :3], 0.0, 1.0))
    elif kind == "emit":
        e = a[..., :3].copy()
        mx = e.max(axis=2)
        e[mx < 0.05] = 0.0                      # bake noise / faint bounce: no glow
        mx = e.max(axis=2)
        lit = mx[mx > 1e-4]
        scale = float(np.percentile(lit, 99.9)) if lit.size > 50 else 0.0
        meta["lit_fraction"] = float(lit.size) / mx.size
        meta["scale"] = max(scale, 1.0) if scale > 0.02 else 0.0
        if meta["scale"] > 0:
            write_png(path, srgb(e / meta["scale"]))
    return meta


def save_meta(path, meta):
    old = {}
    if os.path.exists(path):
        with open(path) as fh:
            old = json.load(fh)
    old.update(meta)
    with open(path, "w") as fh:
        json.dump(old, fh, indent=1)


def load_meta(path):
    if os.path.exists(path):
        with open(path) as fh:
            return json.load(fh)
    return {}
