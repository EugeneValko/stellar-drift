extends SceneTree
## Land-cover statistics of a planet from ScatterBiome (CPU mirror of the terrain shader biomes).
##   godot --headless -s tools/dev/biome_stats.gd -- [preset=terra_nova] [n=4000]
## Prints, over land samples (fibonacci sphere), the share of each attribute > 0.5 and its mean,
## plus height statistics (river valleys, cliffs, beaches).

func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var preset: String = args.get("preset", "terra_nova")
	var n := int(args.get("n", "4000"))
	var cfg: PlanetConfig = load("res://src/planets/presets/%s.tres" % preset)
	var gen := TerrainGenerator.new(cfg)
	var bio := ScatterBiome.new(gen, cfg)
	var share := {}
	var mean := {}
	for k in ScatterBiome.ATTRS:
		share[k] = 0
		mean[k] = 0.0
	var land := 0
	var ga := PI * (3.0 - sqrt(5.0))
	var t0 := Time.get_ticks_msec()
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
		var r := sqrt(1.0 - y * y)
		var d := Vector3(cos(ga * i) * r, y, sin(ga * i) * r)
		var b := bio.evaluate(d)
		if cfg.has_ocean_surface() and b["height"] < 0.0:
			continue
		land += 1
		for k in ScatterBiome.ATTRS:
			var v: float = b[k]
			mean[k] += v
			if v > 0.5:
				share[k] += 1
	print("[biome] %s: %d samples, land %.1f %% (%d ms)" % [preset, n, 100.0 * land / n, Time.get_ticks_msec() - t0])
	for k in ScatterBiome.ATTRS:
		print("  %-8s >0.5: %5.1f %%   mean %.3f" % [k, 100.0 * share[k] / maxi(land, 1), mean[k] / maxi(land, 1)])
	quit()
