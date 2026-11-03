"""Render selected authored-motion poses without changing any Blender file."""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parent


def main():
    argv = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument('--frames', default='1,52,58,67,79,190,250,280')
    parser.add_argument('--view', choices=('front', 'side'), default='front')
    parser.add_argument('--action', default='Demo')
    parser.add_argument('--out', type=Path, default=ROOT/'motion_qa')
    opts = parser.parse_args(argv)
    bpy.ops.wm.open_mainfile(filepath=str(ROOT/'animated.blend'))
    arm = bpy.data.objects['ARM_CH01']
    action = bpy.data.actions[opts.action]
    arm.animation_data.action = action
    arm.animation_data.action_slot = action.slots[0]
    spec = importlib.util.spec_from_file_location('ch01_studio', ROOT/'render_demo.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    scene = bpy.context.scene
    first, last = (round(value) for value in action.frame_range)
    module.studio(scene, arm, first, last, 12)
    scene.render.resolution_x, scene.render.resolution_y = 960, 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGB'
    if hasattr(scene.render, 'use_motion_blur'):
        scene.render.use_motion_blur = False
    opts.out.mkdir(parents=True, exist_ok=True)
    camera = scene.camera
    if opts.view == 'side':
        camera.animation_data_clear()
    for frame in (int(value) for value in opts.frames.split(',')):
        scene.frame_set(frame)
        if opts.view == 'side':
            evaluated = arm.evaluated_get(bpy.context.evaluated_depsgraph_get())
            root = evaluated.matrix_world @ evaluated.pose.bones['root'].matrix.translation
            camera.location = root+Vector((-4.0, -.05, 1.1))
            camera.rotation_euler = (root+Vector((0, 0, .9))-camera.location).to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = str(opts.out/f'{opts.action}_{opts.view}_{frame:04d}.png')
        bpy.ops.render.render(write_still=True)
        print('MOTION_QA '+scene.render.filepath, flush=True)


if __name__ == '__main__':
    main()
