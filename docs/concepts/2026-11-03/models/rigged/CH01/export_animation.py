#!/usr/bin/env python3
"""Bake evaluated CH01 rig motion to a clean 23-joint/three-clip GLB.

Run only after the final motion QA is approved:
  blender --background --factory-startup --python-exit-code 1 \
      --python export_animation.py -- --input animated.blend

The input .blend, rig.blend and downloaded CH01.glb are read-only. No .blend
is saved. The export copy contains root + 22 deform bones, no IK/MCH controls
or constraints. Evaluated visual matrices are sampled with explicit source
action slots, converted to local quaternion keys at 30fps, and verified
against the source skeleton and selected full-mesh deformation samples.
Three explicit action-slot/NLA associations are exported and the actual GLB
animation/skin/weight/PBR content is checked before publishing the final file.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import traceback

import bpy
from mathutils import Matrix

HERE = Path(__file__).resolve().parent
MODELS = HERE.parent.parent
SOURCE_GLB = MODELS / "downloads" / "CH01.glb"
CLIPS = ("Walk_Cycle", "Wave", "Demo")
FPS = 30

sys.path.insert(0, str(MODELS))
from validate_models import GLBAudit
from generate_lods import material_role_signature


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def arguments():
    argv = sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", type=Path, default=HERE / "animated.blend")
    p.add_argument("--output", type=Path, default=HERE / "CH01_rigged_animated.glb")
    p.add_argument("--overwrite", action="store_true", help="Replace the derived final GLB only")
    return p.parse_args(argv)


def action_slot(action, arm):
    slots = [s for s in action.slots if s.target_id_type == "OBJECT"]
    if not slots:
        raise RuntimeError(f"Action {action.name} has no OBJECT slot")
    if len(slots)==1:
        return slots[0]
    if arm.animation_data and arm.animation_data.action==action and arm.animation_data.action_slot in slots:
        return arm.animation_data.action_slot
    raise RuntimeError(f"Action {action.name}: ambiguous source slots")


def activate(arm, action, slot):
    arm.animation_data_create()
    arm.animation_data.use_nla = False
    arm.animation_data.action = action
    arm.animation_data.action_slot = slot
    arm.animation_data.action_blend_type = "REPLACE"
    arm.animation_data.action_influence = 1.0


def set_frame(frame):
    integer = math.floor(frame)
    bpy.context.scene.frame_set(integer, subframe=frame-integer)
    bpy.context.view_layer.update()


def evaluated_vertices(mesh):
    dg = bpy.context.evaluated_depsgraph_get()
    obj = mesh.evaluated_get(dg)
    data = obj.to_mesh()
    try:
        return [obj.matrix_world @ v.co for v in data.vertices]
    finally:
        obj.to_mesh_clear()


def sample_source(arm, mesh, names):
    scene = bpy.context.scene
    source_fps = scene.render.fps / scene.render.fps_base
    clips = {}
    for name in CLIPS:
        action = bpy.data.actions.get(name)
        if action is None:
            raise RuntimeError(f"Missing required source action {name}")
        slot = action_slot(action, arm)
        activate(arm, action, slot)
        start, end = map(float, action.frame_range)
        duration = (end-start) / source_fps
        count = round(duration*FPS)+1
        samples = []
        mesh_samples = {}
        probe_indices = {0, (count-1)//3, 2*(count-1)//3, count-1}
        for i in range(count):
            time = min(duration, i/FPS)
            set_frame(start+time*source_fps)
            evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
            samples.append({bone: evaluated.matrix_world @ evaluated.pose.bones[bone].matrix for bone in names})
            if i in probe_indices:
                mesh_samples[i] = evaluated_vertices(mesh)
        clips[name] = {"samples": samples, "mesh_samples": mesh_samples, "duration": duration,
                       "source_frame_range": [start,end], "source_slot": slot.identifier}
        print(f"[EXPORT] Sampled {name}: {count} visual poses / {duration:.3f}s", flush=True)
    return clips


def make_export_copy(source_arm, source_mesh, names):
    scene = bpy.context.scene
    collection = bpy.data.collections.new("COL_CH01_Export")
    scene.collection.children.link(collection)
    arm_data = bpy.data.armatures.new("ARM_CH01_EXPORT")
    arm = bpy.data.objects.new("ARM_CH01_EXPORT", arm_data)
    collection.objects.link(arm)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    source_world = source_arm.matrix_world.copy()
    if max(abs(s-1) for s in source_world.to_scale()) > 1e-6:
        raise RuntimeError("Source armature must have unit object scale")
    for name in names:
        source = source_arm.data.bones[name]
        bone = arm_data.edit_bones.new(name)
        # A new EditBone has zero length; initialize both endpoints before its
        # matrix so Blender can retain the intended rest orientation.
        bone.head = source_world @ source.head_local
        bone.tail = source_world @ source.tail_local
        bone.matrix = source_world @ source.matrix_local
        bone.length = source.length
        bone.use_deform = True  # Including the unweighted motion root.
    for name in names:
        source = source_arm.data.bones[name]
        parent = source.parent
        while parent and parent.name not in names:
            parent = parent.parent
        bone = arm_data.edit_bones[name]
        if parent:
            bone.parent = arm_data.edit_bones[parent.name]
            bone.use_connect = source.use_connect
    bpy.ops.object.mode_set(mode="OBJECT")
    for name in names:
        copied = arm_data.bones[name]
        original = source_arm.data.bones[name]
        if (copied.head_local-source_world@original.head_local).length>1e-5 or (copied.tail_local-source_world@original.tail_local).length>1e-5:
            raise RuntimeError(f"Export rest endpoints changed: {name}")
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
    mesh = source_mesh.copy()
    mesh.data = source_mesh.data.copy()
    mesh.animation_data_clear()
    mesh.parent = None
    mesh.matrix_world = source_mesh.matrix_world.copy()
    mesh.data.transform(mesh.matrix_world)
    mesh.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh.modifiers):
        mesh.modifiers.remove(modifier)
    collection.objects.link(mesh)
    mesh.parent = arm
    mesh.matrix_parent_inverse = Matrix.Identity(4)
    modifier = mesh.modifiers.new("BakedSkin", "ARMATURE")
    modifier.object = arm
    modifier.use_deform_preserve_volume = False
    # Source objects/actions are removed only in memory after all visual samples.
    for obj in list(bpy.data.objects):
        if obj not in {arm,mesh}:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action, do_unlink=True)
    arm.name = "ARM_CH01"
    mesh.name = "SM_CH01"
    return arm,mesh


def all_curves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield from bag.fcurves


def bake_actions(arm, clips, names):
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1
    actions = {}
    for name,data in clips.items():
        action = bpy.data.actions.new(name)
        slot = action.slots.new(id_type="OBJECT", name=arm.name)
        activate(arm,action,slot)
        previous = {}
        max_scale_deviation = 0
        for i, sample in enumerate(data["samples"]):
            for bone_name in names:
                pb = arm.pose.bones[bone_name]
                kwargs = {}
                if pb.parent:
                    kwargs.update(parent_matrix=sample[pb.parent.name], parent_matrix_local=pb.parent.bone.matrix_local)
                basis = pb.bone.convert_local_to_pose(sample[bone_name], pb.bone.matrix_local, invert=True, **kwargs)
                location,rotation,scale = basis.decompose()
                max_scale_deviation = max(max_scale_deviation, max(abs(s-1) for s in scale))
                if bone_name in previous and previous[bone_name].dot(rotation)<0:
                    rotation.negate()
                previous[bone_name] = rotation.copy()
                pb.location, pb.rotation_quaternion = location, rotation
                pb.scale = scale if max(abs(s-1) for s in scale)>1e-5 else (1,1,1)
                pb.keyframe_insert("location",frame=i+1,group=bone_name)
                pb.keyframe_insert("rotation_quaternion",frame=i+1,group=bone_name)
                pb.keyframe_insert("scale",frame=i+1,group=bone_name)
        for curve in all_curves(action):
            for key in curve.keyframe_points:
                key.interpolation = "LINEAR"
        data["maximum_baked_scale_deviation"] = max_scale_deviation
        actions[name] = (action,slot)
        print(f"[EXPORT] Baked {name}: explicit slot {slot.identifier}",flush=True)
    return actions


def verify_bake(arm,mesh,clips,actions,names):
    result = {}
    for name,data in clips.items():
        activate(arm,*actions[name])
        position_error = rotation_error = vertex_error = 0
        for i,sample in enumerate(data["samples"]):
            set_frame(i+1)
            evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
            for bone in names:
                actual = evaluated.matrix_world @ evaluated.pose.bones[bone].matrix
                desired = sample[bone]
                position_error = max(position_error,(actual.translation-desired.translation).length)
                angle = actual.to_quaternion().rotation_difference(desired.to_quaternion()).angle
                rotation_error = max(rotation_error,min(angle,abs(math.tau-angle)))
            if i in data["mesh_samples"]:
                actual_vertices = evaluated_vertices(mesh)
                reference = data["mesh_samples"][i]
                if len(actual_vertices)!=len(reference):
                    raise RuntimeError("Skin verification vertex count changed")
                vertex_error = max(vertex_error,max((a-b).length for a,b in zip(actual_vertices,reference)))
        result[name] = {"maximum_bone_position_error_m":position_error,
                        "maximum_bone_rotation_error_degrees":math.degrees(rotation_error),
                        "maximum_skinned_vertex_error_m":vertex_error,
                        "mesh_probe_count":len(data["mesh_samples"])}
        if position_error>2e-4 or rotation_error>math.radians(.10) or vertex_error>3e-4:
            raise RuntimeError(f"Visual bake differs from evaluated source: {name}: {result[name]}")
    return result


def link_export_actions(arm,actions):
    animation = arm.animation_data
    animation.action = None  # Avoid active+NLA exporting the same clip twice.
    animation.use_nla = True
    for track in list(animation.nla_tracks):
        animation.nla_tracks.remove(track)
    for name,(action,slot) in actions.items():
        track = animation.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name,1,action)
        strip.action_slot = slot
        strip.action_frame_start,strip.action_frame_end = action.frame_range
        strip.blend_type = "REPLACE"
        strip.extrapolation = "NOTHING"
        # ACTIONS enumerates the strip slot independently of track mute, then
        # activates each action in isolation while sampling (Blender 5.2).
        track.mute = True


def export_glb(arm,mesh,path,mode):
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True);mesh.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 403
    bpy.context.scene.frame_set(1)
    bpy.ops.export_scene.gltf(filepath=str(path),export_format="GLB",use_selection=True,
        export_yup=True,export_apply=False,export_cameras=False,export_lights=False,
        export_texcoords=True,export_normals=True,export_tangents=True,
        export_materials="EXPORT",export_image_format="AUTO",export_keep_originals=False,
        export_skins=True,export_all_influences=False,export_influence_nb=4,
        export_def_bones=True,export_animations=True,export_animation_mode=mode,
        export_frame_range=False,export_frame_step=1,export_force_sampling=True,
        export_bake_animation=False,export_optimize_animation_size=False,
        export_anim_slide_to_zero=True,export_merge_animation="ACTION",
        export_morph=False,export_extras=False)


def acceptable_audit(report):
    return not report.get("errors") and all("Pillow unavailable; image dimensions not read" in x for x in report.get("incomplete_checks",[]))


def glb_validation(path,source_auditor,names,clips):
    audit = GLBAudit(path)
    structural = audit.run()
    errors,warnings = [],[]
    if not acceptable_audit(structural):errors.append("GLB structural audit errors/incomplete checks")
    doc = audit.doc
    nodes = doc.get("nodes",[])
    node_names = {i:n.get("name","") for i,n in enumerate(nodes)}
    skins = doc.get("skins",[])
    joint_names = [node_names[i] for i in skins[0]["joints"]] if len(skins)==1 else []
    if len(skins)!=1 or set(joint_names)!=set(names):errors.append("Skin does not contain exactly root+22 deform bones")
    if any(name.startswith(("CTRL_","MCH_")) for name in node_names.values()):errors.append("Control/mechanism node leaked into GLB")
    if structural.get("scene",{}).get("triangles")!=18694:errors.append("Triangle count changed from 18694")
    if structural.get("materials",{}).get("count")!=1:errors.append("Material count changed from one")
    roles = material_role_signature(audit)
    if roles!=material_role_signature(source_auditor):errors.append("PBR/alpha/texture-role/image/sampler content changed")
    max_influences = 0
    max_normalization_error = 0
    for m in doc.get("meshes",[]):
        for primitive in m.get("primitives",[]):
            attrs=primitive["attributes"]
            if "TEXCOORD_0" not in attrs or "NORMAL" not in attrs:errors.append("UV0 or normals absent")
            for attribute in ('TEXCOORD_0','NORMAL'):
                if attribute in attrs and any(not all(math.isfinite(v) for v in row) for row in audit.values(attrs[attribute])):
                    errors.append(f"Nonfinite {attribute} values")
            if "JOINTS_0" not in attrs or "WEIGHTS_0" not in attrs:errors.append("Skin vertex attributes absent");continue
            if "JOINTS_1" in attrs or "WEIGHTS_1" in attrs:errors.append("More than four skin influences exported")
            for joints,weights in zip(audit.values(attrs["JOINTS_0"]),audit.values(attrs["WEIGHTS_0"],normalized=True)):
                if not all(math.isfinite(w) and w>=-1e-7 for w in weights):
                    errors.append("Nonfinite/negative skin weights");continue
                max_influences=max(max_influences,sum(w>1e-7 for w in weights))
                max_normalization_error=max(max_normalization_error,abs(sum(weights)-1))
                if any(j<0 or j>=len(joint_names) for j,w in zip(joints,weights) if w>0):errors.append("Invalid joint index")
    if max_influences>4 or max_normalization_error>1e-4:errors.append("Skin influence normalization invalid")
    animations = doc.get("animations",[])
    actual_names = [a.get("name") for a in animations]
    if sorted(actual_names)!=sorted(CLIPS):errors.append(f"Expected exactly three named clips, got {actual_names}")
    animation_stats = []
    root_node = next((i for i,name in node_names.items() if name=="root"),None)
    for animation in animations:
        times=[];root_values=[];sampler_counts=[]
        for channel in animation["channels"]:
            sampler=animation["samplers"][channel["sampler"]]
            t=[v[0] for v in audit.values(sampler["input"])]
            if any(not math.isfinite(v) for v in t) or any(a>=b for a,b in zip(t,t[1:])):errors.append("Nonfinite/non-increasing animation time")
            if any(abs(round(v*FPS)-v*FPS)>1e-3 for v in t):errors.append("Animation time not on 30fps sampling grid")
            times.extend(t);sampler_counts.append(len(t))
            if channel["target"].get("node")==root_node and channel["target"]["path"]=="translation":
                root_values=list(audit.values(sampler["output"]))
            if channel["target"]["path"]=="rotation":
                for q in audit.values(sampler["output"]):
                    if not all(math.isfinite(v) for v in q) or abs(math.sqrt(sum(v*v for v in q))-1)>1e-3:errors.append("Quaternion nonfinite/not normalized")
        duration=max(times,default=0)-min(times,default=0)
        expected=clips.get(animation.get("name"),{}).get("duration")
        if expected is not None and abs(duration-expected)>1/FPS+.001:errors.append("Clip duration differs from source")
        root_delta=[root_values[-1][i]-root_values[0][i] for i in range(3)] if root_values else [0,0,0]
        distance=math.sqrt(sum(v*v for v in root_delta))
        if animation.get("name")=="Walk_Cycle" and distance>1e-4:errors.append("Walk_Cycle is not in-place")
        if animation.get("name")=="Demo" and (not root_values or distance<4):errors.append("Demo root motion missing")
        animation_stats.append({"name":animation.get("name"),"duration_seconds":duration,
            "channels":len(animation["channels"]),"minimum_sampler_keys":min(sampler_counts,default=0),
            "maximum_sampler_keys":max(sampler_counts,default=0),"root_translation_delta_gltf":root_delta,
            "root_motion_distance_m":distance})
    return {"status":"failed" if errors else "exported_structurally_checked_engine_review_pending",
            "errors":sorted(set(errors)),"warnings":warnings,"joint_names":joint_names,
            "joint_count":len(joint_names),"skin_count":len(skins),"animations":animation_stats,
            "maximum_influences":max_influences,"maximum_weight_normalization_error":max_normalization_error,
            "pbr_texture_roles_preserved":roles==material_role_signature(source_auditor),"glb_audit":structural}


def main():
    opts=arguments()
    input_path=(opts.input if opts.input.is_absolute() else HERE/opts.input).resolve()
    if not input_path.is_absolute() or not input_path.is_file():raise FileNotFoundError(input_path)
    output=(opts.output if opts.output.is_absolute() else HERE/opts.output).resolve()
    if output.parent!=HERE or output.suffix.lower()!=".glb":raise ValueError("Output must be a derived GLB in this CH01 folder")
    if output.exists() and not opts.overwrite:raise FileExistsError("Derived final exists; use --overwrite if intended")
    protected={str(input_path):digest(input_path),str(SOURCE_GLB):digest(SOURCE_GLB),str(HERE/'rig.blend'):digest(HERE/'rig.blend')}
    qa={"created_utc":datetime.now(timezone.utc).isoformat(),"blender":bpy.app.version_string,
        "input_blend":str(input_path),"output":str(output),"sampling_fps":FPS,"protected_input_hashes":protected,
        "status":"in_progress","limitations":["Engine import/playback QA remains independent; no production/game-ready certification"]}
    candidate=output.with_name(output.stem+'.candidate.glb')
    try:
        bpy.ops.wm.open_mainfile(filepath=str(input_path))
        source_arm=bpy.data.objects['ARM_CH01'];source_mesh=bpy.data.objects['SM_CH01']
        source_arm.data.pose_position='POSE'
        names=[b.name for b in source_arm.data.bones if b.name=='root' or b.use_deform]
        if len(names)!=23 or 'root' not in names:raise RuntimeError(f"Expected 23 root/deform bones, got {names}")
        clips=sample_source(source_arm,source_mesh,names)
        arm,mesh=make_export_copy(source_arm,source_mesh,names)
        actions=bake_actions(arm,clips,names)
        qa['visual_bake_comparison']=verify_bake(arm,mesh,clips,actions,names)
        qa['source_clips']={name:{k:v for k,v in data.items() if k not in {'samples','mesh_samples'}} for name,data in clips.items()}
        link_export_actions(arm,actions)
        source_auditor=GLBAudit(SOURCE_GLB);source_auditor.run()
        qa['export_attempts']=[]
        for mode in ('ACTIONS','NLA_TRACKS'):
            if mode=='NLA_TRACKS':
                for track in arm.animation_data.nla_tracks:track.mute=False
            export_glb(arm,mesh,candidate,mode)
            validation=glb_validation(candidate,source_auditor,names,clips)
            qa['export_attempts'].append({'mode':mode,'status':validation['status'],'errors':validation['errors']})
            if not validation['errors']:break
            if not any('named clips' in e for e in validation['errors']):break
        qa['validation']=validation
        qa['protected_inputs_unchanged']=all(digest(path)==hash_value for path,hash_value in protected.items())
        if validation['errors'] or not qa['protected_inputs_unchanged']:
            raise RuntimeError(f"Final GLB withheld: {validation['errors']}")
        os.replace(candidate,output)
        qa['status']=validation['status']
        qa['output_sha256']=digest(output)
        qa['output_bytes']=output.stat().st_size
        qa['validation']['glb_audit']['path']=str(output)
        print('[EXPORT] Final GLB published: '+str(output),flush=True)
    except Exception as exc:
        qa['status']='failed_final_withheld'
        qa['error']=f'{type(exc).__name__}: {exc}'
        qa['traceback']=traceback.format_exc()
        qa['candidate']=str(candidate) if candidate.exists() else None
        qa['protected_inputs_unchanged']=all(digest(path)==hash_value for path,hash_value in protected.items())
        raise
    finally:
        (HERE/'export_qa.json').write_text(json.dumps(qa,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':main()
