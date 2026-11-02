class_name GraphicsSettings
extends RefCounted
## User graphics options (Esc -> Графика), saved in user://settings.cfg [graphics]:
##   aa           TAA (default): the cloud / atmosphere raymarch jitter changes every frame
##                (SunGlobals.temporal_jitter) and TAA averages it -> clean cloud edges, and the
##                atmosphere gets by with fewer steps; slightly softer ground while moving.
##                MSAA 4x / 2x + FXAA: sharpest in motion, static jitter (visible cloud grain);
##                RTX 3060 start meadow: 2x +1.5 ms over TAA, 4x +1.6 ms over 2x;
##   sky_quality  clouds / atmosphere / ocean steps (SolarSystem.set_quality): 1 high, 0 medium.
## Captures and benchmarks (--shot / --cam) keep the defaults so frames stay comparable.

enum AA { MSAA_4X, MSAA_2X, TAA }

const SETTINGS_PATH := "user://settings.cfg"

static var aa := AA.TAA
static var sky_quality := 1
static var _loaded := false


static func load_cfg() -> void:
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	aa = clampi(int(cfg.get_value("graphics", "aa", AA.TAA)), 0, 2) as AA
	sky_quality = clampi(int(cfg.get_value("graphics", "sky_quality", 1)), 0, 1)


static func save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("graphics", "aa", int(aa))
	cfg.set_value("graphics", "sky_quality", sky_quality)
	cfg.save(SETTINGS_PATH)


## Applies the saved options to the game viewport and the star system.
static func apply(vp: Viewport, system: SolarSystem) -> void:
	if not _loaded:
		load_cfg()
	var temporal_before := SunGlobals.temporal_jitter
	apply_aa(vp)
	# the atmosphere step count depends on the temporal jitter (AtmosphereLayer.build_uniforms)
	if system and (system.quality != sky_quality or SunGlobals.temporal_jitter != temporal_before):
		system.set_quality(sky_quality)


static func apply_aa(vp: Viewport) -> void:
	SunGlobals.temporal_jitter = aa == AA.TAA
	if aa == AA.TAA:
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.use_taa = true
	else:
		vp.msaa_3d = Viewport.MSAA_4X if aa == AA.MSAA_4X else Viewport.MSAA_2X
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		vp.use_taa = false
