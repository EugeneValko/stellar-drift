extends SceneTree
## Headless check of height-field continuity (crater / volcano cell borders).
## godot --headless -s tools/dev/terrain_continuity.gd -- [preset=selene,nyx] [lines=40] [len=3000] [step=0.1]
## Walks random great-circle segments at `step` m and reports the largest change of the height
## step between neighbouring samples (a micro-cliff is a jump far above the local slope).

func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var presets: Array = String(args.get("preset", "selene,nyx,vex,ignis")).split(",")
	var lines := int(args.get("lines", "40"))
	var seg_len := float(args.get("len", "3000"))
	var step := float(args.get("step", "0.1"))
	for pn: String in presets:
		var cfg: PlanetConfig = (load("res://src/planets/presets/%s.tres" % pn) as PlanetConfig).duplicate()
		for k: String in args:   # property overrides, e.g. crater_layers=0
			if k in cfg and k != "preset":
				cfg.set(k, str_to_var(args[k]))
		var gen := TerrainGenerator.new(cfg)
		var rng := RandomNumberGenerator.new()
		rng.seed = 1234
		var worst := 0.0
		var max_jump := 0.0
		var over := 0
		var wa := Vector3.ZERO
		var wb := Vector3.ZERO
		var n_steps := int(seg_len / step)
		for l in lines:
			var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			var t := d.cross(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))).normalized()
			var prev := gen.get_height(d)
			var prev_d := d
			var prev_jump := 0.0
			for k in range(1, n_steps):
				var a := float(k) * step / cfg.radius
				var dd := (d * cos(a) + t * sin(a)).normalized()
				var h := gen.get_height(dd)
				var jump := absf(h - prev)
				max_jump = maxf(max_jump, jump)
				var excess := absf(jump - prev_jump)
				if k > 1:
					if excess > worst:
						wa = prev_d
						wb = dd
					worst = maxf(worst, excess)
					if excess > 0.15:
						over += 1
				prev_jump = jump
				prev = h
				prev_d = dd
		print("[continuity] %s: %d lines x %.0f m @ %.2f m: max step %.3f m, worst step change %.3f m, cliffs (>0.15 m) %d" % [
			pn, lines, seg_len, step, max_jump, worst, over])
		if args.has("debug"):
			for p: Vector3 in [wa, wb]:
				var q := p * cfg.radius
				var line := "  h=%.3f" % gen.get_height(p)
				for i in gen.n_crater_d.size():
					line += " | L%d cv=%.4f d=%.4f gap=%.4f" % [i, gen.n_crater_v[i].get_noise_3d(q.x, q.y, q.z),
						gen.n_crater_d[i].get_noise_3d(q.x, q.y, q.z) + 1.0, gen.n_crater_g[i].get_noise_3d(q.x, q.y, q.z) + 1.0]
				print(line)
	quit()
