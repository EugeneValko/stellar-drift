"""Background Blender studio and resumable frame renderer for the CH01 demo."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent


def args():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', type=Path, default=HERE / 'animated.blend')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--action', default='Demo')
    p.add_argument('--frames', help='Comma separated QA frames; otherwise render the complete action')
    p.add_argument('--width', type=int, default=1920)
    p.add_argument('--height', type=int, default=1080)
    p.add_argument('--samples', type=int, default=32)
    p.add_argument('--resume', action='store_true')
    p.add_argument('--setup-only', action='store_true')
    return p.parse_args(argv)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def linear_keys(obj):
    action = obj.animation_data.action if obj.animation_data else None
    if not action:
        return
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    for key in curve.keyframe_points:
                        key.interpolation = 'LINEAR'


def studio(scene, arm, start, end, samples):
    for obj in list(scene.objects):
        if obj.type in {'CAMERA', 'LIGHT'}:
            bpy.data.objects.remove(obj, do_unlink=True)
    # Retain the rigged render mesh; hide bone-control shapes and earlier QA floors.
    for obj in scene.objects:
        if obj.type == 'MESH':
            skinned = any(m.type == 'ARMATURE' and m.object == arm for m in obj.modifiers)
            obj.hide_render = not skinned
    collection = bpy.data.collections.new('COL_CH01_Studio')
    scene.collection.children.link(collection)
    world = bpy.data.worlds.new('WORLD_CH01_Studio')
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.12, 0.15, 0.19, 1)
    world.node_tree.nodes['Background'].inputs['Strength'].default_value = 0.35
    scene.world = world
    scene.render.engine = 'BLENDER_EEVEE'
    if hasattr(scene, 'eevee'):
        if hasattr(scene.eevee, 'taa_render_samples'):
            scene.eevee.taa_render_samples = samples
        if hasattr(scene.eevee, 'use_raytracing'):
            scene.eevee.use_raytracing = False
    scene.view_settings.view_transform = 'AgX'
    try:
        scene.view_settings.look = 'AgX - Medium High Contrast'
    except TypeError:
        pass
    scene.view_settings.exposure = 0
    scene.render.film_transparent = False
    if hasattr(scene.render, 'use_motion_blur'):
        scene.render.use_motion_blur = True
        scene.render.motion_blur_shutter = 0.22

    mesh = bpy.data.meshes.new('MESH_StudioFloor')
    mesh.from_pydata([(-30, -30, -0.002), (30, -30, -0.002),
                      (30, 30, -0.002), (-30, 30, -0.002)], [], [(0, 1, 2, 3)])
    floor = bpy.data.objects.new('SM_StudioFloor', mesh)
    collection.objects.link(floor)
    material = bpy.data.materials.new('MAT_StudioFloor')
    material.use_nodes = True
    nt = material.node_tree
    bsdf = nt.nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = 0.76
    coord = nt.nodes.new('ShaderNodeTexCoord')
    checker = nt.nodes.new('ShaderNodeTexChecker')
    checker.inputs['Color1'].default_value = (0.055, 0.072, 0.091, 1)
    checker.inputs['Color2'].default_value = (0.061, 0.079, 0.098, 1)
    checker.inputs['Scale'].default_value = 1.25
    nt.links.new(coord.outputs['Object'], checker.inputs['Vector'])
    nt.links.new(checker.outputs['Color'], bsdf.inputs['Base Color'])
    floor.data.materials.append(material)

    camera_data = bpy.data.cameras.new('CAM_CH01_Demo')
    camera_data.lens = 52
    camera_data.clip_start, camera_data.clip_end = 0.05, 120
    camera = bpy.data.objects.new('CAM_CH01_Demo', camera_data)
    collection.objects.link(camera)
    scene.camera = camera
    # Right hand is nearest this camera; full-body framing keeps the foot contacts visible.
    offset = Vector((-2.7, -5.1, 1.30))
    lights = []
    for name, pos, energy, size, color in [
        ('Key', (-3.4, -4.2, 5.8), 900, 4.5, (1.0, 0.95, 0.88)),
        ('Fill', (4.0, -2.0, 3.0), 500, 4.0, (0.77, 0.86, 1.0)),
        ('Rim', (1.0, 3.2, 4.5), 950, 3.5, (0.82, 0.90, 1.0)),
    ]:
        data = bpy.data.lights.new('LIGHT_CH01_' + name, 'AREA')
        data.energy, data.size, data.color = energy, size, color
        light = bpy.data.objects.new('LIGHT_CH01_' + name, data)
        collection.objects.link(light)
        lights.append((light, Vector(pos)))

    root_positions = []
    for frame in range(start, end + 1):
        scene.frame_set(frame)
        evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
        root = evaluated.matrix_world @ evaluated.pose.bones['root'].matrix.translation
        root_positions.append(list(root))
        target = root + Vector((0, 0, 0.94))
        camera.location = root + offset
        camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
        camera.keyframe_insert('location', frame=frame)
        camera.keyframe_insert('rotation_euler', frame=frame)
        for light, relative in lights:
            light.location = root + relative
            light.rotation_euler = (target - light.location).to_track_quat('-Z', 'Y').to_euler()
            light.keyframe_insert('location', frame=frame)
            light.keyframe_insert('rotation_euler', frame=frame)
    for obj in [camera] + [light for light, _ in lights]:
        linear_keys(obj)
    scene.frame_set(start)
    return root_positions


def main():
    opt = args()
    opt.output.mkdir(parents=True, exist_ok=True)
    signature = {'blend_sha256': sha(opt.input), 'script_sha256': sha(__file__),
                 'width': opt.width, 'height': opt.height, 'samples': opt.samples}
    manifest_path = opt.output / 'render_manifest.json'
    if opt.resume and manifest_path.exists():
        old = json.loads(manifest_path.read_text(encoding='utf-8'))
        if old['signature'] != signature:
            raise ValueError('Render inputs changed: choose a fresh frame directory')
    bpy.ops.wm.open_mainfile(filepath=str(opt.input.resolve()))
    scene = bpy.context.scene
    arm = bpy.data.objects.get('ARM_CH01')
    if not arm or arm.type != 'ARMATURE':
        raise ValueError('ARM_CH01 is missing')
    action = bpy.data.actions.get(opt.action)
    if action is None:
        raise ValueError(f'Action {opt.action!r} is missing')
    arm.animation_data_create()
    for track in arm.animation_data.nla_tracks:
        track.mute = True
    arm.animation_data.action = action
    if action.slots:
        arm.animation_data.action_slot = action.slots[0]
    for act in bpy.data.actions:
        act.use_fake_user = True
    start, end = (int(round(v)) for v in action.frame_range)
    scene.frame_start, scene.frame_end = start, end
    scene.render.fps, scene.render.fps_base = 30, 1
    positions = studio(scene, arm, start, end, opt.samples)
    scene.render.resolution_x, scene.render.resolution_y = opt.width, opt.height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGB'
    scene.render.image_settings.compression = 15
    bpy.ops.file.pack_all()
    final_blend = HERE / 'CH01_rig_animations.blend'
    bpy.ops.wm.save_as_mainfile(filepath=str(final_blend))
    manifest = {'signature': signature, 'action': action.name, 'fps': 30,
                'start': start, 'end': end, 'count': end - start + 1,
                'resolution': [opt.width, opt.height], 'final_blend': str(final_blend),
                'root_start': positions[0], 'root_end': positions[-1], 'frames': []}
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    if opt.setup_only:
        return
    frames = [int(v) for v in opt.frames.split(',')] if opt.frames else range(start, end + 1)
    began = time.monotonic()
    for number, frame in enumerate(frames, 1):
        if not start <= frame <= end:
            raise ValueError(f'Frame outside action: {frame}')
        target = opt.output / f'{frame:06d}.png'
        if not (opt.resume and target.is_file()):
            scene.frame_set(frame)
            scene.render.filepath = str(target)
            bpy.ops.render.render(write_still=True)
        manifest['frames'].append(frame)
        if number % 15 == 0 or opt.frames:
            manifest['elapsed_seconds'] = time.monotonic() - began
            manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
            print(f'CH01_RENDER {number}/{len(frames)} frame={frame} elapsed={time.monotonic()-began:.1f}s', flush=True)
    manifest['elapsed_seconds'] = time.monotonic() - began
    manifest['complete'] = True
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
