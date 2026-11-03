#!/usr/bin/env python3
"""Build an editable CH01 humanoid rig and deformation QA in Blender 5.2.

Production brief: existing 18,694-triangle pilot, one PBR material/2K maps;
height 1.82m, -Y forward, +Z up, anatomical left +X. One motion root;
two-bone IK legs with world-aligned foot/pole controls, FK torso/arms.
The source GLB is read-only. A welded temporary proxy is used only to solve
heat weights; the original split-vertex render topology/UVs/normals remain.
Weights are transferred by position, then cleaned with anatomical envelopes
and rigid helmet/plate rules. Maximum four normalized influences per vertex.

Usage: blender --background --factory-startup --python-exit-code 1 \
  --python build_rig.py
Writes only this directory: rig.blend, rig_spec.json, rig_qa.json, QA PNGs.
"""
from __future__ import annotations

from array import array
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import traceback

import bpy
import bmesh
from mathutils import Matrix, Vector
from mathutils.kdtree import KDTree

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / "downloads" / "CH01.glb"
HEIGHT = 1.82
LANDMARKS = {
    "pelvis": (0, .035, .94), "waist": (0, .025, 1.06),
    "spine_mid": (0, .025, 1.19), "chest_base": (0, .025, 1.32),
    "neck_base": (0, .025, 1.48), "head_base": (0, .025, 1.60),
    "head_top": (0, .025, 1.79),
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def smooth(a, b, value):
    t = max(0.0, min(1.0, (value - a) / (b - a)))
    return t * t * (3 - 2 * t)


def tri_count(mesh):
    mesh.calc_loop_triangles()
    return len(mesh.loop_triangles)


def uv_hash(mesh):
    h = hashlib.sha256()
    for uv in mesh.uv_layers:
        values = array("f", [0.0]) * (2 * len(uv.data))
        uv.data.foreach_get("uv", values)
        h.update(values.tobytes())
    return h.hexdigest()


def bounds(points):
    pts = list(points)
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    return {"min": lo, "max": hi, "size": [hi[i] - lo[i] for i in range(3)]}


def import_character():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(SOURCE), merge_vertices=False, import_shading="NORMALS")
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if len(meshes) != 1:
        raise RuntimeError(f"Expected one source mesh, found {len(meshes)}")
    obj = meshes[0]
    for other in list(bpy.context.scene.objects):
        if other != obj:
            bpy.data.objects.remove(other, do_unlink=True)
    world = obj.matrix_world.copy()
    obj.parent = None
    obj.data.transform(world)
    obj.matrix_world = Matrix.Identity(4)
    original_bounds = bounds(v.co for v in obj.data.vertices)
    lo, hi = original_bounds["min"], original_bounds["max"]
    origin = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]))
    factor = HEIGHT / (hi[2] - lo[2])
    for v in obj.data.vertices:
        v.co = (v.co - origin) * factor
    obj.data.update()
    obj.name = "SM_CH01"
    obj.data.name = "SM_CH01_RenderMesh"
    col = bpy.data.collections.new("COL_CH01")
    bpy.context.scene.collection.children.link(col)
    for old in list(obj.users_collection):
        old.objects.unlink(obj)
    col.objects.link(obj)
    return obj, col, {"original_bounds": original_bounds, "uniform_scale_to_meters": factor,
                      "center_and_floor_offset": list(origin)}


def create_armature(col):
    data = bpy.data.armatures.new("ARM_CH01")
    arm = bpy.data.objects.new("ARM_CH01", data)
    col.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    arm.show_in_front = True
    bpy.ops.object.mode_set(mode="EDIT")
    info = {}
    def bone(name, head, tail, parent=None, deform=True, roll_hint=None):
        b = data.edit_bones.new(name)
        b.head, b.tail = head, tail
        b.use_deform = deform
        if parent:
            b.parent = data.edit_bones[parent]
            b.use_connect = (b.head - b.parent.tail).length < 1e-6
        if roll_hint:
            b.align_roll(Vector(roll_hint))
        else:
            b.roll = 0
        info[name] = {"head": list(b.head), "tail": list(b.tail), "parent": parent,
                      "deform": deform, "roll": b.roll}
        return b
    bone("root", (0, 0, 0), (0, .18, 0), deform=False)
    bone("pelvis", LANDMARKS["pelvis"], LANDMARKS["waist"], "root", roll_hint=(0,-1,0))
    bone("spine_01", LANDMARKS["waist"], LANDMARKS["spine_mid"], "pelvis", roll_hint=(0,-1,0))
    bone("spine_02", LANDMARKS["spine_mid"], LANDMARKS["chest_base"], "spine_01", roll_hint=(0,-1,0))
    bone("chest", LANDMARKS["chest_base"], LANDMARKS["neck_base"], "spine_02", roll_hint=(0,-1,0))
    bone("neck", LANDMARKS["neck_base"], LANDMARKS["head_base"], "chest", roll_hint=(0,-1,0))
    bone("head", LANDMARKS["head_base"], LANDMARKS["head_top"], "neck", roll_hint=(0,-1,0))
    for side, s in (("L", 1), ("R", -1)):
        shoulder, elbow = (s*.195,.065,1.455), (s*.485,.075,1.440)
        wrist, fingertip = (s*.735,.010,1.435), (s*.905,-.02,1.415)
        hip, knee = (s*.105,.035,.94), (s*.135,.015,.535)
        ankle, ball, toe = (s*.14,.040,.115), (s*.14,-.095,.052), (s*.14,-.175,.052)
        bone("clavicle."+side, (0,.035,1.435), shoulder, "chest", roll_hint=(0,0,1))
        bone("upper_arm."+side, shoulder, elbow, "clavicle."+side, roll_hint=(0,0,1))
        bone("forearm."+side, elbow, wrist, "upper_arm."+side, roll_hint=(0,0,1))
        bone("hand."+side, wrist, fingertip, "forearm."+side, roll_hint=(0,0,1))
        bone("thigh."+side, hip, knee, "pelvis", roll_hint=(0,1,0))
        bone("shin."+side, knee, ankle, "thigh."+side, roll_hint=(0,1,0))
        bone("foot."+side, ankle, ball, "shin."+side, roll_hint=(0,0,1))
        bone("toe."+side, ball, toe, "foot."+side, roll_hint=(0,0,1))
        bone("CTRL_foot."+side, ankle, Vector(ankle)+Vector((0,.16,0)), "root", deform=False)
        pole = (s*.135,-.48,.535)
        bone("CTRL_knee."+side, pole, Vector(pole)+Vector((0,.12,0)), "root", deform=False)
        bone("MCH_foot."+side, ankle, ball, "CTRL_foot."+side, deform=False, roll_hint=(0,0,1))
    bpy.ops.object.mode_set(mode="OBJECT")
    controls = data.collections.new("Controls")
    deform = data.collections.new("Deform")
    mechanism = data.collections.new("Mechanism")
    for b in data.bones:
        for c in list(b.collections):
            c.unassign(b)
        if b.name.startswith("MCH_"):
            mechanism.assign(b)
            b.hide = True
        elif not b.use_deform:
            controls.assign(b)
            b.color.palette = "THEME04"
        else:
            deform.assign(b)
            b.color.palette = "THEME03"
    mechanism.is_visible = False
    for pb in arm.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.ik_stretch = 0
    return arm, info


def configure_ik(arm):
    diagnostics = {}
    for side in ("L", "R"):
        shin = arm.pose.bones["shin."+side]
        ik = shin.constraints.new("IK")
        ik.name = "LegIK_"+side
        ik.target, ik.subtarget = arm, "CTRL_foot."+side
        ik.pole_target, ik.pole_subtarget = arm, "CTRL_knee."+side
        ik.chain_count, ik.use_stretch = 2, False
        ik.iterations = 100
        copy = arm.pose.bones["foot."+side].constraints.new("COPY_ROTATION")
        copy.name = "FootOrientation_"+side
        copy.target, copy.subtarget = arm, "MCH_foot."+side
        copy.owner_space = copy.target_space = "POSE"
        copy.mix_mode = "REPLACE"
        desired = arm.data.bones["shin."+side].head_local.copy()
        # A nearly straight rest leg poorly determines its bend-plane twist.
        # Calibrate in a functional crouch against the actual pole plane.
        pelvis = arm.pose.bones['pelvis']
        pelvis.location = arm.data.bones['pelvis'].matrix_local.to_3x3().inverted() @ Vector((0,-.025,-.20))
        bpy.context.view_layer.update()
        hip = arm.pose.bones['thigh.'+side].head.copy()
        ankle = arm.pose.bones['CTRL_foot.'+side].head.copy()
        pole = arm.pose.bones['CTRL_knee.'+side].head.copy()
        axis = (ankle-hip).normalized()
        pole_vector = pole-hip
        forward = (pole_vector-axis*pole_vector.dot(axis)).normalized()
        distance = (ankle-hip).length
        upper = arm.data.bones['thigh.'+side].length
        lower = arm.data.bones['shin.'+side].length
        along = (upper*upper-lower*lower+distance*distance)/(2*distance)
        altitude = math.sqrt(max(0,upper*upper-along*along))
        desired_bend = hip+axis*along+forward*altitude
        candidates = []
        for index in range(72):
            angle = -math.pi + index * math.tau/72
            ik.pole_angle = angle
            bpy.context.view_layer.update()
            candidates.append(((shin.head-desired_bend).length, angle))
        error, angle = min(candidates)
        best_angle=angle
        for index in range(-20,21):
            trial=angle+math.radians(index*.25)
            ik.pole_angle=trial
            bpy.context.view_layer.update()
            candidate_error=(shin.head-desired_bend).length
            if candidate_error<error:
                error,best_angle=candidate_error,trial
        angle=best_angle
        ik.pole_angle = angle
        pelvis.location=(0,0,0)
        bpy.context.view_layer.update()
        diagnostics[side] = {"pole_angle_radians": angle, "rest_knee_error_m": (shin.head-desired).length,
                             "crouch_pole_plane_error_m":error,
                             "target": list(arm.pose.bones["CTRL_foot."+side].head)}
    return diagnostics


def automatic_proxy_weights(mesh_obj, arm, col):
    proxy = bpy.data.objects.new("TMP_CH01_WeightSolveProxy", mesh_obj.data.copy())
    col.objects.link(proxy)
    bm = bmesh.new()
    bm.from_mesh(proxy.data)
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=1e-5)
    bm.normal_update()
    bm.to_mesh(proxy.data)
    bm.free()
    proxy.data.update()
    stats = {"proxy_vertices": len(proxy.data.vertices), "render_vertices": len(mesh_obj.data.vertices),
             "weld_threshold_m": 1e-5, "render_mesh_welded": False, "heat_solver_success": True}
    bpy.ops.object.select_all(action="DESELECT")
    proxy.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    try:
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    except RuntimeError as exc:
        stats["heat_solver_success"] = False
        stats["heat_solver_message"] = str(exc)
    deform_names = {b.name for b in arm.data.bones if b.use_deform}
    group_names = {g.index:g.name for g in proxy.vertex_groups}
    tree = KDTree(len(proxy.data.vertices))
    proxy_weights = []
    for v in proxy.data.vertices:
        tree.insert(v.co, v.index)
        proxy_weights.append({group_names[g.group]:g.weight for g in v.groups
                              if group_names.get(g.group) in deform_names and g.weight>1e-6})
    tree.balance()
    auto = []
    no_weights = 0
    for v in mesh_obj.data.vertices:
        _, index, distance = tree.find(v.co)
        weights = proxy_weights[index] if distance < 5e-5 else {}
        auto.append(weights)
        no_weights += not bool(weights)
    stats["render_vertices_missing_heat_weights"] = no_weights
    if no_weights:
        stats["heat_solver_success"] = False
    data = proxy.data
    bpy.data.objects.remove(proxy, do_unlink=True)
    bpy.data.meshes.remove(data)
    return auto, stats


def anatomical_weights(co):
    x,y,z = co
    ax = abs(x)
    side = "L" if x>=0 else "R"
    # Helmet is a rigid shell, not a deforming skull/face.
    if z>=1.57 and ax<.20:
        return {"head":1}, True, "helmet"
    if z>1.50 and ax<.145:
        t=smooth(1.51,1.595,z)
        return {"neck":1-t,"head":t}, False, "neck"
    if .165<ax<.32 and z>1.495:
        return {"upper_arm."+side:1},True,"shoulder_plate"
    if ax>.215 and z>1.25:
        if ax>.755:
            return {"hand."+side:1}, True, "glove"
        if ax>.685:
            t=smooth(.685,.765,ax)
            return {"forearm."+side:1-t,"hand."+side:t}, False, "wrist"
        if ax>.43:
            t=smooth(.435,.545,ax)
            return {"upper_arm."+side:1-t,"forearm."+side:t}, False, "elbow_forearm"
        if z>1.495 and ax<.32:
            return {"upper_arm."+side:1}, True, "shoulder_plate"
        t=smooth(.205,.30,ax)
        return {"chest":.32*(1-t),"clavicle."+side:.28*(1-t),"upper_arm."+side:.40+.60*t}, False,"shoulder"
    if z<1.035:
        thigh,shin,foot,toe=(part+"."+side for part in ("thigh","shin","foot","toe"))
        if z<.14:
            t=smooth(.085,.145,-y)*(1-smooth(.10,.16,z))
            return {foot:1-t,toe:t}, True, "boot_sole_toe"
        if z<.23:
            t=smooth(.12,.225,z)
            return {foot:1-t,shin:t}, False, "ankle"
        if z<.47:
            return {shin:1}, False, "shin"
        if z<.61:
            if y<-.065 and .49<z<.605:
                return {shin:1},True,"knee_plate"
            t=smooth(.475,.605,z)
            return {shin:1-t,thigh:t},False,"knee"
        if z<.865:
            return {thigh:1},False,"thigh"
        t=smooth(.865,1.04,z)
        return {thigh:1-t,"pelvis":t},False,"hip"
    if z<1.14:
        t=smooth(1.025,1.14,z)
        return {"pelvis":1-t,"spine_01":t},False,"waist"
    if y<-.075 and 1.26<z<1.465:
        return {"chest":1},True,"chest_plate"
    if z<1.27:
        t=smooth(1.14,1.27,z)
        return {"spine_01":1-t,"spine_02":t},False,"abdomen"
    if z<1.38:
        t=smooth(1.27,1.38,z)
        return {"spine_02":1-t,"chest":t},False,"thorax"
    return {"chest":1},False,"chest"


def bind_clean_weights(mesh_obj,arm,auto):
    for group in list(mesh_obj.vertex_groups):
        mesh_obj.vertex_groups.remove(group)
    groups={b.name:mesh_obj.vertex_groups.new(name=b.name) for b in arm.data.bones if b.use_deform}
    regions=defaultdict(int)
    for v in mesh_obj.data.vertices:
        authored,rigid,region=anatomical_weights(v.co)
        regions[region]+=1
        weights={k:w for k,w in authored.items() if w>1e-7}
        # Keep only anatomically allowed heat influences at soft joints.
        if not rigid:
            allowed={k:w for k,w in auto[v.index].items() if k in weights}
            total=sum(allowed.values())
            if total>1e-8:
                weights={k:.85*w+.15*allowed.get(k,0)/total for k,w in weights.items()}
        weights=dict(sorted(weights.items(),key=lambda kv:kv[1],reverse=True)[:4])
        total=sum(weights.values())
        if total<=0:
            raise RuntimeError(f"Unweighted vertex {v.index}")
        for name,weight in weights.items():
            groups[name].add([v.index],weight/total,"REPLACE")
    mesh_obj.parent=arm
    mesh_obj.matrix_parent_inverse=Matrix.Identity(4)
    modifier=mesh_obj.modifiers.new("CH01_Deform","ARMATURE")
    modifier.object=arm
    modifier.use_deform_preserve_volume=False  # Match standard game-engine LBS.
    return dict(regions)


def weight_audit(mesh_obj,arm):
    deform={b.name for b in arm.data.bones if b.use_deform}
    names={g.index:g.name for g in mesh_obj.vertex_groups}
    max_inf=0
    max_err=0
    missing=bad_names=0
    helmet_bad=0
    for v in mesh_obj.data.vertices:
        inf=[(names[g.group],g.weight) for g in v.groups if g.weight>1e-7]
        max_inf=max(max_inf,len(inf))
        max_err=max(max_err,abs(sum(w for _,w in inf)-1))
        missing+=not bool(inf)
        bad_names+=sum(name not in deform for name,_ in inf)
        if v.co.z>=1.57 and abs(v.co.x)<.20:
            helmet_bad+=not(len(inf)==1 and inf[0][0]=="head" and abs(inf[0][1]-1)<1e-5)
    return {"maximum_influences":max_inf,"maximum_normalization_error":max_err,
            "unweighted_vertices":missing,"nondeform_influences":bad_names,
            "helmet_vertices_not_rigid_head":helmet_bad}


def rest_spec(arm,info,normalization):
    for b in arm.data.bones:
        info[b.name].update(matrix_local=[list(row) for row in b.matrix_local],
                            x_axis=list(b.x_axis),y_axis=list(b.y_axis),z_axis=list(b.z_axis))
    return {"armature":"ARM_CH01","mesh":"SM_CH01","height_m":HEIGHT,
            "axes":{"forward":"-Y","up":"+Z","anatomical_left":"+X"},
            "rotation_mode":"XYZ (motion agent may author quaternions in a separate animated file)",
            "bones":info,"normalization":normalization,
            "controls":{"root":"world-aligned rest axes; translate -Y for forward motion",
                        "feet":"CTRL_foot.L/R parent=root, local XYZ==world XYZ in rest; location is delta from rest ankle/root; rotation Euler X pitches around world X",
                        "knees":"CTRL_knee.L/R parent=root; forward poles at -Y; same world-aligned axes",
                        "foot_orientation":"MCH_foot child of CTRL_foot supplies rest offset; foot copies MCH POSE rotation",
                        "toe":"FK toe.L/R; compute local pitch basis from matrix_local",
                        "arms_spine":"FK; set desired armature-space orientations through rest/parent basis"},
            "limits":{"foot_ik_stretch":False,"max_weights":4,"helmet_rigid":True,
                      "fingers":False,"facial_rig":False,"game_ready":False}}


def reset_pose(arm):
    for pb in arm.pose.bones:
        pb.matrix_basis=Matrix.Identity(4)
    bpy.context.view_layer.update()


def aim_bone(arm,name,direction):
    """Point a FK bone in armature space, preserving a sensible rest twist."""
    pb=arm.pose.bones[name]
    rest=arm.data.bones[name].matrix_local.to_quaternion()
    delta=(rest@Vector((0,1,0))).rotation_difference(Vector(direction).normalized())
    desired=(delta@rest).to_matrix().to_4x4()
    desired.translation=pb.head
    pb.matrix=desired
    bpy.context.view_layer.update()


def arms_down(arm):
    for side,s in (("L",1),("R",-1)):
        aim_bone(arm,"upper_arm."+side,(s*.07,-.025,-.28))
        aim_bone(arm,"forearm."+side,(s*.015,-.035,-.25))
        aim_bone(arm,"hand."+side,(s*.01,-.015,-.16))


def posed_audit(mesh_obj,arm):
    dg=bpy.context.evaluated_depsgraph_get()
    evaluated=mesh_obj.evaluated_get(dg)
    mesh=evaluated.to_mesh()
    try:
        posed=[evaluated.matrix_world@v.co for v in mesh.vertices]
        result={"bounds":bounds(posed),"nonfinite_vertices":sum(not all(math.isfinite(c) for c in p) for p in posed),
                "feet":{s:{"ankle":list(arm.pose.bones['foot.'+s].head),"knee":list(arm.pose.bones['shin.'+s].head)} for s in ('L','R')}}
    finally:
        evaluated.to_mesh_clear()
    return result


def setup_studio(col):
    scene=bpy.context.scene
    scene.render.engine='BLENDER_EEVEE'
    scene.render.resolution_x=900
    scene.render.resolution_y=900
    scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'
    scene.world=bpy.data.worlds.new('QAWorld')
    scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.16,.18,.21,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.5
    studio=bpy.data.collections.new('COL_RigQA_Studio')
    scene.collection.children.link(studio)
    camdata=bpy.data.cameras.new('CAM_RigQA')
    camera=bpy.data.objects.new('CAM_RigQA',camdata)
    studio.objects.link(camera)
    target=Vector((0,0,.95))
    camera.location=(2.8,-4.8,2.2)
    camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
    camdata.type='ORTHO';camdata.ortho_scale=2.35
    scene.camera=camera
    for name,pos,energy,size in (('Key',(-3,-4,5),650,4),('Fill',(3,-2,3),350,4),('Rim',(1,3,4),750,3)):
        data=bpy.data.lights.new('LGT_'+name,'AREA');data.energy=energy;data.size=size
        light=bpy.data.objects.new('LGT_'+name,data);studio.objects.link(light)
        light.location=pos;light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.003))
    floor=bpy.context.object;floor.name='SM_QAFloor'
    for c in list(floor.users_collection):c.objects.unlink(floor)
    studio.objects.link(floor)
    material=bpy.data.materials.new('MAT_QAFloor');material.diffuse_color=(.19,.21,.24,1)
    floor.data.materials.append(material)
    return studio


def main():
    source_hash=digest(SOURCE)
    print('[RIG] Import CH01',flush=True)
    mesh,col,normalization=import_character()
    initial_uv=uv_hash(mesh.data)
    initial_tris=tri_count(mesh.data)
    arm,info=create_armature(col)
    ik=configure_ik(arm)
    print('[RIG] Heat solve on welded proxy',flush=True)
    auto,heat=automatic_proxy_weights(mesh,arm,col)
    regions=bind_clean_weights(mesh,arm,auto)
    qa={"source":str(SOURCE),"source_sha256":source_hash,"normalization":normalization,
        "heat_weights":heat,"weight_regions":regions,"ik":ik,"weights":weight_audit(mesh,arm),
        "triangles":tri_count(mesh.data),"vertices":len(mesh.data.vertices),"materials":len(mesh.data.materials),
        "uv_preserved":initial_uv==uv_hash(mesh.data),"source_unchanged":source_hash==digest(SOURCE),
        "topology_preserved":initial_tris==tri_count(mesh.data),"poses":{},
        "limitations":["No finger/facial controls; gloves move as hands, helmet is rigid",
                       "Automatic heat solve is only a starting point; anatomical envelopes/rigid plate cleanup authored afterwards",
                       "Deformation and contacts need visual review; no production/animation-export PASS implied"]}
    qa['hierarchy']={'root_bones':[b.name for b in arm.data.bones if b.parent is None],
                     'bone_count':len(arm.data.bones),
                     'deform_bone_count':sum(b.use_deform for b in arm.data.bones),
                     'object_scale':list(arm.scale),'mesh_scale':list(mesh.scale)}
    qa['packed_textures']=[{'name':i.name,'size':list(i.size),'packed':bool(i.packed_file)} for i in bpy.data.images if i.source=='FILE']
    qa['controls_world_aligned']={name:max(abs(arm.data.bones[name].matrix_local.to_3x3()[i][j]-(1 if i==j else 0)) for i in range(3) for j in range(3))<1e-6
        for name in ('root','CTRL_foot.L','CTRL_foot.R','CTRL_knee.L','CTRL_knee.R')}
    spec=rest_spec(arm,info,normalization)
    spec['ik']=ik
    spec['weights']=qa['weights']
    spec['foot_contact_reference']={'floor_z':0,'ankle_height_m':.115,
        'boot_y_extent_m':[-.164,.128],
        'note':'Contact reference in rest; animator should measure evaluated sole vertices when adding heel/toe roll'}
    (HERE/'rig_spec.json').write_text(json.dumps(spec,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    reset_pose(arm)
    bpy.context.scene.unit_settings.system='METRIC'
    bpy.context.scene.unit_settings.scale_length=1
    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'rig.blend'))
    print('[RIG] NEUTRAL RIG READY: rig.blend + rig_spec.json',flush=True)
    studio=setup_studio(col)
    for pose in ('neutral','arms_down','wave','crouch'):
        reset_pose(arm)
        if pose!='neutral':arms_down(arm)
        if pose=='wave':
            aim_bone(arm,'upper_arm.R',(-.24,-.015,-.10))
            aim_bone(arm,'forearm.R',(.025,-.025,.24))
            aim_bone(arm,'hand.R',(.01,-.015,.16))
        if pose=='crouch':
            pb=arm.pose.bones['pelvis']
            displacement=Vector((0,-.025,-.20))
            pb.location=arm.data.bones['pelvis'].matrix_local.to_3x3().inverted()@displacement
            for name,angle in (('spine_01',5),('spine_02',5),('chest',3)):
                arm.pose.bones[name].rotation_euler.x=math.radians(angle)
            bpy.context.view_layer.update()
        qa['poses'][pose]=posed_audit(mesh,arm)
        bpy.context.scene.render.filepath=str(HERE/f'rig_qa_{pose}.png')
        bpy.ops.render.render(write_still=True)
        qa['poses'][pose]['image']=f'rig_qa_{pose}.png'
        if pose=='crouch':
            camera=bpy.context.scene.camera
            original_matrix=camera.matrix_world.copy()
            target=Vector((0,-.05,.90))
            camera.location=(4,0,1.3)
            camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
            bpy.context.scene.render.filepath=str(HERE/'rig_qa_crouch_side.png')
            bpy.ops.render.render(write_still=True)
            qa['poses'][pose]['side_image']='rig_qa_crouch_side.png'
            camera.matrix_world=original_matrix
        print('[RIG] QA rendered '+pose,flush=True)
    reset_pose(arm)
    # The editable rig file excludes the temporary QA studio entirely.
    for obj in list(studio.objects):bpy.data.objects.remove(obj,do_unlink=True)
    bpy.data.collections.remove(studio)
    bpy.context.scene.camera=None
    bpy.ops.object.select_all(action='DESELECT');arm.select_set(True)
    bpy.context.view_layer.objects.active=arm
    qa['source_unchanged']=source_hash==digest(SOURCE)
    qa['status']='built_visual_review_required'
    (HERE/'rig_qa.json').write_text(json.dumps(qa,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'rig.blend'))
    print('[RIG] Complete',flush=True)


if __name__=='__main__':
    try:main()
    except Exception:
        (HERE/'rig_build_error.txt').write_text(traceback.format_exc(),encoding='utf-8')
        raise
