"""ST-7 Tern -> game-ready asset: low-poly LODs, baked PBR atlases, decal atlas, glTF export.

    blender -b --factory-startup -P tools/blender/tern/game/export_game.py -- [--rebake=all|A,B,C|A_color,...]
            [--samples=16] [--nobake] [--noexport] [--blend]

Output: assets/models/tern/tern_lod{0,1,2}.gltf (+ .bin, shared WebP textures).
Bakes are cached as PNG in build/tern/game/ (delete them or pass --rebake to redo).
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402  (sets sys.path for the tern modules)

import bpy  # noqa: E402
from mathutils import Matrix  # noqa: E402

import bake as BK  # noqa: E402
import decals as DC  # noqa: E402
import hull as H  # noqa: E402
import kit  # noqa: E402
import parts_low as PL  # noqa: E402
import ship  # noqa: E402
import studio  # noqa: E402

ATLASES = ("A", "B", "C")
PASSES = ("color", "orm", "normal", "emit")
META = os.path.join(C.BUILD, "bake_meta.json")


def log(*a):
    print("[tern-game]", *a, flush=True)


def build_high():
    cap = {}
    orig = ship.build_decals

    def capture(col, bodies):
        cap["bodies"] = bodies
        return orig(col, bodies)

    ship.build_decals = capture
    high = kit.collection("High")
    ship.build(high, {})
    ship.build_decals = orig
    cls = PL.classify(high)
    for ob in cls["cockpit"] + cls["decal"]:
        bpy.data.objects.remove(ob)
    tc = bpy.data.collections.get("TernTemplates")
    if tc is not None:
        tc.hide_render = True
    return high, cls, cap["bodies"]


def build_parts(cls, work):
    uniq = {}
    for ob in sorted(cls["kept"], key=lambda o: o.name):
        uniq.setdefault(ob.data.name, []).append(ob)
    lows = {}
    for mname, insts in uniq.items():
        t = time.time()
        lo = PL.make_low(insts[0], work)
        lows[mname] = lo
        log("PART %-18s %-14s inst=%d tris %d -> %d (%.1fs)" % (mname, PL.base(mname), len(insts),
                                                              C.tris(insts[0].data), C.tris(lo.data), time.time() - t))
    PL.unwrap_parts(list(lows.values()))
    return uniq, lows


def join_copies(objs, name, col):
    cps = []
    for o in objs:
        c = o.copy()
        c.data = o.data.copy()
        col.objects.link(c)
        cps.append(c)
    for c in cps:
        kit.bake_transform(c)
    ob = kit.join(cps, name)
    C.no_rays(ob)
    return ob


def uv_hash(objs):
    import hashlib
    import numpy as np
    h = hashlib.sha1()
    for o in objs:
        me = o.data
        a = np.empty(len(me.loops) * 2, dtype=np.float32)
        me.uv_layers.active.data.foreach_get("uv", a)
        h.update(np.round(a, 5).tobytes())
    return h.hexdigest()


def run_bakes(opt, jobs, hashes):
    meta = BK.load_meta(META)
    rebake = opt.get("rebake", "")
    for atlas, hv in hashes.items():       # the cache is only valid for the UV layout it was baked with
        if meta.get("uvhash_" + atlas) != hv:
            rebake += "," + atlas
            log("UV layout of atlas %s changed: rebaking it" % atlas)
    samples = int(opt.get("samples", 16))
    for atlas in ATLASES:
        for pas in PASSES:
            key = "%s_%s" % (atlas, pas)
            path = os.path.join(C.BUILD, "tern_%s.png" % key)
            force = rebake == "all" or atlas in rebake.split(",") or key in rebake.split(",")
            if os.path.exists(path) and key in meta and not force:
                continue
            if pas == "emit" and key in meta and meta[key].get("scale", 1) == 0 and not force:
                continue
            kind, mode, init = BK.PASSES[pas]
            img = BK.new_image("bake_" + key, init)
            BK.set_mode(mode)
            t = time.time()
            for low, srcs, ext, maxd, margin in jobs[atlas]:
                BK.bake_into(img, low, srcs, kind, ext, maxd, margin=margin, samples=samples)
            m = BK.finish(img, pas, path)
            m["seconds"] = round(time.time() - t, 1)
            meta[key] = m
            BK.save_meta(META, {key: m, "uvhash_" + atlas: hashes[atlas]})
            bpy.data.images.remove(img)
            log("BAKE %s %.1fs %s" % (key, time.time() - t, m))
    BK.set_mode(0)
    return meta


# ------------------------------------------------------------------------------------------
# export materials
# ------------------------------------------------------------------------------------------
def _gltf_output_group():
    ng = bpy.data.node_groups.get("glTF Material Output")
    if ng is None:
        ng = bpy.data.node_groups.new("glTF Material Output", "ShaderNodeTree")
        ng.interface.new_socket(name="Occlusion", in_out="INPUT", socket_type="NodeSocketFloat")
    return ng


def _img(name, colorspace):
    path = os.path.join(C.BUILD, name + ".png")
    img = bpy.data.images.get(name)
    if img is None:
        img = bpy.data.images.load(path)
        img.name = name
    img.colorspace_settings.name = colorspace
    return img


def pbr_material(name, atlas, meta):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    p = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    tex = lambda img: (lambda t: (setattr(t, "image", img), t)[1])(nt.nodes.new("ShaderNodeTexImage"))  # noqa: E731
    col = tex(_img("tern_%s_color" % atlas, "sRGB"))
    nt.links.new(col.outputs["Color"], p.inputs["Base Color"])
    orm = tex(_img("tern_%s_orm" % atlas, "Non-Color"))
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(orm.outputs["Color"], sep.inputs[0])
    nt.links.new(sep.outputs[1], p.inputs["Roughness"])
    nt.links.new(sep.outputs[2], p.inputs["Metallic"])
    g = nt.nodes.new("ShaderNodeGroup")
    g.node_tree = _gltf_output_group()
    nt.links.new(sep.outputs[0], g.inputs["Occlusion"])
    nrm = tex(_img("tern_%s_normal" % atlas, "Non-Color"))
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(nrm.outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], p.inputs["Normal"])
    em = meta.get("%s_emit" % atlas, {})
    if em.get("scale", 0) > 0:
        e = tex(_img("tern_%s_emit" % atlas, "sRGB"))
        nt.links.new(e.outputs["Color"], p.inputs["Emission Color"])
        p.inputs["Emission Strength"].default_value = em["scale"]
    p.inputs["Specular IOR Level"].default_value = 0.5
    return m


def glass_material():
    m = bpy.data.materials.new("glass")
    m.use_nodes = True
    p = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    p.inputs["Base Color"].default_value = (0.006, 0.008, 0.012, 1.0)
    p.inputs["Roughness"].default_value = 0.05
    p.inputs["Metallic"].default_value = 0.0
    p.inputs["Specular IOR Level"].default_value = 0.7
    return m


def decal_material(path):
    m = bpy.data.materials.new("decals")
    m.use_nodes = True
    nt = m.node_tree
    p = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    img = bpy.data.images.load(path)
    img.name = "tern_decals"
    img.colorspace_settings.name = "sRGB"
    img.alpha_mode = "STRAIGHT"
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = img
    nt.links.new(t.outputs["Color"], p.inputs["Base Color"])
    nt.links.new(t.outputs["Alpha"], p.inputs["Alpha"])
    p.inputs["Roughness"].default_value = 0.46
    try:
        m.surface_render_method = "BLENDED"
    except (AttributeError, TypeError):
        pass
    return m


# ------------------------------------------------------------------------------------------
def export_lod(lod, lods, uniq, lows, part_lods, mats, entries, rects, out_dir):
    col = kit.collection("LOD%d" % lod)
    objs = []
    root = bpy.data.objects.new("Tern", None)
    col.objects.link(root)
    objs.append(root)

    def child(ob, parent):
        if ob.name not in col.objects:
            col.objects.link(ob)
        mw = ob.matrix_world.copy()
        ob.parent = parent
        ob.matrix_parent_inverse = Matrix.Identity(4)
        ob.matrix_world = mw
        objs.append(ob)
        return ob

    names = list(lods[lod].keys())
    hull = H.assemble(lods[lod], names, col, "Hull", mat_of=lambda n: 0 if H.BODIES[n.replace("_L", "_R")][0] == "A" else 1,
                      keep_glass=False)
    hull.data.name = "Hull_lod%d" % lod
    hull.data.materials.append(mats["A"])
    hull.data.materials.append(mats["B"])
    child(hull, root)
    glass = H.assemble(lods[lod], ["fuselage"], col, "Glass", only_glass=True)
    glass.data.name = "Glass_lod%d" % lod
    for p in glass.data.polygons:
        p.material_index = 0
    glass.data.materials.append(mats["glass"])
    child(glass, root)
    bvhs = {n: H.body_bvh(b) for n, b in lods[lod].items()}
    dec = DC.build_quads(entries, rects, bvhs, lod, col, mats["decals"])
    dec.data.name = "Decals_lod%d" % lod
    child(dec, root)
    fit = bpy.data.objects.new("Fittings", None)
    col.objects.link(fit)
    child(fit, root)
    stats = {"Hull": C.tris(hull.data), "Glass": C.tris(glass.data), "Decals": C.tris(dec.data)}
    for mname, insts in uniq.items():
        me = part_lods[lod].get(mname)
        if me is None:
            continue
        for nn, loc, rot in insts:
            ob = bpy.data.objects.new(nn, me)
            ob.matrix_world = Matrix.LocRotScale(loc, rot, None)
            child(ob, fit if PL.base(mname) in PL.FITTINGS else root)
            stats[nn] = C.tris(me)
    total = sum(stats.values())
    log("LOD%d triangles %d  %s" % (lod, total, stats))
    vl = bpy.context.view_layer
    vl.active_layer_collection = vl.layer_collection.children[col.name]
    path = os.path.join(out_dir, "tern_lod%d.gltf" % lod)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", use_active_collection=True,
                              use_active_collection_with_nested=True, export_image_format="WEBP",
                              export_image_quality=90, export_yup=True, export_apply=False, export_tangents=True,
                              export_normals=True, export_texcoords=True, export_materials="EXPORT",
                              export_animations=False, export_cameras=False, export_lights=False,
                              export_extras=False)
    # free the node names for the next LOD
    for o in objs:
        bpy.data.objects.remove(o)
    return total, stats


def main():
    opt = C.options()
    C.TEX = int(opt.get("tex", C.TEX))
    C.ensure_dirs()
    t0 = time.time()
    studio.reset()
    studio.setup_cycles(res=(64, 64), samples=16, denoise=False)
    high, cls, bodies = build_high()
    log("HIGH built %.1fs: hull=%d kept=%d flush=%d" % (time.time() - t0, len(cls["hull"]), len(cls["kept"]),
                                                        len(cls["flush"])))
    work = kit.collection("Work")
    uniq, lows = build_parts(cls, work)
    refs = {}
    for a in ("A", "B"):
        ref = H.unwrap_atlas(a, work)
        td, auv = H.texel_density(ref)
        log("ATLAS %s texel density %.0f px/m, uv coverage %.1f%%" % (a, td, auv * 100))
        refs[a] = H.UVRef(ref)
        C.no_rays(ref)
    tdc = [H.texel_density(o) for o in lows.values()]
    log("ATLAS C texel density %.0f px/m, uv coverage %.1f%%" % (
        sum(t for t, _ in tdc) / len(tdc), sum(a for _, a in tdc) * 100))
    lods = {lod: H.lod_bodies(lod, refs, bays=(lod < 2)) for lod in (0, 1, 2)}
    log("LOW bodies %.1fs" % (time.time() - t0))
    for o in lows.values():
        C.no_rays(o)

    meta = BK.load_meta(META)
    if "nobake" not in opt:
        BK.patch_surface_group()
        used = {m for o in high.objects if o.type == "MESH" for m in o.data.materials}
        BK.patch_materials(used)
        n = PL.strip_lenses([o for o in high.objects if o.type == "MESH"])
        log("lens meshes stripped for baking: %d" % n)
        bakeA = H.assemble(lods[0], ["fuselage", "cheek_R", "spike_R"], work, "bakeA", keep_glass=False)
        bakeB = H.assemble(lods[0], ["pod_R", "wing_R", "fin_R", "tip_R"], work, "bakeB")
        for o in (bakeA, bakeB):
            C.no_rays(o)
        trees = [m.node_tree for m in used if m is not None and m.node_tree] + [bpy.data.node_groups["TernSurface"]]
        log("object-space links rerouted: %d" % BK.object_coords_to_attribute(trees))
        tj = time.time()
        jcol = kit.collection("BakeSources")
        hull_src = [BK.joined_source(cls["hull"] + cls["flush"], "J_hull", jcol)]
        part_src = [BK.joined_source([uniq[m][0] for m in uniq], "J_parts", jcol)]
        log("bake sources joined %.1fs" % (time.time() - tj))
        groups = {}
        for mname, lo in lows.items():
            groups.setdefault(PL.KEEP[PL.base(mname)][2], []).append(mname)
        jobsC = []
        params = {"fine": (0.015, 0.06), "mid": (0.05, 0.30), "bay": (0.10, 0.30)}
        for g, mnames in groups.items():
            bo = join_copies([lows[m] for m in mnames], "bakeC_" + g, work)
            jobsC.append((bo, part_src, *params[g], 4))
        jobs = {"A": [(bakeA, hull_src, 0.05, 0.30, 6)], "B": [(bakeB, hull_src, 0.05, 0.30, 6)], "C": jobsC}
        tb = time.time()
        meta = run_bakes(opt, jobs, {"A": uv_hash([bakeA]), "B": uv_hash([bakeB]),
                                     "C": uv_hash([j[0] for j in jobsC])})
        log("BAKES done %.1fs" % (time.time() - tb))
    if "blend" in opt:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(C.BUILD, "tern_game_work.blend"))
    if "noexport" in opt:
        return

    # part LOD meshes
    part_lods = {0: {}, 1: {}, 2: {}}
    for mname, lo in lows.items():
        part_lods[0][mname] = lo.data
        r1, r2 = PL.LOD_RATIO[PL.base(mname)]
        part_lods[1][mname] = PL.lod_copy(lo, r1, work, "_lod1", 0.04).data
        if r2 is not None:
            part_lods[2][mname] = PL.lod_copy(lo, r2, work, "_lod2", 0.15).data
    for lod in (0, 1, 2):
        for mname, me in part_lods[lod].items():
            me.name = "%s_lod%d" % (PL.node_name(uniq[mname][0]), lod)

    entries = DC.collect(bodies)
    dpath = os.path.join(C.BUILD, "tern_decals.png")
    rects = DC.build_atlas(entries, dpath)
    mats = {a: pbr_material("hull_" + a if a != "C" else "parts_C", a, meta) for a in ATLASES}
    mats["glass"] = glass_material()
    mats["decals"] = decal_material(dpath)
    for lod, me_map in part_lods.items():
        for me in me_map.values():
            me.materials.clear()
            me.materials.append(mats["C"])
    placements = {m: [(PL.node_name(i),) + tuple(i.matrix_world.decompose()[:2]) for i in insts]
                  for m, insts in uniq.items()}
    for o in list(high.objects):
        bpy.data.objects.remove(o)
    totals = {}
    for lod in (0, 1, 2):
        totals[lod] = export_lod(lod, lods, placements, lows, part_lods, mats, entries, rects, C.ASSETS)
    log("EXPORT done %.1fs  totals %s" % (time.time() - t0, {k: v[0] for k, v in totals.items()}))


main()
