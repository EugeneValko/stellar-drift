extends SceneTree
## Terrain generator benchmark + height statistics.
##   godot --headless -s tools/dev/bench_terrain.gd -- res://src/planets/presets/terra_nova.tres

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var path: String = a[0] if a.size() > 0 else "res://src/planets/presets/terra_nova.tres"
	var cfg: PlanetConfig = load(path)
	var gen := TerrainGenerator.new(cfg)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var hs: Array[float] = []
	var land := 0
	var t := Time.get_ticks_usec()
	for i in 4000:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var h := gen.get_height(d)
		hs.append(h)
		if h > cfg.get_base_level():
			land += 1
	var per := float(Time.get_ticks_usec() - t) / 4000.0
	hs.sort()
	print("%s: height min %.0f p10 %.0f p50 %.0f p90 %.0f p99 %.0f max %.0f | land %.2f | get_height %.1f us" % [
		cfg.planet_name, hs[0], hs[400], hs[2000], hs[3600], hs[3960], hs[3999], land / 4000.0, per])
	t = Time.get_ticks_usec()
	for i in 10:
		gen.build_chunk(i % 6, -1.0 + i * 0.1, -0.5, 0.0005, true, 2.0)
	print("  finest chunk build avg %.1f ms" % (float(Time.get_ticks_usec() - t) / 10000.0))
	t = Time.get_ticks_usec()
	for i in 6:
		gen.build_chunk(i, -1.0, -1.0, 2.0, false, 2.0)
	print("  root chunk build avg %.1f ms" % (float(Time.get_ticks_usec() - t) / 6000.0))
	quit()
