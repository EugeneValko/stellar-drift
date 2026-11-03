#!/usr/bin/env python3
"""Read-only exported CH01 glTF skin/clip QA; no engine/conformance claim."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))
from validate_models import GLBAudit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("glb", type=Path)
    parser.add_argument("--expected-clips", nargs="+", default=["Walk_Cycle", "Wave"])
    args = parser.parse_args()
    before = hashlib.sha256(args.glb.read_bytes()).hexdigest()
    audit = GLBAudit(args.glb)
    structural = audit.run()
    errors, warnings = list(structural["errors"]), []
    if structural["incomplete_checks"]:
        errors.extend(structural["incomplete_checks"])
    doc = audit.doc
    nodes, skins, animations = doc.get("nodes", []), doc.get("skins", []), doc.get("animations", [])
    controls = [node.get("name", "") for node in nodes if node.get("name", "").startswith(("CTRL_", "MCH_"))]
    if controls:
        errors.append("Export includes control/mechanism nodes: " + ", ".join(controls))
    if not skins:
        errors.append("No exported glTF skin")
    names = [a.get("name", "") for a in animations]
    for name in args.expected_clips:
        if name not in names:
            errors.append("Required clip absent: " + name)
    mesh_skin_links = {n["mesh"]: n["skin"] for n in nodes if "mesh" in n and "skin" in n}
    primitives = []
    for mi, mesh in enumerate(doc.get("meshes", [])):
        skin = skins[mesh_skin_links[mi]] if mi in mesh_skin_links and mesh_skin_links[mi] < len(skins) else None
        for pi, primitive in enumerate(mesh.get("primitives", [])):
            attributes = primitive.get("attributes", {})
            result = {"mesh": mi, "primitive": pi, "vertices": 0, "max_influences": 0,
                      "unweighted": 0, "unnormalized": 0, "invalid_joint_indices": 0,
                      "invalid_weights": 0, "weight_sum_range": [1.0, 1.0]}
            primitives.append(result)
            if skin is None:
                errors.append(f"Mesh {mi} has no node-linked skin")
            if not all(name in attributes for name in ("POSITION", "JOINTS_0", "WEIGHTS_0")):
                errors.append(f"Mesh {mi} primitive {pi} lacks POSITION/JOINTS_0/WEIGHTS_0")
                continue
            accessors = [attributes["JOINTS_0"], attributes["WEIGHTS_0"]]
            if any(not audit.can_read(index) for index in accessors):
                errors.append(f"Mesh {mi} primitive {pi}: cannot decode skin accessors")
                continue
            joint_count = len(skin.get("joints", [])) if skin else 0
            low, high = math.inf, -math.inf
            if "WEIGHTS_1" in attributes or "JOINTS_1" in attributes:
                errors.append(f"Mesh {mi} primitive {pi}: extra influence set exists beyond four")
            joints_layout = audit.accessors[accessors[0]]
            weights_layout = audit.accessors[accessors[1]]
            if joints_layout["type"] != "VEC4" or weights_layout["type"] != "VEC4":
                errors.append(f"Mesh {mi} primitive {pi}: joint/weight accessors must be VEC4")
                continue
            for joints, weights in zip(audit.values(accessors[0]), audit.values(accessors[1], normalized=True)):
                result["vertices"] += 1
                active = [(joint, weight) for joint, weight in zip(joints, weights) if weight > 1e-7]
                result["max_influences"] = max(result["max_influences"], len(active))
                total = sum(weights)
                low, high = min(low, total), max(high, total)
                result["unweighted"] += not active
                result["unnormalized"] += abs(total - 1.0) > 1e-4
                result["invalid_joint_indices"] += any(not 0 <= joint < joint_count for joint, _ in active)
                result["invalid_weights"] += any(not math.isfinite(w) or not 0 <= w <= 1 for w in weights)
            result["weight_sum_range"] = [low, high]
            if any(result[key] for key in ("unweighted", "unnormalized", "invalid_joint_indices", "invalid_weights")):
                errors.append(f"Mesh {mi} primitive {pi}: invalid skin weights; see counters")
    clips = []
    for animation in animations:
        starts, ends = [], []
        for sampler in animation.get("samplers", []):
            index = sampler.get("input")
            if not isinstance(index, int) or not 0 <= index < len(audit.accessors) or not audit.can_read(index):
                errors.append("Animation input accessor unavailable")
                continue
            times = [value[0] for value in audit.values(index)]
            if times:
                starts.append(times[0]); ends.append(times[-1])
            if any(not math.isfinite(t) for t in times) or any(b <= a for a, b in zip(times, times[1:])):
                errors.append("Animation sampler times are nonfinite/non-increasing")
            output = sampler.get("output")
            if isinstance(output, int) and 0 <= output < len(audit.accessors) and audit.can_read(output):
                if any(not all(math.isfinite(x) for x in value) for value in audit.values(output)):
                    errors.append("Animation sampler output has nonfinite values")
        clips.append({"name": animation.get("name"), "channels": len(animation.get("channels", [])),
                      "samplers": len(animation.get("samplers", [])), "start_s": min(starts) if starts else None,
                      "end_s": max(ends) if ends else None,
                      "duration_s": max(ends) - min(starts) if starts and ends else None})
    report = {"file": str(args.glb.resolve()), "scope": "Selected local GLB skin/weight/clip checks; engine import and visual deformation are separate",
              "structural_status": structural["structural_status"], "skins": len(skins),
              "file_bytes": args.glb.stat().st_size, "source_sha256": before,
              "source_unchanged": before == hashlib.sha256(args.glb.read_bytes()).hexdigest(),
              "scene": structural.get("scene"), "materials": structural.get("materials"),
              "textures": structural.get("textures"),
              "skin_joint_counts": [len(s.get("joints", [])) for s in skins],
              "skin_joint_names": [[nodes[j].get("name") for j in s.get("joints", []) if 0 <= j < len(nodes)] for s in skins],
              "control_nodes": controls, "primitives": primitives, "clips": clips,
              "errors": errors, "warnings": warnings,
              "status": "requires_correction" if errors else "local_skin_clip_checks_completed"}
    (HERE / "qa_skeletal_glb.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (HERE / "qa_skeletal_glb.txt").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
