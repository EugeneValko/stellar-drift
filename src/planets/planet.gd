class_name Planet
extends Node3D
## Root node of a procedural planet: owns a PlanetConfig, builds the PlanetTerrain and
## hosts optional components (atmosphere, ocean, clouds, vegetation, ...).
##
## Space: the planet centre is this node's origin; everything below it is planet-local,
## so a floating-origin system may move/rotate this node freely.
##
## ## Extension points for components
## - `add_component(node)`: adds `node` under the "Components" child. Before it enters the
##   tree, if the node has `setup(config: PlanetConfig)` it is called; if it has
##   `set_planet(planet: Planet)` that is called too (gives access to `terrain`,
##   `get_height()`, the light, etc.). Signal `component_added(node)` fires afterwards.
## - `component_scenes`: PackedScenes instantiated and added via add_component() on _ready.
## - Components are found later with `get_component(name)` / `get_components()`.
## - Planet-wide uniforms for other shaders: `get_shader_params()`.
## Ocean placement: radius `config.get_ocean_radius()` (0 = none), centred on this node.

signal component_added(node: Node)
signal terrain_ready

@export var config: PlanetConfig
@export var component_scenes: Array[PackedScene] = []
## Terrain follows the viewport camera automatically (disable when the game calls
## `set_focus()` itself, e.g. focus = ship position).
@export var auto_focus_camera := true
@export var build_on_ready := true

var terrain: PlanetTerrain
var terrain_material: ShaderMaterial
var components: Node3D

const TERRAIN_SHADER := preload("res://shaders/planet_terrain.gdshader")


func _ready() -> void:
	components = get_node_or_null("Components") as Node3D
	if components == null:
		components = Node3D.new()
		components.name = "Components"
		add_child(components)
	if build_on_ready and config:
		build()


## (Re)builds terrain + material from `config`. Safe to call again after changing config.
func build() -> void:
	assert(config != null, "Planet.build(): no config")
	if terrain == null:
		terrain = PlanetTerrain.new()
		terrain.name = "Terrain"
		add_child(terrain)
	terrain_material = create_terrain_material(config)
	terrain.auto_focus_camera = auto_focus_camera
	terrain.setup(config, terrain_material)
	for c in components.get_children():
		if c.has_method("setup"):
			c.setup(config)
	for ps in component_scenes:
		if ps:
			add_component(ps.instantiate())
	component_scenes = []
	terrain_ready.emit()


func add_component(node: Node) -> Node:
	if node.has_method("setup"):
		node.setup(config)
	if node.has_method("set_planet"):
		node.set_planet(self)
	components.add_child(node)
	component_added.emit(node)
	return node


func get_component(component_name: String) -> Node:
	return components.get_node_or_null(component_name)


func get_components() -> Array[Node]:
	return components.get_children()


## Focus (camera/ship) in planet-local space; drives LOD + collision.
func set_focus(local_pos: Vector3) -> void:
	terrain.set_focus(local_pos)


func set_focus_global(world_pos: Vector3) -> void:
	terrain.set_focus(to_local(world_pos))


func get_height(dir: Vector3) -> float:
	return terrain.get_height(dir)


func get_surface_point(dir: Vector3) -> Vector3:
	return terrain.get_surface_point(dir)


## Altitude above terrain of a world-space point.
func get_altitude_global(world_pos: Vector3) -> float:
	return terrain.get_altitude(to_local(world_pos))


## Uniform values other planet shaders (ocean, atmosphere) may want.
func get_shader_params() -> Dictionary:
	return {
		"planet_radius": config.radius,
		"ocean_radius": config.get_ocean_radius(),
		"height_amplitude": config.height_amplitude,
		"atmosphere_height": config.atmosphere_height,
		"atmosphere_color": config.atmosphere_color,
	}


static func create_terrain_material(cfg: PlanetConfig) -> ShaderMaterial:
	var tex := TerrainTextures.get_textures()
	var m := ShaderMaterial.new()
	m.shader = TERRAIN_SHADER
	m.set_shader_parameter("planet_type", int(cfg.type))
	m.set_shader_parameter("planet_radius", cfg.radius)
	m.set_shader_parameter("height_amplitude", cfg.height_amplitude)
	m.set_shader_parameter("base_level", cfg.get_base_level())
	m.set_shader_parameter("has_ocean", cfg.has_ocean_surface())
	m.set_shader_parameter("beach_width", cfg.beach_width)
	m.set_shader_parameter("snow_line", cfg.snow_line)
	m.set_shader_parameter("polar_snow", cfg.polar_snow)
	m.set_shader_parameter("strata_strength", cfg.strata_strength)
	m.set_shader_parameter("macro_variation", cfg.macro_variation)
	m.set_shader_parameter("lava_intensity", cfg.lava_intensity)
	for k in ["seabed", "sand", "grass", "forest", "dry", "desert", "rock", "rock2", "snow", "lava"]:
		m.set_shader_parameter("color_" + k, cfg.get("color_" + k))
	m.set_shader_parameter("tex_noise", tex["noise"])
	m.set_shader_parameter("tex_normal", tex["normal"])
	m.set_shader_parameter("tex_rock", tex["rock"])
	return m
