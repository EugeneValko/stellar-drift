extends SceneTree
## GPU/CPU frame-time benchmark on a real GPU (Windows local render machine).
##   godot --path . --resolution 1920x1080 --fullscreen --disable-vsync -s tools/dev/gpu_bench.gd -- \
##       --scene=res://scenes/main.tscn --cam=terra_low [--warm=300] [--frames=300] [--label=x] [--snap=out.png]
## Loads the scene (autoload Capture parses the same user args, so scenes apply --cam themselves),
## waits `warm` frames (LOD / scatter / weather bake), then samples `frames` frames of
## viewport GPU time, viewport CPU time and wall-clock frame time. Prints one machine-readable line:
##   [gpubench] label | fps avg | gpu avg/p95 ms | cpu avg ms | frame avg/p95 ms | draw calls | prims
## --snap=<png> also saves the last frame (same frame the timing describes).

var _args: Dictionary = {}
var _frame := 0
var _warm := 300
var _count := 300
var _gpu: Array[float] = []
var _cpu: Array[float] = []
var _dt: Array[float] = []
var _last_us := 0
var _draws := 0.0
var _prims := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	_warm = int(_args.get("warm", "300"))
	_count = int(_args.get("frames", "300"))
	change_scene_to_file(_args.get("scene", "res://scenes/main.tscn"))
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)


func _process(_delta: float) -> bool:
	_frame += 1
	var now := Time.get_ticks_usec()
	if _frame > _warm and _frame <= _warm + _count:
		var vp := root.get_viewport_rid()
		_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
		_dt.append((now - _last_us) / 1000.0)
		_draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		_prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	_last_us = now
	if _frame == _warm + _count:
		_report()
	return false


func _report() -> void:
	var label: String = _args.get("label", "%s %s" % [String(_args.get("scene", "main")).get_file().get_basename(), _args.get("cam", "-")])
	var line := "[gpubench] %s | fps %.1f | gpu %.2f / p95 %.2f ms | cpu %.2f ms | frame %.2f / p95 %.2f ms | draws %d | prims %.2fM" % [
		label, 1000.0 / _avg(_dt), _avg(_gpu), _pct(_gpu, 0.95), _avg(_cpu), _avg(_dt), _pct(_dt, 0.95),
		int(_draws / _count), _prims / _count / 1.0e6]
	print(line)
	if _args.has("snap"):
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var path: String = _args["snap"]
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		img.save_png(path)
	quit()


func _avg(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)


func _pct(a: Array[float], p: float) -> float:
	var b := a.duplicate()
	b.sort()
	return b[clampi(int(b.size() * p), 0, b.size() - 1)] if b.size() > 0 else 0.0
