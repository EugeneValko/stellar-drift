extends Node
## Offscreen screenshot helper for agent-driven development (autoload "Capture").
##
## Command-line user args (after `--`):
##   --shot=<file.png>            single screenshot, then quit
##   --shots=a,b,c --outdir=<d>   several camera presets in one run -> <d>/<preset>.png
##   --warmup=<frames>            frames to wait before each capture (default 30)
##   --res=1920x1080              window/viewport size
##   --offscreen                  borderless window of exactly --res (default 1920x1080) parked
##                                outside the desktop: renders normally, never covers the user's
##                                windows (tools/shot.ps1 and movie.ps1 use it unless -Front)
##   any other --key=value        readable by scenes via Capture.args
##
## Scenes that support camera presets add a node to group "capture_target"
## implementing `apply_capture_preset(name: String) -> void`.
## Presets every scene should try to offer are listed in docs/TOOLS.md.

signal preset_applied(name: String)

var args: Dictionary = {}
var active := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if args.has("res"):
		var wh: PackedStringArray = String(args["res"]).split("x")
		get_window().size = Vector2i(int(wh[0]), int(wh[1]))
	if args.has("offscreen"):
		_park_offscreen()
	if args.has("shot") or args.has("shots"):
		active = true
		_run.call_deferred()

## Borderless window left of every screen, rendering at exactly `sz`. Rendering and viewport
## captures work as on screen.
func _park_offscreen() -> void:
	var w := get_window()
	var sz := Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width")),
		int(ProjectSettings.get_setting("display/window/size/viewport_height")))
	if args.has("res"):
		var wh: PackedStringArray = String(args["res"]).split("x")
		sz = Vector2i(int(wh[0]), int(wh[1]))
	w.mode = Window.MODE_WINDOWED
	w.borderless = true
	w.unfocusable = true
	var left := 0
	for i in DisplayServer.get_screen_count():
		left = mini(left, DisplayServer.screen_get_position(i).x)
	w.size = sz
	w.position = Vector2i(left - sz.x - 200, 0)
	# should Windows still clamp the window to the work area: render the root viewport at exactly
	# `sz` whatever the window size (same image and UI layout as fullscreen)
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	w.content_scale_size = sz


func get_preset() -> String:
	return args.get("cam", "")

func _wait(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame

func _apply(preset: String) -> void:
	for n in get_tree().get_nodes_in_group("capture_target"):
		if n.has_method("apply_capture_preset"):
			n.apply_capture_preset(preset)
	preset_applied.emit(preset)

func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("[capture] saved ", path, " ", img.get_size())

func _run() -> void:
	var warm := int(args.get("warmup", "30"))
	if args.has("shots"):
		var outdir: String = args.get("outdir", "user://shots")
		for p in String(args["shots"]).split(","):
			_apply(p)
			await _wait(warm)
			await _save(outdir.path_join(p + ".png"))
	else:
		if args.has("cam"):
			_apply(args["cam"])
		await _wait(warm)
		await _save(args["shot"])
	get_tree().quit()
