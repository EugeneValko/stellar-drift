#!/usr/bin/env python3
"""Godot skeletal import/playback sampling in the isolated QA project only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
QA_PROJECT = Path(r"C:\Users\admin\.codex\visualizations\2026\11\03\01a1a23c-dd9b-7a11-8ed8-86d5a0707fd7\model-qa")
GDSCRIPT = r'''extends SceneTree

func _initialize() -> void:
	call_deferred("check_import")

func scan(node: Node, meshes: Array, skeletons: Array, players: Array) -> void:
	if node is MeshInstance3D: meshes.append(node)
	if node is Skeleton3D: skeletons.append(node)
	if node is AnimationPlayer: players.append(node)
	for child in node.get_children(): scan(child, meshes, skeletons, players)

func pose_sample(skeletons: Array) -> Dictionary:
	var result: Dictionary = {}
	for skeleton in skeletons:
		if skeleton.has_method("force_update_all_bone_transforms"):
			skeleton.call("force_update_all_bone_transforms")
		for name in ["root", "pelvis", "foot.L", "foot.R", "hand.R"]:
			var index: int = skeleton.find_bone(name)
			if index >= 0:
				var position: Vector3 = (skeleton.global_transform * skeleton.get_bone_global_pose(index)).origin
				result[name] = [position.x, position.y, position.z]
	return result

func check_import() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var path: String = args[0]
	var output: String = args[1]
	var report: Dictionary = {"file": path, "engine": Engine.get_version_info(),
		"qa_project": ProjectSettings.globalize_path("res://"), "errors": [],
		"status": "requires_correction",
		"bone_poses_reset_before_each_clip": true,
		"scope": "Headless GLTFDocument import, generated skeletal scene and sampled bone pose playback; no image/render/FPS/gameplay certification",
		"skeletal_scenes": [], "clips": [], "mesh_instances": 0, "materials": 0, "skin_bind_counts": []}
	var document: GLTFDocument = GLTFDocument.new()
	var state: GLTFState = GLTFState.new()
	var error: Error = document.append_from_file(path, state)
	report.append_error = int(error)
	report.append_error_name = error_string(error)
	var scene: Node = null
	if error == OK:
		scene = document.generate_scene(state)
	if scene == null:
		report.errors.append("Scene generation/import failed")
	else:
		root.add_child(scene)
		await process_frame
		var meshes: Array = []
		var skeletons: Array = []
		var players: Array = []
		scan(scene, meshes, skeletons, players)
		report.mesh_instances = meshes.size()
		var materials: Dictionary = {}
		for mesh in meshes:
			if mesh.skin != null: report.skin_bind_counts.append(mesh.skin.get_bind_count())
			if mesh.mesh != null:
				for surface in range(mesh.mesh.get_surface_count()):
					var material = mesh.get_active_material(surface)
					if material != null: materials[material.get_instance_id()] = true
		report.materials = materials.size()
		for skeleton in skeletons:
			var names: Array = []
			for index in range(skeleton.get_bone_count()): names.append(skeleton.get_bone_name(index))
			report.skeletal_scenes.append({"name": skeleton.name, "bones": names, "bone_count": names.size()})
		if skeletons.is_empty() or report.skin_bind_counts.is_empty():
			report.errors.append("No generated Skeleton3D/skinned MeshInstance3D")
		var found: Dictionary = {}
		for player in players:
			for clip_name in player.get_animation_list():
				if clip_name == "RESET": continue
				var animation: Animation = player.get_animation(clip_name)
				var clip: Dictionary = {"name": clip_name, "duration_s": animation.length,
					"tracks": animation.get_track_count(), "samples": []}
				# Godot can remove constant tracks. Test every clip from bind pose;
				# otherwise an earlier Demo root transform persists into Walk/Wave.
				player.stop(true)
				for skeleton in skeletons: skeleton.reset_bone_poses()
				player.play(clip_name)
				for time in [0.0, animation.length * 0.5, animation.length]:
					player.seek(time, true)
					player.advance(0.0)
					clip.samples.append({"time_s": time, "bone_positions_world": pose_sample(skeletons)})
				player.stop(true)
				report.clips.append(clip)
				found[str(clip_name)] = true
		for required in ["Walk_Cycle", "Wave", "Demo"]:
			if not found.has(required): report.errors.append("Required imported clip missing: " + required)
		scene.free()
		document = null
		state = null
	report.status = "imported_sampled_engine_review_complete" if report.errors.is_empty() else "requires_correction"
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write isolated import report")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.close()
	print("[SKELETAL QA] ", report.status, " clips=", report.clips.size(), " skeletons=", report.skeletal_scenes.size())
	quit(0 if report.errors.is_empty() else 1)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("glb", type=Path)
    parser.add_argument("--godot", default=r"C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe")
    args = parser.parse_args()
    source = args.glb.resolve()
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    QA_PROJECT.mkdir(parents=True, exist_ok=True)
    project = QA_PROJECT / "project.godot"
    if not project.exists():
        project.write_text('config_version=5\n[application]\nconfig/name="Isolated GLB QA"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
    script = QA_PROJECT / "qa_skeletal_import.gd"
    script.write_text(GDSCRIPT, encoding="utf-8")
    output = HERE / "qa_engine_import.json"
    # Remove only this generated report so a failed invocation cannot reuse an old pass.
    if output.exists():
        output.unlink()
    result = subprocess.run([args.godot, "--headless", "--path", str(QA_PROJECT), "--script",
                             "res://qa_skeletal_import.gd", "--", str(source), str(output)],
                            capture_output=True, text=True, timeout=120)
    if not output.exists():
        raise RuntimeError("Godot did not write a report: " + result.stdout + result.stderr)
    report = json.loads(output.read_text(encoding="utf-8"))
    report["source_sha256"] = before
    report["source_unchanged"] = before == hashlib.sha256(source.read_bytes()).hexdigest()
    report["godot_exit_code"] = result.returncode
    report["console"] = result.stdout + result.stderr
    report["runtime_note"] = ("Godot may omit constant rest-pose tracks. These samples reset all bone poses "
                              "before each clip; application animation transitions need their own reset/blending policy.")
    for clip in report.get("clips", []):
        poses = [sample.get("bone_positions_world", {}) for sample in clip.get("samples", [])]
        if len(poses) != 3 or any(not all(name in p for name in ("root", "pelvis", "foot.L", "foot.R", "hand.R")) for p in poses):
            report.setdefault("errors", []).append("Required bone samples missing: " + clip["name"])
            continue
        clip["root_delta_godot_m"] = [b - a for a, b in zip(poses[0]["root"], poses[-1]["root"])]
        if clip["name"] == "Demo" and abs(clip["root_delta_godot_m"][2] - 4.95) > .001:
            report.setdefault("errors", []).append("Demo engine root displacement differs from +4.95m Godot Z")
        if clip["name"] in ("Walk_Cycle", "Wave") and any(abs(v) > .001 for v in poses[0]["root"] + poses[-1]["root"]):
            report.setdefault("errors", []).append("Stationary clip root differs from rest origin: " + clip["name"])
    if result.returncode:
        report.setdefault("errors", []).append("Godot returned nonzero exit code")
    if report.get("errors") or not report["source_unchanged"]:
        report["status"] = "requires_correction"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (HERE / "qa_engine_import.txt").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report.get(k) for k in ("status", "append_error", "mesh_instances", "materials", "skin_bind_counts", "source_unchanged", "errors")}))
    print(json.dumps({"clips": [{"name": clip["name"], "duration_s": clip["duration_s"], "tracks": clip["tracks"]} for clip in report.get("clips", [])]}))
    return 1 if report.get("errors") or not report["source_unchanged"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
