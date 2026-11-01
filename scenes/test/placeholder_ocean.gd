extends MeshInstance3D
## Trivial stand-in ocean for terrain tests (the real ocean is a separate component).
## Demonstrates the Planet component contract: setup(config) is called before entering the tree.

func setup(cfg: PlanetConfig) -> void:
	name = "PlaceholderOcean"
	var r := cfg.get_ocean_radius()
	visible = r > 0.0
	if r <= 0.0:
		return
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 768
	s.rings = 384
	mesh = s
	var m := StandardMaterial3D.new()
	m.albedo_color = cfg.ocean_color
	m.roughness = 0.08
	m.metallic_specular = 0.6
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.88
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
