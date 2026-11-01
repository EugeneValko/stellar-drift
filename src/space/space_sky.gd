class_name SpaceSky
extends WorldEnvironment
## WorldEnvironment that owns the procedural space sky.
##
## On ready it bakes the expensive low-frequency backdrop (Milky Way, dust lanes, nebulae, hero
## galaxy, faint star dust) into a 3x2 equi-angular cube atlas through an HDR SubViewport, then
## binds it to the sky material (`baked_sky`). Resolved stars stay per-pixel in the sky shader
## so they are always crisp. Call `rebake()` after changing backdrop uniforms at runtime.
##
## Quality knob: `face_size` (512 low / 1024 medium / 1536 high). VRAM = 3*2*face^2*8 bytes
## (RGBA16F): 12.6 MB / 50 MB / 113 MB. The bake is a one-off cost (a few ms on a desktop GPU).
## `Capture.args["sky_face"]` overrides face_size (fast previews: --sky_face=512).

const BAKE_SHADER := preload("res://shaders/space_sky_bake.gdshader")

@export_enum("512:512", "768:768", "1024:1024", "1536:1536", "2048:2048") var face_size: int = 1024
## When false the sky shader evaluates the backdrop live per pixel (slow; for debugging).
@export var bake_on_ready := true

var _viewport: SubViewport
var _version := 0.0


func _ready() -> void:
	if Capture.args.has("sky_face"):
		face_size = int(Capture.args["sky_face"])
	if bake_on_ready:
		rebake()


func get_sky_material() -> ShaderMaterial:
	if environment == null or environment.sky == null:
		return null
	return environment.sky.sky_material as ShaderMaterial


## (Re)bakes the backdrop atlas from the current sky-material uniforms.
func rebake() -> void:
	var sky_mat := get_sky_material()
	if sky_mat == null:
		push_warning("SpaceSky: environment has no ShaderMaterial sky")
		return
	if _viewport:
		_viewport.queue_free()
	_viewport = SubViewport.new()
	_viewport.name = "SkyBake"
	_viewport.size = Vector2i(3 * face_size, 2 * face_size)
	_viewport.use_hdr_2d = true
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	var bake_mat := ShaderMaterial.new()
	bake_mat.shader = BAKE_SHADER
	# Single source of truth: copy every uniform explicitly set on the sky material.
	for u: Dictionary in BAKE_SHADER.get_shader_uniform_list():
		var uname: String = u["name"]
		var v: Variant = sky_mat.get_shader_parameter(uname)
		if v != null:
			bake_mat.set_shader_parameter(uname, v)
	bake_mat.set_shader_parameter("face_size", float(face_size))

	var rect := ColorRect.new()
	rect.size = Vector2(_viewport.size)
	rect.material = bake_mat
	_viewport.add_child(rect)
	add_child(_viewport)

	sky_mat.set_shader_parameter("baked_sky", _viewport.get_texture())
	sky_mat.set_shader_parameter("baked_face_size", float(face_size))
	sky_mat.set_shader_parameter("use_baked", true)
	# Nudge the radiance cubemap to refresh once the bake has actually been rendered.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	_version += 1.0
	sky_mat.set_shader_parameter("bake_version", _version)
	if Capture.args.has("dump_sky"):
		_dump_atlas(String(Capture.args["dump_sky"]))


## Debug: writes the raw RGBAH atlas (<path>.bin, float16) for tools/sky_preview.py.
func _dump_atlas(path: String) -> void:
	var img := _viewport.get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGBAH:
		img.convert(Image.FORMAT_RGBAH)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(img.get_data())
	f.close()
	print("[sky] dumped atlas ", img.get_size(), " -> ", path)
