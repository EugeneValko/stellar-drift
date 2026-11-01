extends SceneTree
## Headless LOD statistics: node count per level for a focus at a given altitude.
##   godot --headless -s tools/dev/lod_stats.gd -- <preset.tres> <altitude_m>

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var path: String = a[0] if a.size() > 0 else "res://src/planets/presets/terra_nova.tres"
	var alt: float = float(a[1]) if a.size() > 1 else 500.0
	var cfg: PlanetConfig = load(path)
	var t := PlanetTerrain.new()
	root.add_child(t)
	t.setup(cfg, StandardMaterial3D.new())
	var d := Vector3(0.3, 0.2, 0.9).normalized()
	if a.size() > 2 and a[2] == "peak":
		var best := -1e9
		for i in 4000:
			var y := 1.0 - (i + 0.5) / 2000.0
			var rr := sqrt(1.0 - y * y)
			var dd := Vector3(cos(2.39996 * i) * rr, y, sin(2.39996 * i) * rr)
			var h := t.get_height(dd)
			if h > best:
				best = h
				d = dd
	t.set_focus(d * (cfg.radius + t.get_height(d) + alt))
	t._update_tree()
	var per := {}
	for r in t._roots:
		_count(r, per)
	print("alt %.0f: nodes %d, leaves per level %s" % [alt, t._node_count, str(per)])
	if a.size() > 4:
		var tn := d.cross(Vector3.UP).normalized()
		var line := ""
		for k in range(-10, 11):
			var dd := (d + tn * (k * 20.0 / cfg.radius)).normalized()
			line += "%.0f " % t.get_height(dd)
		print("profile 20m step: ", line)
	if a.size() > 3:
		var rb: PlanetTerrain.ChunkNode = t._roots[0]
		for r in t._roots:
			if r.center.normalized().dot(d) > rb.center.normalized().dot(d):
				rb = r
		_deepest(t, rb)
	t.clear()
	quit()


func _count(n: PlanetTerrain.ChunkNode, per: Dictionary) -> void:
	if n.children.is_empty():
		per[n.level] = per.get(n.level, 0) + 1
	for c in n.children:
		_count(c, per)


func _deepest(t: PlanetTerrain, n: PlanetTerrain.ChunkNode) -> void:
	print("  L%d edge %.1f dist %.1f horiz %.1f half_range %.1f below_hz %s" % [n.level, n.edge_m, t._distance_to(n), n.horiz, n.half_range, str(t._below_horizon(n))])
	var best: PlanetTerrain.ChunkNode = null
	var bd := 1e18
	for c in n.children:
		var dd := c.center.distance_to(t.focus)
		if dd < bd:
			bd = dd
			best = c
	if best:
		_deepest(t, best)
