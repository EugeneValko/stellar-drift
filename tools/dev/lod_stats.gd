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
	t.set_focus(d * (cfg.radius + t.get_height(d) + alt))
	t._update_tree()
	var per := {}
	for r in t._roots:
		_count(r, per)
	print("alt %.0f: nodes %d, leaves per level %s" % [alt, t._node_count, str(per)])
	t.clear()
	quit()


func _count(n: PlanetTerrain.ChunkNode, per: Dictionary) -> void:
	if n.children.is_empty():
		per[n.level] = per.get(n.level, 0) + 1
	for c in n.children:
		_count(c, per)
