"""Independent read-only evaluated-mesh QA of CH01 rig/actions in Blender.

This does not author poses or save the blend. Stance phases are supplied by the
animator's contract; geometry/contacts are sampled from actual deformed mesh,
not inferred from IK controls. Run after the animation file is stable.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
FPS = 30.0
PERIOD = 1.1


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blend", type=Path, default=HERE / "animated.blend")
    parser.add_argument("--prefix", default="qa_motion")
    return parser.parse_args(argv)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def vector_mean(points):
    return sum(points, Vector()) / len(points) if points else Vector()


def foot_masks(mesh):
    rest = [mesh.matrix_world @ v.co for v in mesh.data.vertices]
    masks = {}
    for side, sign in (("L", 1), ("R", -1)):
        boot = [i for i, v in enumerate(rest) if sign * v.x > .045 and v.z < .20]
        floor = min(rest[i].z for i in boot)
        sole = [i for i in boot if rest[i].z <= floor + .025]
        masks[side] = {"boot": boot, "sole": sole,
                       "heel": [i for i in sole if rest[i].y > .065],
                       "ball": [i for i in sole if -.115 <= rest[i].y <= -.055],
                       "toe": [i for i in sole if rest[i].y < -.125]}
    return masks


def weight_qa(mesh, arm):
    deform = {b.name for b in arm.data.bones if b.use_deform}
    names = {g.index: g.name for g in mesh.vertex_groups}
    bad, unweighted, excessive, nonfinite = [], [], [], []
    min_sum, max_sum, max_count = math.inf, -math.inf, 0
    rigid_helmet_nonrigid = 0
    forbidden = set()
    for v in mesh.data.vertices:
        values = [(names.get(g.group, "UNKNOWN"), g.weight) for g in v.groups if g.weight > 1e-7]
        forbidden.update(n for n, w in values if n not in deform)
        weights = [w for n, w in values if n in deform]
        total, count = sum(weights), len(weights)
        min_sum, max_sum, max_count = min(min_sum, total), max(max_sum, total), max(max_count, count)
        if not count:
            unweighted.append(v.index)
        if count > 4:
            excessive.append(v.index)
        if abs(total - 1.0) > 1e-4:
            bad.append(v.index)
        if any(not math.isfinite(w) or w < 0 or w > 1 for w in weights):
            nonfinite.append(v.index)
        if (mesh.matrix_world @ v.co).z > 1.60 and (len(weights) != 1 or not any(n == "head" and w > .9999 for n, w in values)):
            rigid_helmet_nonrigid += 1
    return {"vertices": len(mesh.data.vertices), "max_deform_influences": max_count,
            "weight_sum_range": [min_sum, max_sum], "unweighted_count": len(unweighted),
            "more_than_four_count": len(excessive), "normalization_error_count": len(bad),
            "invalid_weight_count": len(nonfinite), "weighted_nondeform_groups": sorted(forbidden),
            "helmet_above_1_60m_nonrigid_vertices": rigid_helmet_nonrigid,
            "bad_vertex_examples": {"unweighted": unweighted[:12], "normalization": bad[:12], "over_four": excessive[:12]},
            "status": "checked" if not (unweighted or excessive or bad or nonfinite or forbidden) else "requires_correction"}


def classify(action_name, time, side):
    shift = 0.0 if side == "L" else .5
    if action_name == "Walk_Cycle":
        phase_total = time / PERIOD + shift
    elif action_name == "Demo" and 1.5 <= time <= 5.9:
        phase_total = .1 + (time - 1.5) / PERIOD + shift
    elif action_name == "Wave" or action_name == "Demo" and time >= 6.7:
        return {"phase": None, "flat": True, "stance": True, "segment": "standing"}
    else:
        return {"phase": None, "flat": False, "stance": None, "segment": None}
    phase = phase_total % 1.0
    return {"phase": phase, "flat": .09 - 1e-8 <= phase <= .40 + 1e-8,
            "stance": phase <= .60 + 1e-8, "segment": math.floor(phase_total)}


def sample_action(arm, mesh, action, masks):
    arm.animation_data.action = action
    if action.slots:
        arm.animation_data.action_slot = action.slots[0]
    start, end = (round(x) for x in action.frame_range)
    frame_samples, endpoints, bone_endpoints, flat = [], [], [], defaultdict(list)
    min_z, max_ik_error = math.inf, 0.0
    evaluated = bpy.context.evaluated_depsgraph_get()
    for frame in range(start, end + 1):
        time = (frame - start) / FPS
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        root_world = arm.matrix_world @ arm.pose.bones["root"].matrix
        root_inverse = root_world.inverted()
        root_position = root_world.translation.copy()
        record = {"frame": frame, "time": time, "root": list(root_position),
                  "pelvis": list(arm.matrix_world @ arm.pose.bones["pelvis"].head), "feet": {}}
        em = mesh.evaluated_get(evaluated)
        data = em.to_mesh()
        try:
            if len(data.vertices) != len(mesh.data.vertices):
                raise ValueError("Evaluated topology changed; vertex-index foot tracking is invalid")
            world = em.matrix_world
            for side in ("L", "R"):
                points = {name: [world @ data.vertices[i].co for i in indices] for name, indices in masks[side].items()}
                info = classify(action.name, time, side)
                info["boot_min_z"] = min(p.z for p in points["boot"])
                info["sole_min_z"] = min(p.z for p in points["sole"])
                info["sole_centroid"] = list(vector_mean(points["sole"]))
                info["patch_min_z"] = {name: min((p.z for p in points[name]), default=None) for name in ("heel", "ball", "toe")}
                min_z = min(min_z, info["boot_min_z"])
                ankle = arm.matrix_world @ arm.pose.bones["foot." + side].head
                control = arm.matrix_world @ arm.pose.bones["CTRL_foot." + side].head
                error = (ankle - control).length
                max_ik_error = max(max_ik_error, error)
                info["ankle"] = list(ankle)
                info["ik_ankle_error_m"] = error
                if info["flat"]:
                    centroid = vector_mean(points["sole"])
                    # In-place clip is judged in a virtual treadmill/world frame.
                    # Demo is always judged with its ACTUAL authored root motion.
                    if action.name == "Walk_Cycle":
                        centroid.y -= time
                    flat[(side, str(info["segment"]))].append((frame, centroid, info["sole_min_z"]))
                record["feet"][side] = info
            if frame in (start, end):
                endpoints.append([root_inverse @ (world @ vertex.co) for vertex in data.vertices])
                bone_endpoints.append({bone.name: root_inverse @ (arm.matrix_world @ bone.matrix)
                                       for bone in arm.pose.bones if bone.bone.use_deform})
        finally:
            em.to_mesh_clear()
        frame_samples.append(record)
    segments = []
    for (side, segment), entries in flat.items():
        if len(entries) < 2:
            continue
        positions = [p for _, p, _ in entries]
        horizontal_range = math.sqrt((max(p.x for p in positions) - min(p.x for p in positions)) ** 2 +
                                     (max(p.y for p in positions) - min(p.y for p in positions)) ** 2)
        max_speed = max((Vector((entries[i][1].x - entries[i-1][1].x,
                                 entries[i][1].y - entries[i-1][1].y, 0)).length /
                         ((entries[i][0] - entries[i-1][0]) / FPS)) for i in range(1, len(entries)))
        segments.append({"side": side, "segment": segment, "first_frame": entries[0][0], "last_frame": entries[-1][0],
                         "horizontal_centroid_range_m": horizontal_range, "max_horizontal_speed_m_s": max_speed,
                         "sole_min_z_range_m": [min(z for _, _, z in entries), max(z for _, _, z in entries)]})
    first, last = frame_samples[0], frame_samples[-1]
    root_delta = [last["root"][i] - first["root"][i] for i in range(3)]
    backwards = [(frame_samples[i]["frame"], frame_samples[i]["root"][1] - frame_samples[i-1]["root"][1])
                 for i in range(1, len(frame_samples)) if frame_samples[i]["root"][1] - frame_samples[i-1]["root"][1] > .00001]
    loop = None
    if action.name == "Walk_Cycle":
        loop = {"root_relative_mesh_endpoint_max_difference_m": max((a-b).length for a, b in zip(endpoints[0], endpoints[-1])),
                "root_relative_bone_endpoint_position_max_difference_m": max((bone_endpoints[0][n].translation - bone_endpoints[-1][n].translation).length for n in bone_endpoints[0]),
                "root_relative_bone_endpoint_rotation_max_difference_rad": max(bone_endpoints[0][n].to_quaternion().rotation_difference(bone_endpoints[-1][n].to_quaternion()).angle for n in bone_endpoints[0])}
    flat_z = [z for entries in flat.values() for _, _, z in entries]
    return {"action": action.name, "frame_range": [start, end], "duration_s": (end-start)/FPS,
            "sampled_frames": len(frame_samples), "minimum_deformed_boot_z_m": min_z,
            "max_penetration_below_ground_m": max(0, -min_z), "max_ik_ankle_error_m": max_ik_error,
            "max_flat_stance_horizontal_drift_m": max((s["horizontal_centroid_range_m"] for s in segments), default=None),
            "flat_stance_minimum_sole_z_range_m": [min(flat_z), max(flat_z)] if flat_z else None,
            "flat_stance_segments": segments, "root_displacement_m": root_delta,
            "root_reverse_forward_motion_frames": backwards, "walk_loop": loop,
            "sliding_coordinate_frame": "Actual mesh world coordinates minus virtual root Y=1m/s for in-place Walk_Cycle ONLY" if action.name == "Walk_Cycle" else "Actual deformed mesh world coordinates, no correction",
            "frame_samples": frame_samples}


def main():
    args = parse_args()
    source = args.blend.resolve()
    before = sha(source)
    bpy.ops.wm.open_mainfile(filepath=str(source))
    arm, mesh = bpy.data.objects["ARM_CH01"], bpy.data.objects["SM_CH01"]
    if arm.animation_data is None:
        raise ValueError("Armature has no animation_data")
    for track in arm.animation_data.nla_tracks:
        track.mute = True
    masks = foot_masks(mesh)
    report = {"blend": str(source), "source_sha256": before, "blender": bpy.app.version_string,
              "scope": "Read-only rig weight inspection and frame-by-frame evaluated deformed-mesh boot contact/stance/loop checks; no poses authored or blend saved",
              "thresholds": {"penetration_major_m": .010, "flat_sliding_major_m": .015,
                             "floating_flat_sole_major_m": .012, "loop_endpoint_major_m": .001},
              "stance_contract": {"Walk_Cycle": "period1.1s, Lphase0/Rphase+.5; flat phase.09..40; virtual forward speed1m/s",
                                  "Demo": "steady1.5..5.9s phase.1+(t-1.5)/1.1; flatboth>=6.7s; actual root",
                                  "Wave": "both feet flat entire action"},
              "foot_mask_vertex_counts": {s: {k: len(v) for k, v in items.items()} for s, items in masks.items()},
              "weights": weight_qa(mesh, arm), "actions": [], "issues": [],
              "not_assessed": ["wave palm appearance", "natural artistic timing", "joint silhouette/cloth compression", "exported skin/clip equivalence", "Godot skeletal import"]}
    for name in ("Walk_Cycle", "Wave", "Demo"):
        action = bpy.data.actions.get(name)
        if action is None:
            report["issues"].append({"severity": "major", "message": "Missing action " + name})
            continue
        result = sample_action(arm, mesh, action, masks)
        report["actions"].append(result)
        print("QA " + name + " " + json.dumps({k:v for k,v in result.items() if k not in ("frame_samples", "flat_stance_segments")}))
        if result["max_penetration_below_ground_m"] > .010:
            report["issues"].append({"severity": "major", "action": name, "message": "Actual deformed boot penetrates ground >10mm", "value_m": result["max_penetration_below_ground_m"]})
        if result["max_flat_stance_horizontal_drift_m"] is not None and result["max_flat_stance_horizontal_drift_m"] > .015:
            report["issues"].append({"severity": "major", "action": name, "message": "Flat-stance deformed sole centroid drifts >15mm", "value_m": result["max_flat_stance_horizontal_drift_m"]})
        if result["flat_stance_minimum_sole_z_range_m"] and result["flat_stance_minimum_sole_z_range_m"][1] > .012:
            report["issues"].append({"severity": "major", "action": name, "message": "Flat-stance sole floats >12mm", "value_m": result["flat_stance_minimum_sole_z_range_m"][1]})
        if result["walk_loop"] and result["walk_loop"]["root_relative_mesh_endpoint_max_difference_m"] > .001:
            report["issues"].append({"severity": "major", "action": name, "message": "Loop root-relative mesh endpoints differ >1mm"})
    report["source_unchanged"] = before == sha(source)
    report["verdict"] = "requires_correction_or_visual_review" if report["issues"] or report["weights"]["status"] != "checked" else "numeric_checks_completed_visual_review_required"
    (HERE / (args.prefix + ".json")).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["CH01 INDEPENDENT RIG / MOTION QA", "Blend: " + str(source),
             "Source SHA unchanged: " + str(report["source_unchanged"]),
             "Weights: " + json.dumps(report["weights"]), "Verdict: " + report["verdict"], ""]
    for action in report["actions"]:
        lines.append(json.dumps({k:v for k,v in action.items() if k not in ("frame_samples", "flat_stance_segments")}, indent=2))
    lines.extend("ISSUE " + json.dumps(issue) for issue in report["issues"])
    lines.append("Not assessed: " + "; ".join(report["not_assessed"]))
    (HERE / (args.prefix + ".txt")).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(HERE / (args.prefix + '.json')), "weights": report["weights"], "issues": report["issues"], "source_unchanged": report["source_unchanged"]}))


if __name__ == "__main__":
    main()
