"""Read-only CH01 geometry measurements; run in background Blender.

Only reports are written. Landmark samples are measured surface sections,
not confirmed anatomical joints. No asset, source GLB or rig is saved/changed.
"""
import hashlib
import json
import math
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "downloads" / "CH01.glb"
TARGET_HEIGHT = 1.82


def bbox(points):
    if not points:
        return None
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    return {"min": lo, "max": hi, "size": [hi[i] - lo[i] for i in range(3)],
            "mid": [(hi[i] + lo[i]) / 2 for i in range(3)], "samples": len(points)}


def components(bm):
    bm.verts.ensure_lookup_table()
    seen, result = set(), []
    for vert in bm.verts:
        if vert.index in seen:
            continue
        stack, group = [vert], []
        seen.add(vert.index)
        while stack:
            current = stack.pop()
            group.append(current)
            for edge in current.link_edges:
                other = edge.other_vert(current)
                if other.index not in seen:
                    seen.add(other.index)
                    stack.append(other)
        result.append({"vertices": len(group), "bounds": bbox([v.co for v in group])})
    return sorted(result, key=lambda x: x["vertices"], reverse=True)


def topology(bm):
    groups = components(bm)
    return {"vertices": len(bm.verts), "edges": len(bm.edges), "faces": len(bm.faces),
            "connected_components": len(groups), "largest_components": groups[:20],
            "components_under_8_vertices": sum(c["vertices"] < 8 for c in groups),
            "non_manifold_edges": sum(not e.is_manifold for e in bm.edges),
            "boundary_edges": sum(e.is_boundary for e in bm.edges),
            "zero_area_faces_1e_12_m2": sum(f.calc_area() <= 1e-12 for f in bm.faces),
            "loose_vertices": sum(not v.link_edges for v in bm.verts),
            "loose_edges": sum(not e.link_faces for e in bm.edges)}


original_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(SOURCE), merge_vertices=True, import_shading="NORMALS")
meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
world = [obj.matrix_world @ vertex.co for obj in meshes for vertex in obj.data.vertices]
raw = bbox(world)
factor = TARGET_HEIGHT / raw["size"][2]
x_center = (raw["min"][0] + raw["max"][0]) / 2
floor = raw["min"][2]
points = [Vector(((v.x - x_center) * factor, v.y * factor, (v.z - floor) * factor)) for v in world]
report = {
    "source": str(SOURCE), "source_sha256": original_hash, "blender": bpy.app.version_string,
    "coordinate_convention": "Blender Z up, X left/right; front -Y supplied by project, not independently identified by this geometry-only probe",
    "target_height_m": TARGET_HEIGHT, "raw_world_bounds": raw, "scale_factor": factor,
    "normalization": {"x_center_subtracted": x_center, "floor_z_subtracted": floor, "y_offset": 0},
    "scaled_bounds": bbox(points), "meshes": len(meshes),
    "triangle_count": sum(len(obj.data.loop_triangles) for obj in meshes),
    "landmarks_scope": "Surface cross-section bounds/midpoints only; internal joint centres require rigging judgment and deformation tests.",
    "height_slices": [], "left_arm_x_slices": [], "right_arm_x_slices": [],
    "left_leg_z_slices": [], "right_leg_z_slices": [],
}
for obj in meshes:
    obj.data.calc_loop_triangles()
report["triangle_count"] = sum(len(obj.data.loop_triangles) for obj in meshes)
for z in [0.02, 0.06, 0.10, 0.14, 0.18, 0.22, 0.30, 0.40, 0.50, 0.60,
          0.70, 0.80, 0.90, 1.00, 1.10, 1.20, 1.30, 1.35, 1.40, 1.45,
          1.50, 1.55, 1.60, 1.65, 1.70, 1.75, 1.80]:
    section = [p for p in points if abs(p.z - z) <= 0.02]
    report["height_slices"].append({"z": z, "bounds": bbox(section)})
for sign, name in [(1, "left"), (-1, "right")]:
    for x in [0.14, 0.18, 0.22, 0.26, 0.30, 0.34, 0.38, 0.42, 0.46,
              0.50, 0.54, 0.58, 0.62, 0.66, 0.70, 0.74, 0.78, 0.82, 0.86, 0.90]:
        section = [p for p in points if abs(p.x - sign * x) <= 0.015 and p.z > 1.12]
        report[f"{name}_arm_x_slices"].append({"x": sign * x, "bounds": bbox(section)})
    for z in [0.02, 0.06, 0.10, 0.14, 0.18, 0.22, 0.30, 0.40, 0.50,
              0.60, 0.70, 0.80, 0.90, 1.00, 1.10]:
        section = [p for p in points if abs(p.z - z) <= 0.02 and 0.04 < sign * p.x < 0.38]
        report[f"{name}_leg_z_slices"].append({"z": z, "bounds": bbox(section)})
    report[f"{name}_boot_lower_18cm"] = bbox([p for p in points if p.z < 0.18 and sign * p.x > 0.04])

bm = bmesh.new()
offset = 0
for obj in meshes:
    mesh = obj.data
    local_map = [bm.verts.new(points[offset + i]) for i in range(len(mesh.vertices))]
    for poly in mesh.polygons:
        try:
            bm.faces.new([local_map[i] for i in poly.vertices])
        except ValueError:
            pass
    offset += len(mesh.vertices)
bm.verts.index_update()
report["imported_topology"] = topology(bm)
copy = bm.copy()
try:
    bmesh.ops.remove_doubles(copy, verts=list(copy.verts), dist=0.000001)
    copy.verts.index_update()
    report["diagnostic_coincident_merge_1micron"] = topology(copy)
    report["diagnostic_note"] = "Coincident merge occurs only on an in-memory diagnostic bmesh copy; never written to the source or rig. It approximates topology behind glTF normal/UV split vertices, not an asset repair."
finally:
    copy.free()
    bm.free()
report["source_unchanged"] = original_hash == hashlib.sha256(SOURCE.read_bytes()).hexdigest()
(HERE / "qa_mesh_probe.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
lines = ["CH01 READ-ONLY MESH PROBE", f"Height: {TARGET_HEIGHT} m; scale: {factor}",
         "Scaled XYZ bounds: " + str(report["scaled_bounds"]),
         "Imported topology: " + str({k: v for k, v in report["imported_topology"].items() if k != "largest_components"}),
         "Diagnostic merged-copy topology: " + str({k: v for k, v in report["diagnostic_coincident_merge_1micron"].items() if k != "largest_components"}),
         report["landmarks_scope"], report["diagnostic_note"],
         "Source unchanged: " + str(report["source_unchanged"])]
(HERE / "qa_mesh_probe.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps({"scale": factor, "bounds": report["scaled_bounds"],
                  "topology": {k: v for k, v in report["imported_topology"].items() if k != "largest_components"},
                  "diagnostic_topology": {k: v for k, v in report["diagnostic_coincident_merge_1micron"].items() if k != "largest_components"},
                  "source_unchanged": report["source_unchanged"]}))
