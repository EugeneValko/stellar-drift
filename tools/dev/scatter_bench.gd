extends SceneTree
## Headless PlanetScatter benchmark: full synchronous build at a site + per-layer instance/tri counts,
## then a simulated walk / flight measuring main-thread cost per frame.
##   godot --headless -s tools/dev/scatter_bench.gd -- [planet=terra_nova] [alt=2] [want=forest|meadow|any] [speed=5]
##       [frames=600] [only=layer1,layer2]

func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var key: String = args.get("planet", "terra_nova")
	var alt := float(args.get("alt", "2"))
	var want: String = args.get("want", "forest")
	var speed := float(args.get("speed", "5"))
	var cfg: PlanetConfig = load("res://src/planets/presets/%s.tres" % key)
	var planet: Planet = load("res://scenes/planets/planet.tscn").instantiate()
	planet.config = cfg
	planet.auto_focus_camera = false
	root.add_child(planet)
	await process_frame
	if planet.terrain == null:
		planet._ready()
	var scatter := PlanetScatter.new()
	scatter.verbose = true
	if args.has("only"):
		var rs: ScatterRuleSet = load("res://src/planets/scatter/presets/%s.tres" % key).duplicate()
		var keep: Array[ScatterLayer] = []
		for l in rs.layers:
			if l.name in String(args["only"]).split(","):
				keep.append(l)
		rs.layers = keep
		scatter.rules = rs
	planet.add_component(scatter)
	var bio := ScatterBiome.new(planet.terrain.generator, cfg)
	var d := Vector3(0.3, 0.2, 0.9).normalized()
	var best := -1e9
	var t0 := Time.get_ticks_msec()
	for i in 1500:
		var y := 1.0 - (i + 0.5) / 750.0
		if absf(y) > 0.7:
			continue
		var rr := sqrt(1.0 - y * y)
		var dd := Vector3(cos(2.39996 * i) * rr, y, sin(2.39996 * i) * rr)
		var b := bio.evaluate(dd)
		if cfg.has_ocean_surface() and b["height"] < 5.0:
			continue
		var s := 0.0
		match want:
			"forest": s = b["forest"] - b["slope"]
			"meadow": s = 1.0 - absf(b["forest"] - 0.15) * 3.0 - b["slope"] * 5.0 - b["rock"]
			_: s = -b["slope"]
		if s > best:
			best = s
			d = dd
	print("[bench] site search %d ms, biome %s" % [Time.get_ticks_msec() - t0, str(bio.evaluate(d))])
	var R := cfg.radius
	var pos := d * (R + planet.get_height(d) + alt)
	scatter.set_focus(pos)
	t0 = Time.get_ticks_msec()
	scatter.build_until_stable()
	var st := scatter.get_stats()
	print("[bench] %s alt=%.0f: full build %d ms (%d cells, avg %.2f ms/cell on a worker)" % [key, alt,
		Time.get_ticks_msec() - t0, st["cells_built"], st["avg_cell_ms"]])
	print("[bench] instances=%d tris<=%d patch nodes=%d bodies=%d" % [st["instances"], st["tris_max"],
		st["patch_nodes"], st["bodies"]])
	for k in st["layers"]:
		print("    %-18s %s" % [k, str(st["layers"][k])])
	# moving focus: main-thread time per simulated frame (60 fps)
	var t1 := d.cross(Vector3.UP).normalized()
	var frames := int(args.get("frames", "600"))
	var worst := 0.0
	var total := 0.0
	for f in frames:
		pos = (pos + t1 * speed / 60.0)
		var nd := pos.normalized()
		pos = nd * (R + planet.get_height(nd) + alt)
		scatter.set_focus(pos)
		var ts := Time.get_ticks_usec()
		scatter._process(1.0 / 60.0)
		var ms := (Time.get_ticks_usec() - ts) / 1000.0
		worst = maxf(worst, ms)
		total += ms
		OS.delay_msec(2)
	st = scatter.get_stats()
	print("[bench] moved %.0f m at %.0f m/s: main thread avg %.3f ms, worst %.2f ms, queued %d" % [
		speed * frames / 60.0, speed, total / frames, worst, st["queued"]])
	print("[bench]   max upload %.2f ms, max scan %.2f ms, max dispatch+bodies %.2f ms" % [st["max_upload_ms"],
		st["max_scan_ms"], st["max_dispatch_bodies_ms"]])
	scatter.clear()
	planet.queue_free()
	quit()
