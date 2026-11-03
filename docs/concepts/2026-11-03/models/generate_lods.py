#!/usr/bin/env python3
"""Serial, non-destructive Blender 5.2 LOD and real-preview workflow.

Production brief
----------------
Target: Godot/PC static concept assets, GLB, meters, original origin/size kept.
LOD0: downloaded Tripo retopology, never overwritten. LOD1 ~50%, LOD2 ~22.5%
are candidate targets, subordinate to protected seams. The reviewed delivery
contains LOD1 for SH01/SH02/BP01/BP02 only; all tools remain base-only and
duplicate LOD2s are withheld. Preserve source UV maps, materials and 1K/2K
textures; do not resize, rebake, invent collisions, rigs or real-world scale.
Only SH01, SH02, BP01, BP02, TL01, TL02, TL03 may be decimated. AL01/CH01/CH02
are import/audit/render only, even when their downloaded file has no skin yet.

Run ONE hidden/background Blender process, serially, after downloads finish:
  blender --background --factory-startup --python generate_lods.py -- \
      --mode all --lod-previews
Modes: all, lods, previews. --dry-run and --help also work with normal Python.
--experimental-candidates generates seven static candidates/two levels into
lod_candidates/, never the published lods/ folder. It needs fresh visual QA.
The script reads jobs.json; writes lods/*, previews/*.png and lod_report.json, never jobs,
base GLBs, game assets or gallery. Existing outputs require --overwrite.

Validation is a bounded structural check, not a game-ready certification.
Decimation can change UV interpolation, baked-normal shading, narrow supports
and silhouette despite unchanged bounds. Review actual previews and test LOD
transitions in Godot before choosing screen-size thresholds. No automatic
repairs of manifold defects, faces/hands, UV packing or internal surfaces occur.
"""
from __future__ import annotations

import argparse
from array import array
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys
import traceback

STATIC_IDS = ("SH01", "SH02", "BP01", "BP02", "TL01", "TL02", "TL03")
PUBLISHED_LOD_IDS = ("SH01", "SH02", "BP01", "BP02")
CHARACTER_IDS = ("AL01", "CH01", "CH02")
ALL_IDS = CHARACTER_IDS + STATIC_IDS
RATIOS = ((1, 0.50), (2, 0.225))
HERE = Path(__file__).resolve().parent


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def arguments(argv=None):
    if argv is None:
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--jobs", type=Path, default=HERE / "jobs.json")
    p.add_argument("--mode", choices=("all", "lods", "previews"), default="all")
    p.add_argument("--ids", nargs="+", choices=ALL_IDS, help="Subset; character LODs are always skipped")
    p.add_argument("--size", type=int, choices=(512, 640, 768), default=640)
    p.add_argument("--lod-previews", action="store_true", help="Also render exported LOD1/2 in the base camera framing")
    p.add_argument("--experimental-candidates", action="store_true", help="Unreviewed 7-static/two-level outputs go to lod_candidates/, not published lods/")
    p.add_argument("--overwrite", action="store_true", help="Replace derived outputs only; never source GLBs")
    p.add_argument("--dry-run", action="store_true", help="Validate manifest paths without Blender or writing outputs")
    return p.parse_args(argv)


def preflight(args):
    root = args.jobs.resolve().parent
    rows = json.loads(args.jobs.read_text(encoding="utf-8-sig"))["jobs"]
    by_id = {row["id"]: row for row in rows}
    ids = args.ids or (STATIC_IDS if args.mode == "lods" else ALL_IDS)
    selected = []
    for asset_id in ids:
        row = by_id.get(asset_id)
        if row is None:
            raise ValueError(f"Missing job {asset_id}")
        if not row.get("local_file"):
            raise FileNotFoundError(f"{asset_id}: jobs.json local_file is not ready")
        source = (root / row["local_file"]).resolve()
        if source.suffix.lower() != ".glb" or not source.is_file():
            raise FileNotFoundError(f"{asset_id}: expected downloaded GLB: {source}")
        if asset_id in STATIC_IDS and row.get("category") not in {"ships", "backpacks", "tools"}:
            raise ValueError(f"{asset_id}: category does not permit static LOD generation")
        outputs = []
        if args.mode in {"all", "previews"}:
            outputs.append(root / "previews" / f"{asset_id}.png")
            if asset_id in {"CH01", "CH02"}:
                outputs.append(root / "previews" / f"{asset_id}-rear.png")
        eligible = STATIC_IDS if args.experimental_candidates else PUBLISHED_LOD_IDS
        if args.mode in {"all", "lods"} and asset_id in eligible:
            folder = "lod_candidates" if args.experimental_candidates else "lods"
            for lod, _ in (RATIOS if args.experimental_candidates else RATIOS[:1]):
                outputs.append(root / folder / f"{asset_id}_LOD{lod}.glb")
                if args.lod_previews:
                    outputs.append(root / folder / "previews" / f"{asset_id}_LOD{lod}.png")
        for path in outputs:
            if path.resolve() == source:
                raise ValueError("Refusing to overwrite a base GLB")
            if path.exists() and not args.overwrite:
                raise FileExistsError(f"Derived output exists; use --overwrite if intended: {path}")
        selected.append((row, source))
    return root, selected


def reset_import(path, merge_vertices=False):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0
    bpy.ops.import_scene.gltf(filepath=str(path), merge_vertices=merge_vertices, import_shading="NORMALS")
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise ValueError(f"No mesh objects in {path}")
    for o in list(bpy.context.scene.objects):
        if o.type in {"CAMERA", "LIGHT"}:
            bpy.data.objects.remove(o, do_unlink=True)
    return meshes


def world_bounds(meshes):
    points = [o.matrix_world @ Vector(corner) for o in meshes for corner in o.bound_box]
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    return {"min": lo, "max": hi, "size": [hi[i] - lo[i] for i in range(3)]}


def triangle_count(meshes, evaluated=False):
    total = 0
    dg = bpy.context.evaluated_depsgraph_get() if evaluated else None
    for obj in meshes:
        mesh = obj.evaluated_get(dg).data if evaluated else obj.data
        mesh.calc_loop_triangles()
        total += len(mesh.loop_triangles)
    return total


def image_inventory(meshes):
    images = {}
    for obj in meshes:
        for material in obj.data.materials:
            if material and material.use_nodes:
                for n in material.node_tree.nodes:
                    if n.type == "TEX_IMAGE" and n.image:
                        images[n.image.as_pointer()] = n.image
    result = []
    for image in images.values():
        # Decoded pixels test preservation independently of PNG/JPEG byte encoding.
        pixels = array("f", [0.0]) * len(image.pixels)
        image.pixels.foreach_get(pixels)
        result.append({"size": list(image.size), "channels": image.channels,
                       "colorspace": image.colorspace_settings.name,
                       "decoded_pixels_sha256": hashlib.sha256(pixels.tobytes()).hexdigest()})
    return sorted(result, key=lambda x: (x["size"], x["colorspace"], x["decoded_pixels_sha256"]))


def mesh_audit(meshes):
    result = {"triangles": triangle_count(meshes), "objects": len(meshes),
              "bounds": world_bounds(meshes), "materials": [], "per_object": [],
              "topology_note": "Counts use imported split vertices; UV/normal seams can appear as boundaries. No welding or repair performed.",
              "non_manifold_edges": 0, "boundary_edges": 0, "zero_area_faces": 0,
              "loose_vertices": 0, "loose_edges": 0, "nonfinite_coordinates": 0,
              "nonfinite_uv_values": 0}
    materials = set()
    for obj in meshes:
        mesh = obj.data
        bm = bmesh.new()
        try:
            bm.from_mesh(mesh)
            item = {"name": obj.name, "triangles": triangle_count([obj]),
                    "vertices": len(mesh.vertices), "uv_layers": len(mesh.uv_layers),
                    "material_slots": len(mesh.materials),
                    "scale": list(obj.scale), "location": list(obj.location),
                    "non_manifold_edges": sum(not e.is_manifold for e in bm.edges),
                    "boundary_edges": sum(e.is_boundary for e in bm.edges),
                    "zero_area_faces": sum(f.calc_area() <= 1e-14 for f in bm.faces),
                    "loose_vertices": sum(not v.link_edges for v in bm.verts),
                    "loose_edges": sum(not e.link_faces for e in bm.edges),
                    "nonfinite_coordinates": sum(not all(math.isfinite(c) for c in v.co) for v in bm.verts),
                    "nonfinite_uv_values": sum(not math.isfinite(v) for uv in mesh.uv_layers for d in uv.data for v in d.uv)}
        finally:
            bm.free()
        for key in ("non_manifold_edges", "boundary_edges", "zero_area_faces", "loose_vertices",
                    "loose_edges", "nonfinite_coordinates", "nonfinite_uv_values"):
            result[key] += item[key]
        materials.update(m.name for m in mesh.materials if m)
        result["per_object"].append(item)
    result["materials"] = sorted(materials)
    result["material_count"] = len(materials)
    result["textures"] = image_inventory(meshes)
    return result


def prepare_static(meshes, asset_id, lod):
    if any(o.type == "ARMATURE" for o in bpy.context.scene.objects):
        raise ValueError(f"{asset_id}: refusing armature scene")
    if any(o.data.shape_keys or o.find_armature() or o.animation_data for o in meshes):
        raise ValueError(f"{asset_id}: refusing deforming/animated mesh")
    col = bpy.data.collections.new(f"COL_LODs_{asset_id}")
    bpy.context.scene.collection.children.link(col)
    for index, obj in enumerate(meshes, 1):
        world = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = world
        obj.data = obj.data.copy()  # Avoid applying an instance transform twice.
        for old_col in list(obj.users_collection):
            old_col.objects.unlink(obj)
        col.objects.link(obj)
        obj.name = f"SM_{asset_id}_{index:02d}_LOD{lod}"
        obj.data.name = obj.name
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    # Source material values and image data stay intact; only local names change.
    mats = list(dict.fromkeys(m for o in meshes for m in o.data.materials if m))
    for index, material in enumerate(mats, 1):
        material.name = f"MAT_{asset_id}_{index:02d}"


def reduce_meshes(meshes, target):
    """Conservative planar cleanup then one ratio-controlled collapse pass.

    Planar delimiters respect normals/material/UV seams; collapse subsequently
    interpolates UVs but cannot guarantee the original texture distortion level.
    """
    for obj in meshes:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        planar = obj.modifiers.new("LOD_Planar", "DECIMATE")
        planar.decimate_type = "DISSOLVE"
        planar.angle_limit = math.radians(0.5)
        planar.delimit = {"NORMAL", "MATERIAL", "SEAM", "SHARP", "UV"}
        planar.use_dissolve_boundaries = False
        # Do not let an aggressive planar pass overshoot the requested budget.
        if triangle_count(meshes, evaluated=True) >= target:
            bpy.ops.object.modifier_apply(modifier=planar.name)
        else:
            obj.modifiers.remove(planar)
    current = triangle_count(meshes)
    if current <= target:
        return {"method": "planar_only", "triangles_after_planar": current}
    modifiers = []
    protected = []
    ratio = max(0.001, min(1.0, target / current))
    for obj in meshes:
        # UV/hard-normal splits form separate boundaries in imported glTF. If
        # their vertices move independently, Collapse opens visible cracks.
        # Zero vertex-group weights lock those endpoints (Blender's decimator
        # explicitly excludes an edge with either endpoint weight zero).
        bm = bmesh.new()
        try:
            bm.from_mesh(obj.data)
            bm.verts.ensure_lookup_table()
            bm.verts.index_update()
            locked = set()
            uv_layers = list(bm.loops.layers.uv.values())
            for edge in bm.edges:
                lock = not edge.is_manifold or not edge.smooth
                if edge.is_manifold:
                    loops = list(edge.link_loops)
                    lock |= loops[0].face.material_index != loops[1].face.material_index
                    for uv in uv_layers:
                        for vert in edge.verts:
                            a = loops[0] if loops[0].vert == vert else loops[0].link_loop_next
                            b = loops[1] if loops[1].vert == vert else loops[1].link_loop_next
                            if (a[uv].uv - b[uv].uv).length > 1e-6:
                                lock = True
                if lock:
                    locked.update(v.index for v in edge.verts)
        finally:
            bm.free()
        group = obj.vertex_groups.new(name="VG_LOD_Reducible")
        if len(obj.data.vertices):
            group.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
        if locked:
            group.add(sorted(locked), 0.0, "REPLACE")
        protected.append({"object": obj.name, "locked_vertices": len(locked),
                          "vertices": len(obj.data.vertices)})
        mod = obj.modifiers.new("LOD_Collapse", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.use_collapse_triangulate = True
        mod.ratio = ratio
        mod.vertex_group = group.name
        mod.vertex_group_factor = 1.0
        modifiers.append((obj, mod))
    # Multi-object rounding/tiny components can move the aggregate away from target.
    for _ in range(3):
        actual = triangle_count(meshes, evaluated=True)
        if actual <= 0 or abs(actual - target) <= max(8, target * 0.025):
            break
        ratio = max(0.001, min(1.0, ratio * target / actual))
        for _, mod in modifiers:
            mod.ratio = ratio
    for obj, mod in modifiers:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return {"method": "planar_then_collapse_with_locked_boundary_uv_material_seams",
            "triangles_after_planar": current, "protected_vertices": protected,
            "note": "Budget may remain above target when further reduction would move protected seam/boundary vertices"}


def export_glb(meshes, path):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True,
        export_yup=True, export_apply=False, export_animations=False, export_skins=False,
        export_morph=False, export_cameras=False, export_lights=False,
        export_texcoords=True, export_normals=True, export_tangents=True,
        # Keep Originals requires external image paths and drops packed GLB
        # textures. AUTO's normal encoder reuses packed PNG/JPEG bytes when
        # channels already match glTF, and our hash checks verify that result.
        export_materials="EXPORT", export_image_format="AUTO", export_keep_originals=False,
        export_image_quality=100, export_extras=False)


def validate_derived_mesh(meshes):
    """Make exporter validation explicit on derived static meshes only.

    Blender's glTF exporter itself calls Mesh.validate(). Run until stable here
    so discarded invalid elements are counted instead of hidden by export and
    reimport. Original GLBs/characters are never validated destructively.
    """
    before = triangle_count(meshes)
    changed = False
    for obj in meshes:
        for _ in range(4):
            repaired = obj.data.validate(verbose=False, clean_customdata=False)
            obj.data.update()
            changed |= repaired
            if not repaired:
                break
        else:
            raise ValueError("Derived mesh validation did not stabilize")
    after = triangle_count(meshes)
    if before - after > max(12, before * 0.005):
        raise ValueError(f"Derived mesh validation removed too much geometry: {before} -> {after}")
    return {"changed": changed, "triangles_before": before, "triangles_after": after,
            "removed_triangles": before - after,
            "scope": "Only invalid elements in the derived static LOD; no source/character repair"}


def material_role_signature(auditor):
    """Canonical glTF PBR factors, alpha and role-to-image/sampler bindings."""
    doc = auditor.doc
    def image_hash(index):
        image = doc["images"][index]
        if "bufferView" in image:
            view = auditor.views[image["bufferView"]]
            payload = view["data"][view["offset"]:view["offset"] + view["length"]]
        else:
            payload = auditor.uri_bytes(image["uri"], "material-role-image")
        return hashlib.sha256(payload).hexdigest()
    def texture(info, extra=None):
        if not info:
            return None
        tex = doc["textures"][info["index"]]
        sampler = doc.get("samplers", [])[tex["sampler"]] if "sampler" in tex else {}
        result = {"image_sha256": image_hash(tex["source"]), "texCoord": info.get("texCoord", 0),
                  "sampler": {"magFilter": sampler.get("magFilter", 9729),
                              "minFilter": sampler.get("minFilter", 9987),
                              "wrapS": sampler.get("wrapS", 10497), "wrapT": sampler.get("wrapT", 10497)},
                  "extensions": info.get("extensions", {})}
        if extra:
            result[extra] = info.get(extra, 1.0)
        return result
    result = []
    for m in doc.get("materials", []):
        pbr = m.get("pbrMetallicRoughness", {})
        result.append({"baseColorFactor": pbr.get("baseColorFactor", [1, 1, 1, 1]),
                       "metallicFactor": pbr.get("metallicFactor", 1.0),
                       "roughnessFactor": pbr.get("roughnessFactor", 1.0),
                       "baseColorTexture": texture(pbr.get("baseColorTexture")),
                       "metallicRoughnessTexture": texture(pbr.get("metallicRoughnessTexture")),
                       "normalTexture": texture(m.get("normalTexture"), "scale"),
                       "occlusionTexture": texture(m.get("occlusionTexture"), "strength"),
                       "emissiveTexture": texture(m.get("emissiveTexture")),
                       "emissiveFactor": m.get("emissiveFactor", [0, 0, 0]),
                       "alphaMode": m.get("alphaMode", "OPAQUE"),
                       "alphaCutoff": m.get("alphaCutoff", 0.5),
                       "doubleSided": m.get("doubleSided", False), "extensions": m.get("extensions", {})})
    return sorted(result, key=lambda x: json.dumps(x, sort_keys=True))


def framing(bounds):
    lo, hi = bounds["min"], bounds["max"]
    center = Vector([(lo[i] + hi[i]) / 2 for i in range(3)])
    extent = max(bounds["size"])
    if extent <= 0:
        raise ValueError("Zero-size bounds cannot be framed")
    return center, extent


def render_preview(path, bounds, size, rear=False):
    scene = bpy.context.scene
    # Rear/LOD renders must not accumulate cameras or lights from a prior view.
    for obj in list(scene.objects):
        if obj.type in {"CAMERA", "LIGHT"}:
            bpy.data.objects.remove(obj, do_unlink=True)
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT", "CYCLES"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if scene.render.engine == "CYCLES":
        scene.cycles.samples = 24
        scene.cycles.use_denoising = True
    center, extent = framing(bounds)
    world = bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.20, 0.22, 0.25, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.5
    scene.world = world
    cam_data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", cam_data)
    scene.collection.objects.link(camera)
    direction = Vector((-1.6, 2.6, 1.5) if rear else (1.6, -2.6, 1.5)).normalized()
    camera.location = center + direction * extent * 3
    camera.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    cam_data.type = "ORTHO"
    inv_rot = camera.rotation_euler.to_quaternion().inverted()
    corners = [inv_rot @ (Vector((x, y, z)) - center)
               for x in (bounds["min"][0], bounds["max"][0])
               for y in (bounds["min"][1], bounds["max"][1])
               for z in (bounds["min"][2], bounds["max"][2])]
    cam_data.ortho_scale = max(max(v[i] for v in corners) - min(v[i] for v in corners) for i in (0, 1)) * 1.18
    cam_data.clip_start, cam_data.clip_end = max(0.0001, extent / 1000), extent * 20
    scene.camera = camera
    for name, offset, energy, area in (
        ("Key", (-2.5, -3.5, 4.0), 1050, 3.0),
        ("Fill", (3.5, -1.0, 2.0), 650, 3.5),
        ("Rim", (0.5, 3.0, 3.5), 1200, 2.5),
    ):
        data = bpy.data.lights.new("Preview" + name, "AREA")
        obj = bpy.data.objects.new("Preview" + name, data)
        scene.collection.objects.link(obj)
        obj.location = center + Vector(offset) * extent
        obj.rotation_euler = (center - obj.location).to_track_quat("-Z", "Y").to_euler()
        data.energy, data.size = energy * extent * extent, area * extent
    scene.render.resolution_x = scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.filepath = str(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)
    return {"path": str(path), "engine": scene.render.engine, "resolution": [size, size],
            "view": "orthographic rear three-quarter; source orientation retained" if rear else "orthographic front three-quarter; source orientation retained",
            "source": "actual imported GLB render, not the concept image"}


def compare_lod(base, output, exported, target_ratio):
    errors, warnings = [], []
    n0, n1 = base["triangles"], output["triangles"]
    actual = exported.get("scene", {}).get("triangles")
    ratio = actual / n0 if n0 and actual is not None else None
    if not audit_acceptable(exported):
        errors.append("Exported GLB structural audit is not clean; see exported_glb")
    if actual != n1:
        delta = actual - n1 if actual is not None else None
        if delta is not None and 0 < delta <= max(8, n0 * 0.001):
            warnings.append(f"Reimport normalized {delta} degenerate elements; actual GLB budget remains {actual}, usable imported triangles {n1}")
        else:
            errors.append(f"Exported scene triangles {actual} != reimported triangles {n1}")
    if ratio is None or not 0 < ratio < 1:
        errors.append("LOD did not reduce actual triangles")
    elif abs(ratio - target_ratio) > 0.05:
        warnings.append(f"Actual ratio {ratio:.4f} differs from target {target_ratio:.4f}")
    max_extent = max(base["bounds"]["size"])
    bounds_error = max(abs(base["bounds"][key][i] - output["bounds"][key][i])
                       for key in ("min", "max") for i in range(3)) / max(max_extent, 1e-12)
    if bounds_error > 0.005:
        warnings.append(f"Bounds changed by {bounds_error:.2%} of largest extent; inspect silhouette")
    if base["objects"] != output["objects"]:
        errors.append("Mesh object count changed")
    if base["material_count"] != output["material_count"]:
        errors.append("Material count changed")
    if sorted(x["uv_layers"] for x in base["per_object"]) != sorted(x["uv_layers"] for x in output["per_object"]):
        errors.append("UV layer count changed")
    if base["textures"] != output["textures"]:
        errors.append("Decoded texture pixels/resolution/colorspace changed")
    if base.get("material_role_signature") != exported.get("material_role_signature"):
        errors.append("glTF PBR/alpha/texture-role/sampler signature changed")
    if any(abs(v - 1) > 1e-5 for x in output["per_object"] for v in x["scale"]):
        errors.append("Reimported mesh has non-unit scale")
    if any(not x["name"].startswith("SM_") for x in output["per_object"]):
        errors.append("Reimported mesh naming is not SM_")
    for key in ("nonfinite_coordinates", "nonfinite_uv_values"):
        if output[key]:
            errors.append(key)
    for key in ("non_manifold_edges", "zero_area_faces", "loose_vertices", "loose_edges"):
        if output[key] > base[key]:
            warnings.append(f"{key} increased: {base[key]} -> {output[key]}")
    return {"status": "failed" if errors else "structurally_checked_visual_review_required",
            "actual_exported_triangles": actual, "actual_ratio": ratio,
            "target_ratio": target_ratio, "bounds_max_error_fraction": bounds_error,
            "errors": errors, "warnings": warnings,
            "silhouette": "Review base/LOD previews at intended transition size; AABB is not a silhouette test"}


def audit_acceptable(report):
    # Blender's bundled Python may lack Pillow. Its image decoder and the pixel
    # inventory above perform that texture check instead; no mesh/accessor or
    # extension-related incomplete checks are waived.
    return (not report.get("errors") and
            all("Pillow unavailable; image dimensions not read" in note
                for note in report.get("incomplete_checks", [])))


def main(argv=None):
    args = arguments(argv)
    root, selected = preflight(args)
    if args.dry_run:
        print(json.dumps({"mode": args.mode, "ready": [r["id"] for r, _ in selected],
                          "static_lod_whitelist": STATIC_IDS, "characters_never_decimated": CHARACTER_IDS}, indent=2))
        return 0
    global bpy, bmesh, Vector
    try:
        import bpy
        import bmesh
        from mathutils import Vector
    except ImportError as e:
        raise RuntimeError("Run with Blender --background --factory-startup --python, or use --dry-run") from e
    sys.path.insert(0, str(HERE))
    from validate_models import GLBAudit
    outdir = root / ("lod_candidates" if args.experimental_candidates else "lods")
    outdir.mkdir(parents=True, exist_ok=True)
    report_path = root / ("lod_candidate_report.json" if args.experimental_candidates else "lod_report.json")
    report = {"created_utc": datetime.now(timezone.utc).isoformat(), "blender": bpy.app.version_string,
              "mode": args.mode, "source_manifest": str(args.jobs.resolve()), "assets": [],
              "static_lod_whitelist": STATIC_IDS, "characters_never_decimated": CHARACTER_IDS,
              "default_published_lod_ids": PUBLISHED_LOD_IDS,
              "limitations": ["No rigging, deformation, collision, physical scale or Godot integration certification",
                              "No UV rebake; collapse interpolates existing UVs and can change baked-normal shading",
                              "No automatic repair of original manifold/loose/zero-area geometry",
                              "Silhouette/shading and LOD screen-size transitions require visual/engine review"]}
    report["texture_verification"] = "Blender decoded pixels, dimensions and colorspace are compared after LOD GLB reimport; no resizing. Pillow-only GLBAudit header checks may be unavailable inside Blender."
    failed = False
    for row, source in selected:
        asset_id = row["id"]
        record = {"id": asset_id, "source": str(source), "source_sha256": sha256(source), "lods": []}
        report["assets"].append(record)
        try:
            print(f"[LOD] {asset_id}: import/audit", flush=True)
            source_auditor = GLBAudit(source)
            record["source_glb"] = source_auditor.run()
            meshes = reset_import(source)
            base = mesh_audit(meshes)
            record["base_mesh_qa"] = base
            if not audit_acceptable(record["source_glb"]):
                raise ValueError(f"{asset_id}: source GLB structural audit requires attention")
            if args.mode in {"all", "previews"}:
                record["preview"] = render_preview(root / "previews" / f"{asset_id}.png", base["bounds"], args.size)
                if asset_id in {"CH01", "CH02"}:
                    record["rear_preview"] = render_preview(root / "previews" / f"{asset_id}-rear.png", base["bounds"], args.size, rear=True)
            if asset_id in CHARACTER_IDS:
                record["lod_status"] = "skipped_character_requires_deformation_tests"
                continue
            if args.mode == "previews":
                continue
            if not args.experimental_candidates and asset_id not in PUBLISHED_LOD_IDS:
                record["lod_status"] = "base_only_tool_prior_visual_rejection_or_insufficient_saving"
                continue
            if source_auditor.doc.get("skins") or source_auditor.doc.get("animations"):
                raise ValueError(f"{asset_id}: source contains skins/animations; refusing static decimation")
            for lod, ratio in (RATIOS if args.experimental_candidates else RATIOS[:1]):
                # Each level starts from original LOD0, not the previous reduced mesh.
                # Blender's importer reconstructs shared mesh vertices where
                # possible while keeping loop UVs/normals. This is not a spatial
                # weld/repair pass; hard-normal discontinuities may stay split.
                meshes = reset_import(source, merge_vertices=True)
                prepare_static(meshes, asset_id, lod)
                prepared = mesh_audit(meshes)
                prepared["material_role_signature"] = material_role_signature(source_auditor)
                target = max(4, round(base["triangles"] * ratio))
                reduction = reduce_meshes(meshes, target)
                derived_validation = validate_derived_mesh(meshes)
                before_export = mesh_audit(meshes)
                if before_export["nonfinite_coordinates"] or before_export["nonfinite_uv_values"]:
                    raise ValueError("Nonfinite geometry/UVs before export")
                output = outdir / f"{asset_id}_LOD{lod}.glb"
                export_glb(meshes, output)
                exported_auditor = GLBAudit(output)
                exported = exported_auditor.run()
                exported["material_role_signature"] = material_role_signature(exported_auditor)
                meshes = reset_import(output, merge_vertices=True)
                after_import = mesh_audit(meshes)
                validation = compare_lod(prepared, after_import, exported, ratio)
                result = {"level": lod, "path": str(output), "target_triangles": target,
                          "sha256": sha256(output),
                          "valid": False, "visual_qa": {"status": "pending"},
                          "reduction": reduction,
                          "derived_mesh_validation": derived_validation,
                          "prepared_static_mesh_qa": prepared, "preexport_mesh_qa": before_export,
                          "import_policy": "merge_vertices=True via glTF importer; preserve loop UVs and source normals; no spatial weld or automatic repair",
                          "reimported_mesh_qa": after_import, "exported_glb": exported,
                          "validation": validation}
                record["lods"].append(result)
                if args.lod_previews:
                    result["preview"] = render_preview(outdir / "previews" / f"{asset_id}_LOD{lod}.png", base["bounds"], args.size)
                if validation["errors"]:
                    failed = True
                print(f"[LOD] {asset_id} LOD{lod}: {validation['actual_exported_triangles']} triangles, {validation['status']}", flush=True)
            if len(record["lods"]) == 2:
                counts = [x["validation"]["actual_exported_triangles"] for x in record["lods"]]
                if counts[1] >= counts[0]:
                    record["lods"][1]["visual_qa"] = {"status": "not_published_no_additional_reduction",
                        "reason": "Protected seams set a reduction floor; LOD2 provides no triangle saving over LOD1"}
                    record["lod_chain_note"] = "LOD2 is withheld rather than moving protected vertices or publishing a duplicate level"
        except Exception as exc:
            failed = True
            record["error"] = f"{type(exc).__name__}: {exc}"
            record["traceback"] = traceback.format_exc()
            print(f"[LOD] {asset_id} FAILED: {exc}", flush=True)
        finally:
            record["source_unchanged"] = record["source_sha256"] == sha256(source)
            if not record["source_unchanged"]:
                failed = True
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report["status"] = "failed_checks" if failed else "structurally_checked_visual_engine_review_required"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[LOD] Complete: {report_path}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
