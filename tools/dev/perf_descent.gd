extends SceneTree
## Headless perf test: focus descends from orbit to 2 m above ground over N frames
## (exponential altitude curve, like a landing). Measures main-thread time spent in
## PlanetTerrain._process per frame and how far LOD lags behind.
##   godot --headless -s tools/dev/perf_descent.gd -- <preset.tres> [frames=600]
## Note: headless uses the dummy renderer, so GPU upload cost is not included.

var t: PlanetTerrain
var cfg: PlanetConfig
var frame := 0
var frames := 600
var dir := Vector3(0.3, 0.2, 0.9).normalized()
var times: Array[float] = []
var settle := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	cfg = load(a[0] if a.size() > 0 else "res://src/planets/presets/terra_nova.tres")
	if a.size() > 1:
		frames = int(a[1])
	t = PlanetTerrain.new()
	root.add_child(t)
	t.set_process(false)
	t.setup(cfg, StandardMaterial3D.new())
	var t0 := Time.get_ticks_msec()
	t.set_focus(dir * cfg.radius * 3.0)
	t.build_until_stable()
	print("initial orbit build: %d ms, %s" % [Time.get_ticks_msec() - t0, str(t.get_stats())])


func _process(_dt: float) -> bool:
	var ground := cfg.radius + t.get_height(dir)
	if frame <= frames:
		var k := float(frame) / float(frames)
		var alt := 150000.0 * pow(2.0 / 150000.0, k)
		t.set_focus(dir * (ground + alt))
	var t0 := Time.get_ticks_usec()
	t._process(1.0 / 60.0)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	times.append(ms)
	frame += 1
	if frame > frames:
		if t.is_idle():
			settle = frame - frames
			_report()
			return true
		if frame > frames + 3000:
			print("did not settle")
			_report()
			return true
	OS.delay_msec(int(maxf(16.0 - ms, 0.0)))  # emulate 60 FPS frame pacing
	return false


func _report() -> void:
	var s := times.duplicate()
	s.sort()
	var sum := 0.0
	for x in s:
		sum += x
	print("frames %d | main-thread terrain ms: avg %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f" % [
		s.size(), sum / s.size(), s[s.size() / 2], s[int(s.size() * 0.95)],
		s[int(s.size() * 0.99)], s[s.size() - 1]])
	print("LOD settled %d frames after touchdown; %s" % [settle, str(t.get_stats())])
	t.clear()
