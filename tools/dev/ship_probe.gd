extends SceneTree
## Prints ShipVisual markers, part transforms and mesh AABBs (collision-shape authoring aid).
##   godot --headless -s tools/dev/ship_probe.gd


func _init() -> void:
	var vis: Node3D = load("res://scenes/ship/ship_visual.tscn").instantiate()
	root.add_child(vis)
	await process_frame
	_walk(vis, 0)
	quit()


func _walk(n: Node, depth: int) -> void:
	for c in n.get_children():
		var n3 := c as Node3D
		if n3 and not String(c.name).begins_with("Plume") and not (c is OmniLight3D):
			var line := "%s%s %s pos=%s" % ["  ".repeat(depth), c.name, c.get_class(), str(n3.global_position)]
			if c is MeshInstance3D and (c as MeshInstance3D).mesh:
				var aabb: AABB = n3.global_transform * (c as MeshInstance3D).mesh.get_aabb()
				line += " aabb=" + str(aabb)
			print(line)
		_walk(c, depth + 1)
