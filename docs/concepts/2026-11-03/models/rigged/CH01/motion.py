"""Authored CH01 walk/wave. Run with Blender 5.2 --background --python motion.py.

Reads rig.blend and saves a separate animated.blend. No source geometry, rig file,
materials or weights are changed. Coordinates and control names follow rig_spec.json.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Euler, Quaternion, Vector


ROOT = Path(__file__).resolve().parent
FPS = 30
PERIOD = 1.1
STRIDE = 1.1
STANCE = .60
HALF = STRIDE * STANCE / 2
TOE_OFF_PITCH = 15.
DEMO_LENGTH = 13.4
IDENTITY = Quaternion((1, 0, 0, 0))
FRONT = Vector((0, -1, 0))
UP = Vector((0, 0, 1))
XAXIS = Vector((1, 0, 0))
REST = {}
WORLD = {}
ARM = None
WALK_DROP = -.055
ANIMATED = []


def clamp(value, low=0., high=1.):
    return max(low, min(high, value))


def ease(value):
    u = clamp(value)
    return u*u*u*(10+u*(-15+6*u))


def ease_integral(value):
    u = clamp(value)
    return 2.5*u**4-3*u**5+u**6


def mix(a, b, amount):
    return a*(1-amount)+b*amount


def deg(value):
    return math.radians(value)


def rotation(x=0, y=0, z=0):
    return Euler((deg(x), deg(y), deg(z)), 'XYZ').to_quaternion()


def profile(phase, points):
    for (a, x), (b, y) in zip(points, points[1:]):
        if phase <= b:
            return mix(x, y, ease((phase-a)/(b-a)))
    return points[-1][1]


def hermite(a, b, ma, mb, u):
    return (2*u**3-3*u*u+1)*a+(u**3-2*u*u+u)*ma+(-2*u**3+3*u*u)*b+(u**3-u*u)*mb


def reset_pose():
    WORLD.clear()
    for bone in ARM.pose.bones:
        bone.location = (0, 0, 0)
        bone.rotation_mode = 'QUATERNION'
        bone.rotation_quaternion = IDENTITY
        bone.scale = (1, 1, 1)


def pose_world_rotation(name, desired):
    """Solve local FK basis from desired armature-space orientation, with no guessing of roll."""
    bone = ARM.pose.bones[name]
    rest = REST[name]
    parent = bone.parent
    parent_rest = REST[parent.name]['q'] if parent else IDENTITY
    parent_world = WORLD.get(parent.name, parent_rest) if parent else IDENTITY
    local_rest = parent_rest.inverted() @ rest['q']
    basis = local_rest.inverted() @ parent_world.inverted() @ desired
    bone.rotation_quaternion = basis.normalized()
    WORLD[name] = desired.normalized()


def pose_delta(name, delta):
    pose_world_rotation(name, delta @ REST[name]['q'])


def aim(name, direction, secondary=FRONT, twist=0.):
    """Aim rest bone Y, then use an explicit secondary direction to control twist."""
    desired = Vector(direction).normalized()
    rest_dir = REST[name]['direction']
    swing = rest_dir.rotation_difference(desired)
    q = swing @ REST[name]['q']
    current = swing @ FRONT
    current -= desired*current.dot(desired)
    target = Vector(secondary)-desired*Vector(secondary).dot(desired)
    if current.length > 1e-6 and target.length > 1e-6:
        current.normalize()
        target.normalize()
        angle = math.atan2(desired.dot(current.cross(target)), current.dot(target))
        q = Quaternion(desired, angle) @ q
    pose_world_rotation(name, Quaternion(desired, deg(twist)) @ q)


def set_pelvis_location(delta):
    ARM.pose.bones['pelvis'].location = REST['pelvis']['q'].inverted() @ Vector(delta)


def body(phase=0., amount=0., settle=0., wave_amount=0.):
    theta = 2*math.pi*phase
    yaw = -3.0*math.cos(theta)*amount
    roll = -1.5*math.sin(theta)*amount
    lean = 2.0*amount
    bob = .015*math.cos(4*math.pi*(phase-.28))*amount
    # Slow, small breathing remains below 2 mm and is not an artificial torso bounce.
    breath = .0012*math.sin(settle*2*math.pi/3.6)*(1-amount)
    z = mix(-.003, WALK_DROP, amount)+bob+breath
    shift = .018*math.cos(theta-.6*math.pi)*amount+.020*wave_amount
    set_pelvis_location((shift, 0, z))
    pose_delta('root', IDENTITY)
    pose_delta('pelvis', rotation(lean, roll, yaw))
    pose_delta('spine_01', rotation(lean*.83, roll*.65, yaw*.45))
    pose_delta('spine_02', rotation(lean*.72, roll*.35, -.1*yaw))
    pose_delta('chest', rotation(lean*.6, roll*.15, -.6*yaw+2*wave_amount))
    pose_delta('neck', rotation(.3*amount, 0, .05*yaw))
    pose_delta('head', rotation(.2*amount-.8*wave_amount, 0, -.8*wave_amount))


def arm_side(side, phase=0., walk=0., wave_lift=0., oscillation=0., wrist=0.):
    sign = 1 if side == 'L' else -1
    swing = -15*math.cos(2*math.pi*phase)*walk*sign
    flex = 17+4*max(0, math.sin(deg(swing)))
    upper = Vector((sign*math.sin(deg(10)), -math.sin(deg(swing)), -math.cos(deg(swing))))
    upper.normalize()
    fore = Vector((sign*math.sin(deg(7)), -math.sin(deg(swing+flex)), -math.cos(deg(swing+flex))))
    fore.normalize()
    hand = Vector((sign*math.sin(deg(7)), -math.sin(deg(swing+flex-5)), -math.cos(deg(swing+flex-5))))
    hand.normalize()
    chest_delta = WORLD['chest'] @ REST['chest']['q'].inverted()
    upper, fore, hand = (chest_delta @ vector for vector in (upper, fore, hand))
    front = chest_delta @ FRONT
    # The actual generated GLB has palm-down T-pose gloves (palm normal near -Z),
    # unlike a literal reading of the painted reference. Neutral aim already turns palms inward.
    # Spread the extra greeting turn through the chain, with only 30 degrees at each soft joint.
    upper_twist = fore_twist = hand_twist = 0.
    if side == 'R' and wave_lift:
        raised_upper = Vector((-.90, -.16, -.405)).normalized()
        raised_upper = rotation(0, oscillation*.12, 0) @ raised_upper
        raised_fore = rotation(0, oscillation, 0) @ Vector((.035, -.13, .991)).normalized()
        raised_hand = rotation(4, oscillation+wrist, 0) @ Vector((.035, -.13, .991)).normalized()
        upper = upper.slerp(raised_upper, wave_lift).normalized()
        fore = fore.slerp(raised_fore, wave_lift).normalized()
        hand = hand.slerp(raised_hand, wave_lift).normalized()
        front = front.lerp(FRONT, wave_lift).normalized()
        upper_twist = 30*wave_lift
        fore_twist = 60*wave_lift
        hand_twist = 90*wave_lift
    clav = 'clavicle.'+side
    clav_lift = 2.5*wave_lift if side == 'R' else 0
    pose_world_rotation(clav, chest_delta @ rotation(0, -sign*clav_lift, 0) @ REST[clav]['q'])
    aim('upper_arm.'+side, upper, front, upper_twist)
    aim('forearm.'+side, fore, front, fore_twist)
    aim('hand.'+side, hand, front, hand_twist)


def arms(phase=0., walk=0., lift=0., oscillation=0., wrist=0.):
    arm_side('L', phase, walk)
    arm_side('R', phase, walk, lift, oscillation, wrist)


def ankle_target(side, flat_y=0., swing_z=0., pitch=0.):
    ankle = REST['CTRL_foot.'+side]['head']
    # The contact pivot is anatomical: heel sole on landing, ball joint at toe-off.
    if pitch <= 0:
        pivot = Vector((0, .062, -ankle.z))
    else:
        ball = REST['toe.'+side]['head']
        pivot = Vector((0, ball.y-ankle.y, ball.z-ankle.z))
    q = rotation(pitch, 0, 0)
    correction = pivot-q @ pivot
    desired = ankle+Vector((0, flat_y, swing_z))+correction
    return desired, q


def foot(side, flat_y=0., swing_z=0., pitch=0., toe_pitch=None):
    ankle = REST['CTRL_foot.'+side]['head']
    desired, q = ankle_target(side, flat_y, swing_z, pitch)
    control = ARM.pose.bones['CTRL_foot.'+side]
    control.location = desired-ankle
    control.rotation_quaternion = q
    WORLD[control.name] = q
    if toe_pitch is None:
        toe_pitch = pitch if pitch <= 0 else 0.
    # Foot final orientation is constrained, so explicitly include it as the FK parent.
    WORLD['foot.'+side] = q @ REST['foot.'+side]['q']
    pose_delta('toe.'+side, rotation(toe_pitch, 0, 0))


def gait_values(phase):
    p = phase % 1.
    if p <= STANCE:
        y = -HALF+STRIDE*p
        pitch = profile(p, [(0, -10), (.09, 0), (.40, 0), (.51, 6), (.60, TOE_OFF_PITCH)])
        return y, 0., pitch, None
    else:
        u = (p-STANCE)/(1-STANCE)
        # Equal endpoint derivatives cancel root speed: zero world velocity at contact.
        tangent = STRIDE*(1-STANCE)
        y = hermite(HALF, -HALF, tangent, tangent, u)
        pitch = profile(u, [(0, TOE_OFF_PITCH), (.24, 5), (.68, -5), (1, -10)])
        # Round-ended clearance arc, 8 cm above the blended endpoint ankle heights.
        lift = .080*16*u*u*(1-u)*(1-u)
        toe_pitch = pitch*ease(u/.20) if u < .20 else pitch
        return y, lift, pitch, toe_pitch


def cycle_foot(side, phase):
    foot(side, *gait_values(phase))


def standing(time=0., wave=None):
    wave = wave or (0., 0., 0.)
    body(settle=time, wave_amount=wave[0])
    arms(lift=wave[0], oscillation=wave[1], wrist=wave[2])
    for side in ('L', 'R'):
        foot(side)


def wave_state(time):
    # Stationary action: .3 s anticipation, .9 s lift, 2.6 s wave, 1.1 s lower.
    lift = ease((time-.3)/.9)*(1-ease((time-3.8)/1.1))
    u = (time-1.2)/2.6
    window = ease(u/.10)*ease((1-u)/.10)
    phase = 2*math.pi*2.75*u
    oscillation = 11*math.sin(phase)*window if 0 <= u <= 1 else 0.
    wrist = 6*math.sin(phase-.45)*window if 0 <= u <= 1 else 0.
    return lift, oscillation, wrist


def walk_pose(time):
    phase = time/PERIOD
    body(phase, 1., time)
    arms(phase, 1.)
    cycle_foot('L', phase)
    cycle_foot('R', phase+.5)


def wave_pose(time):
    standing(time, wave_state(time))


def demo_pose(time):
    start, steady, stop, wave_start = .7, 1.5, 5.9, 7.1
    if time < start:
        standing(time)
        return
    if time < steady:
        u = clamp((time-start)/(steady-start))
        # Integrate a smooth speed ramp: monotonic root, zero acceleration at joins.
        root_distance = .66*ease_integral((u*.8-.14)/.66)
        ARM.pose.bones['root'].location.y = -root_distance
        amount = ease(u)
        phase = .1+(root_distance-.33)/STRIDE
        body(phase, amount, time)
        arms(phase, amount)
        # Left makes a short first step; right stays anchored and rolls onto the ball.
        left_move = ease((u-.10)/.80)
        left_y = -.55*left_move+root_distance
        left_lift = .080*math.sin(math.pi*clamp((u-.10)/.78))**2 if .10 < u < .88 else 0
        left_pitch = profile(u, [(0, 0), (.15, 7), (.44, 0), (.78, -10), (.90, -10), (1, 0)])
        foot('L', left_y, left_lift, left_pitch, left_pitch)
        foot('R', root_distance, 0, TOE_OFF_PITCH*ease((u-.72)/.28))
        return
    if time < stop:
        phase = .1+(time-steady)/PERIOD
        ARM.pose.bones['root'].location.y = -.33-(time-steady)
        body(phase, 1., time)
        arms(phase, 1.)
        cycle_foot('L', phase)
        cycle_foot('R', phase+.5)
        return
    if time < 6.7:
        u = clamp((time-stop)/.8)
        stop_progress = clamp(u*.8/.44)
        advance = .44*(stop_progress-ease_integral(stop_progress))
        distance = 4.73+advance
        ARM.pose.bones['root'].location.y = -distance
        amount = 1-ease(u)
        phase = .1+advance/STRIDE
        body(phase, amount, time)
        arms(phase, amount)
        foot('L', distance-4.95)
        right_move = ease(u/.82)
        right_y = mix(-4.4, -4.95, right_move)+distance
        right_lift = .08*math.sin(math.pi*clamp(u/.80))**2 if u < .8 else 0
        right_pitch = profile(u, [(0, TOE_OFF_PITCH), (.20, 6), (.55, -6), (.78, -10), (.86, -10), (1, 0)])
        foot('R', right_y, right_lift, right_pitch, right_pitch*ease(u/.18))
        return
    ARM.pose.bones['root'].location.y = -4.95
    standing(time, wave_state(time-wave_start) if time >= wave_start else None)


def action_curves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                yield from bag.fcurves


def smooth_curves(action, loop=False):
    for curve in action_curves(action):
        points = curve.keyframe_points
        count = len(points)
        for i, point in enumerate(points):
            if loop and count > 3 and i in {0, count-1}:
                slope = (points[1].co.y-points[-2].co.y)/2
            elif i == 0:
                slope = points[1].co.y-point.co.y
            elif i == count-1:
                slope = point.co.y-points[-2].co.y
            else:
                slope = (points[i+1].co.y-points[i-1].co.y)/2
            point.interpolation = 'BEZIER'
            point.handle_left_type = point.handle_right_type = 'FREE'
            point.handle_left = (point.co.x-1/3, point.co.y-slope/3)
            point.handle_right = (point.co.x+1/3, point.co.y+slope/3)
        if loop:
            curve.modifiers.new('CYCLES')


def create_action(name, duration, pose_function, loop=False):
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    ARM.animation_data.action = action
    previous = {}
    for frame in range(1, round(duration*FPS)+2):
        time = (frame-1)/FPS
        reset_pose()
        pose_function(time)
        for name in ANIMATED:
            bone = ARM.pose.bones[name]
            q = bone.rotation_quaternion.copy()
            if name in previous and previous[name].dot(q) < 0:
                q.negate()
                bone.rotation_quaternion = q
            previous[name] = q
            bone.keyframe_insert('rotation_quaternion', frame=frame, group=name)
            if name == 'root' or name == 'pelvis' or name.startswith('CTRL_'):
                bone.keyframe_insert('location', frame=frame, group=name)
    smooth_curves(action, loop)
    action['description'] = {'Walk_Cycle': 'In-place human 1g walk, 60% stance, heel/toe roll, 109 steps/min',
                             'Wave': 'Stationary friendly wave with preparation, wrist lag and settle',
                             'Demo': 'Root-motion start, four full steady cycles, stop, friendly wave'}[action.name]
    print(f'MOTION action {action.name}: {len(list(action_curves(action)))} curves, {round(duration*FPS)+1} frames', flush=True)
    return action


def main():
    global ARM, REST, ANIMATED, WALK_DROP
    args = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument('--rig', type=Path, default=ROOT/'rig.blend')
    parser.add_argument('--out', type=Path, default=ROOT/'animated.blend')
    opts = parser.parse_args(args)
    if opts.rig.resolve() == opts.out.resolve():
        raise RuntimeError('The output must not overwrite rig.blend')
    bpy.ops.wm.open_mainfile(filepath=str(opts.rig.resolve()))
    ARM = bpy.data.objects.get('ARM_CH01')
    if not ARM or ARM.type != 'ARMATURE':
        raise RuntimeError('Expected ARM_CH01 armature')
    required = ['root', 'pelvis', 'spine_01', 'spine_02', 'chest', 'neck', 'head']
    required += [part+'.'+side for side in ('L', 'R') for part in
                 ('clavicle', 'upper_arm', 'forearm', 'hand', 'thigh', 'shin', 'foot', 'toe', 'CTRL_foot', 'CTRL_knee')]
    missing = [name for name in required if name not in ARM.pose.bones]
    if missing:
        raise RuntimeError('Missing agreed rig bones: '+', '.join(missing))
    REST = {bone.name: {'head': bone.head_local.copy(), 'tail': bone.tail_local.copy(),
                       'q': bone.matrix_local.to_quaternion(),
                       'direction': (bone.tail_local-bone.head_local).normalized()}
            for bone in ARM.data.bones}
    # Keep contact poses away from full extension with the actual limb proportions.
    safety_drops = []
    for side in ('L', 'R'):
        hip = REST['thigh.'+side]['head']
        ankle = REST['CTRL_foot.'+side]['head']
        length = ARM.data.bones['thigh.'+side].length+ARM.data.bones['shin.'+side].length
        for sample in range(121):
            phase = sample/200
            y, z, pitch, _ = gait_values(phase)
            target, _ = ankle_target(side, y, z, pitch)
            horizontal_sq = (hip.x-target.x)**2+(abs(hip.y-target.y)+.006)**2
            max_vertical = math.sqrt(max(.01, (length*.992)**2-horizontal_sq))
            bob = .015*math.cos(4*math.pi*(phase-.28))
            safety_drops.append(target.z+max_vertical-hip.z-bob-.002)
    WALK_DROP = min(-.035, min(safety_drops))
    ANIMATED = [name for name in required if not name.startswith(('thigh.', 'shin.', 'foot.'))]
    ARM.animation_data_create()
    for track in list(ARM.animation_data.nla_tracks):
        ARM.animation_data.nla_tracks.remove(track)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.frame_start = 1
    scene.frame_end = round(DEMO_LENGTH*FPS)+1
    scene.timeline_markers.clear()
    for label, seconds in [('Stand', 0), ('Start', .7), ('Steady walk / 4 cycles', 1.5),
                           ('Stop', 5.9), ('Settle', 6.7), ('Wave preparation', 7.4),
                           ('Wave', 8.3), ('Lower arm', 10.9), ('End settle', 12.0)]:
        scene.timeline_markers.new(label, frame=round(seconds*FPS)+1)
    actions = [create_action('Walk_Cycle', PERIOD, walk_pose, True),
               create_action('Wave', 6., wave_pose),
               create_action('Demo', DEMO_LENGTH, demo_pose)]
    ARM.animation_data.action = actions[-1]
    ARM.animation_data.action_slot = actions[-1].slots[0]
    scene.frame_set(1)
    opts.out.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(opts.out.resolve()))
    report = {'fps': FPS, 'walk_period_seconds': PERIOD, 'steps_per_minute': 120/PERIOD,
              'step_length_m': STRIDE/2, 'stance_fraction': STANCE,
              'walk_pelvis_offset_m': WALK_DROP, 'demo_seconds': DEMO_LENGTH,
              'demo_root_distance_m': 4.95, 'actions': [action.name for action in actions],
              'rig_source': str(opts.rig.resolve()), 'output': str(opts.out.resolve()),
              'note': 'Authored control animation. Visual contact/deformation QA and export baking remain separate.'}
    (ROOT/'motion_report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('MOTION saved '+str(opts.out.resolve()), flush=True)


if __name__ == '__main__':
    main()
