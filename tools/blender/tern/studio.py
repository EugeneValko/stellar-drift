"""Render harness: Cycles/OptiX setup, studio lighting, auto-framed cameras, contact sheets."""
import math
import os

import bpy
import numpy as np
from mathutils import Matrix, Vector

V = Vector

VIEWS = {  # direction from the target towards the eye (ship space: +Y is the nose)
    "front34": (0.62, 1.0, 0.36),
    "rear34": (0.72, -1.0, 0.40),
    "side": (1.0, 0.0, 0.06),
    "top": (0.0, 0.02, 1.0),
    "front": (0.0, 1.0, 0.10),
    "rear": (0.0, -1.0, 0.14),
    "low34": (0.75, 1.0, -0.12),
    "bottom34": (0.6, 0.8, -0.75),
    "left34": (-0.62, 1.0, 0.36),
    "rearleft34": (-0.72, -1.0, 0.40),
    "door34": (-0.75, 0.45, 0.85),
}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return bpy.context.scene


def setup_cycles(res=(1280, 720), samples=96, denoise=True, look="AgX - Medium High Contrast", exposure=0.0):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for t in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = t
            prefs.refresh_devices()
            got = False
            for d in prefs.devices:
                d.use = d.type == t
                got = got or d.use
            if got:
                sc.cycles.device = "GPU"
                break
        except Exception:
            continue
    c = sc.cycles
    c.samples = samples
    c.use_adaptive_sampling = True
    c.adaptive_threshold = 0.02
    c.use_denoising = denoise
    try:
        c.denoiser = "OPENIMAGEDENOISE"
        c.denoising_use_gpu = True
    except Exception:
        pass
    c.max_bounces = 8
    c.glossy_bounces = 6
    c.transmission_bounces = 8
    c.transparent_max_bounces = 8
    c.sample_clamp_indirect = 8.0
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "AgX"
    try:
        sc.view_settings.look = look
    except TypeError:
        pass
    sc.view_settings.exposure = exposure
    return sc


def world(top=(0.020, 0.024, 0.032), horizon=(0.060, 0.066, 0.078), strength=1.0):
    """Soft vertical gradient world."""
    w = bpy.data.worlds.new("StudioWorld")
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    mp = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(geo.outputs["Incoming"], sep.inputs[0])
    nt.links.new(sep.outputs[2], mp.inputs["Value"])
    mp.inputs["From Min"].default_value = -1.0
    mp.inputs["From Max"].default_value = 1.0
    nt.links.new(mp.outputs[0], ramp.inputs[0])
    e = ramp.color_ramp.elements
    e[0].position, e[0].color = 0.35, tuple(top) + (1,)
    e[1].position, e[1].color = 0.52, tuple(horizon) + (1,)
    e2 = ramp.color_ramp.elements.new(0.75)
    e2.color = tuple(top) + (1,)
    nt.links.new(ramp.outputs[0], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = strength
    nt.links.new(bg.outputs[0], out.inputs["Surface"])
    bpy.context.scene.world = w
    return w


def area_light(name, loc, target, size=(4.0, 4.0), power=1000.0, color=(1, 1, 1), col=None, spread=None):
    ld = bpy.data.lights.new(name, "AREA")
    ld.shape = "RECTANGLE"
    ld.size, ld.size_y = size
    ld.energy = power
    ld.color = color
    if spread is not None:
        ld.spread = math.radians(spread)
    ob = bpy.data.objects.new(name, ld)
    (col or bpy.context.scene.collection).objects.link(ob)
    ob.location = loc
    ob.rotation_euler = (V(target) - V(loc)).to_track_quat("-Z", "Y").to_euler()
    return ob


def floor_plane(z, size=400.0, color=(0.045, 0.047, 0.052), rough=0.32, col=None):
    me = bpy.data.meshes.new("Floor")
    h = size / 2
    me.from_pydata([(-h, -h, z), (h, -h, z), (h, h, z), (-h, h, z)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new("Floor", me)
    (col or bpy.context.scene.collection).objects.link(ob)
    m = bpy.data.materials.new("StudioFloor")
    m.use_nodes = True
    p = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    p.inputs["Base Color"].default_value = tuple(color) + (1,)
    p.inputs["Roughness"].default_value = rough
    me.materials.append(m)
    return ob


def studio_rig(lo, hi, floor=True, key=1.0, col=None):
    """Three soft boxes + top strip sized to the bounding box (lo, hi). Returns the created objects."""
    lo, hi = V(lo), V(hi)
    c = (lo + hi) / 2
    r = (hi - lo).length / 2
    d = r * 2.4
    k = d * d * key
    objs = [
        area_light("Key", c + V((0.75, 0.55, 0.85)).normalized() * d, c, (r * 2.2, r * 1.4), 11.0 * k, (1.0, 0.96, 0.90), col),
        area_light("Fill", c + V((-0.9, 0.35, 0.25)).normalized() * d, c, (r * 2.0, r * 2.0), 2.2 * k, (0.80, 0.88, 1.0), col),
        area_light("Rim", c + V((-0.35, -0.9, 0.55)).normalized() * d, c, (r * 2.4, r * 0.9), 13.0 * k, (0.78, 0.88, 1.0), col),
        area_light("Top", c + V((0.0, 0.0, 1.0)) * d * 0.9, c, (r * 3.0, r * 0.7), 4.5 * k, (1.0, 1.0, 1.0), col),
    ]
    if floor:
        objs.append(floor_plane(lo.z - 1e-4, size=max(60.0, r * 40), col=col))
    return objs


def make_camera(name="Cam", lens=70.0, col=None):
    cd = bpy.data.cameras.new(name)
    cd.lens = lens
    cd.sensor_width = 36.0
    cd.clip_start = 0.01
    cd.clip_end = 5000.0
    ob = bpy.data.objects.new(name, cd)
    (col or bpy.context.scene.collection).objects.link(ob)
    bpy.context.scene.camera = ob
    return ob


def aim_camera(cam, lo, hi, direction, margin=1.08, target=None):
    """Place `cam` along `direction` (target -> eye) so that the box (lo, hi) fills the frame."""
    sc = bpy.context.scene
    lo, hi = V(lo), V(hi)
    c = V(target) if target is not None else (lo + hi) / 2
    d = V(direction).normalized()
    quat = (-d).to_track_quat("-Z", "Y")
    rot = quat.to_matrix()
    right, up = rot.col[0], rot.col[1]
    aspect = sc.render.resolution_x / sc.render.resolution_y
    th = math.atan(cam.data.sensor_width / 2 / cam.data.lens)
    tv = math.atan(math.tan(th) / aspect)
    dist = 0.0
    for x in (lo.x, hi.x):
        for y in (lo.y, hi.y):
            for z in (lo.z, hi.z):
                p = V((x, y, z)) - c
                dist = max(dist, p.dot(d) + abs(p.dot(right)) / math.tan(th), p.dot(d) + abs(p.dot(up)) / math.tan(tv))
    cam.location = c + d * dist * margin
    cam.rotation_euler = quat.to_euler()
    return cam


def gdignore(folder):
    """Keep Godot from importing preview output: drop a .gdignore into build/tern (if `folder` is inside it)."""
    d = os.path.abspath(folder)
    while True:
        parent = os.path.dirname(d)
        if os.path.basename(d) == "tern" and os.path.basename(parent) == "build":
            marker = os.path.join(d, ".gdignore")
            if not os.path.exists(marker):
                open(marker, "w").close()
            return
        if parent == d:
            return
        d = parent


def render(path):
    sc = bpy.context.scene
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    gdignore(os.path.dirname(path))
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def contact_sheet(paths, out, cols=2, scale=1.0):
    """Tile PNGs into one image (all the same size)."""
    out = os.path.abspath(out)
    tiles = []
    for p in paths:
        img = bpy.data.images.load(p)
        w, h = img.size
        a = np.empty(w * h * 4, dtype=np.float32)
        img.pixels.foreach_get(a)
        tiles.append(a.reshape(h, w, 4))
        bpy.data.images.remove(img)
    h, w = tiles[0].shape[:2]
    if scale != 1.0:
        st = max(1, int(round(1 / scale)))
        tiles = [t[::st, ::st] for t in tiles]
        h, w = tiles[0].shape[:2]
    rows = (len(tiles) + cols - 1) // cols
    sheet = np.zeros((rows * h, cols * w, 4), dtype=np.float32)
    sheet[..., 3] = 1.0
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        y0 = (rows - 1 - r) * h
        sheet[y0:y0 + h, c * w:(c + 1) * w] = t
    img = bpy.data.images.new("sheet", cols * w, rows * h, alpha=False)
    img.pixels.foreach_set(sheet.ravel())
    img.filepath_raw = out
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    return out


def clay_override(on=True):
    vl = bpy.context.view_layer
    if not on:
        vl.material_override = None
        return
    m = bpy.data.materials.get("Clay")
    if m is None:
        m = bpy.data.materials.new("Clay")
        m.use_nodes = True
        p = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        p.inputs["Base Color"].default_value = (0.55, 0.55, 0.56, 1)
        p.inputs["Roughness"].default_value = 0.45
    vl.material_override = m


def render_views(out_dir, lo, hi, views=("front34", "rear34", "side", "top"), prefix="", lens=70.0, margin=1.08,
                 sheet=True, cols=2, cam=None):
    """Render named views (see VIEWS; a view may also be a (name, direction) tuple). Returns file paths."""
    os.makedirs(out_dir, exist_ok=True)
    cam = cam or make_camera(lens=lens)
    cam.data.lens = lens
    paths = []
    for v in views:
        name, d = (v, VIEWS[v]) if isinstance(v, str) else v
        aim_camera(cam, lo, hi, d, margin)
        paths.append(render(os.path.join(out_dir, prefix + name + ".png")))
    if sheet and len(paths) > 1:
        contact_sheet(paths, os.path.join(out_dir, prefix + "sheet.png"), cols)
    return paths
