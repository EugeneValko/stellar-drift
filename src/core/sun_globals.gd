class_name SunGlobals
## Global shader uniforms describing the star light (declared in project.godot [shader_globals]).
##
##   sun_direction : vec3  world-space unit vector pointing TOWARD the sun
##   sun_color     : color linear RGB color of the unattenuated star light (outside atmospheres)
##   sun_intensity : float scale; a white lambert surface facing the sun has radiance
##                         sun_color * sun_intensity (same convention as DirectionalLight3D energy)
##
## All planet shaders (atmosphere, clouds, ocean, gas giant, rings) read these, so call
## `SunGlobals.set_sun()` (or `sync_from_light()`) whenever the star direction changes,
## e.g. every frame from the system/star controller.
extends RefCounted

const P_DIRECTION := &"sun_direction"
const P_COLOR := &"sun_color"
const P_INTENSITY := &"sun_intensity"


static func set_sun(direction_to_sun: Vector3, color: Color = Color(1, 0.96, 0.9), intensity: float = 1.6) -> void:
	RenderingServer.global_shader_parameter_set(P_DIRECTION, direction_to_sun.normalized())
	RenderingServer.global_shader_parameter_set(P_COLOR, color)
	RenderingServer.global_shader_parameter_set(P_INTENSITY, intensity)


static func set_direction(direction_to_sun: Vector3) -> void:
	RenderingServer.global_shader_parameter_set(P_DIRECTION, direction_to_sun.normalized())


## Copies direction from a DirectionalLight3D (light shines along its -Z, so the sun is at +Z).
## Color/intensity are taken from the light unless overridden (pass a negative intensity to keep).
static func sync_from_light(light: DirectionalLight3D, color_override: Variant = null, intensity_override: float = -1.0) -> void:
	var dir := light.global_transform.basis.z.normalized()
	var col: Color = light.light_color if color_override == null else color_override
	var inten := light.light_energy if intensity_override < 0.0 else intensity_override
	set_sun(dir, col, inten)


## Points a DirectionalLight3D so that it shines from `direction_to_sun`.
static func aim_light(light: DirectionalLight3D, direction_to_sun: Vector3) -> void:
	var z := direction_to_sun.normalized()
	var up := Vector3.UP if absf(z.y) < 0.99 else Vector3.RIGHT
	var x := up.cross(z).normalized()
	var y := z.cross(x)
	light.global_transform = Transform3D(Basis(x, y, z), light.global_transform.origin)


## Raymarch jitter offset per frame (global `sd_temporal`): on with TAA, which then averages the
## cloud / atmosphere grain over frames; off (static pattern) otherwise. Call once per frame.
static var temporal_jitter := false
static var _frame := 0
static var _temporal_applied := -1.0


static func advance_frame() -> void:
	var v := 0.0
	if temporal_jitter:
		_frame = (_frame + 1) % 4096
		v = fposmod(float(_frame) * 0.6180339887, 1.0)
	if v != _temporal_applied:
		_temporal_applied = v
		RenderingServer.global_shader_parameter_set(&"sd_temporal", v)


static func get_direction() -> Vector3:
	return RenderingServer.global_shader_parameter_get(P_DIRECTION)
