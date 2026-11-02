class_name GameAudio
extends Node
## All game audio (no audio files: every sound is synthesized by Synth on a worker thread while
## the loading screen runs). One node in the main scene; `GameAudio.instance` for UI clicks.
##
## Buses (created at runtime, no bus-layout resource): Master (limiter) <- Music (reverb, soft
## low-pass), SFX (gentle compressor) <- Roar (engine roar low-pass), Wind (low-pass + high-pass),
## UI. Volumes Master / Music / SFX are user settings (user://settings.cfg, [audio]).
##
## Layers (continuous loops, driven every frame from the ship / player state):
##   engine hum + turbine whine (internal: audible in vacuum while piloting), thrust roar
##   (exterior: needs air at the listener; muffled in the cockpit), cockpit air hum, wind
##   (speed x air density), re-entry rumble + plasma crackle, RCS hiss, warp tunnel hum,
##   helmet breathing (on foot in vacuum), surface wind ambience (on foot in air).
## Events: warp spool / whoosh / drop-out boom, sonic boom, touchdown thump, gear motor, hatch
## servo, RCS puffs, footsteps by surface (sand / grass / rock / snow), landing thud, HUD blips,
## UI clicks. Music: MusicPad (mood from the game state).

static var instance: GameAudio

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULTS := {"Master": 0.8, "Music": 0.5, "SFX": 0.9}

var volumes: Dictionary = DEFAULTS.duplicate()
var bank: Dictionary = {}
var ship: Ship
var game: GameMode
var music: MusicPad
## 0..1 global fade (loading screen -> game).
var fade := 0.0
var fade_target := 1.0
var build_ms := 0

var _task := -1
var _bank_tmp: Dictionary
var _loops: Dictionary = {}           # key -> {p, amp, pitch}
var _pool: Array[AudioStreamPlayer] = []
var _ui_pool: Array[AudioStreamPlayer] = []
var _pool_i := 0
var _roar_lp: AudioEffectLowPassFilter
var _wind_lp: AudioEffectLowPassFilter
var _sfx_lp: AudioEffectLowPassFilter
var _prev_warp := 0
var _prev_rcs := 0.0
var _puff_cd := 0.0
var _gust := 0.0
var _gust_t := 0.0
var _rng := RandomNumberGenerator.new()
var _player_hooked: Player
var _visual_hooked: ShipVisual
var _cockpit_k := 0.0


func _ready() -> void:
	instance = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_setup_buses()
	_load_settings()
	music = MusicPad.new()
	music.name = "Music"
	add_child(music)
	_task = WorkerThreadPool.add_task(_build_bank, false, "Synth.build_bank")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if instance == self:
		instance = null


func _build_bank() -> void:
	_bank_tmp = Synth.build_bank()


func is_ready() -> bool:
	return not bank.is_empty()


## Links the gameplay objects (main scene).
func setup(p_ship: Ship, p_game: GameMode) -> void:
	ship = p_ship
	game = p_game
	if ship:
		ship.warp_engaged.connect(func() -> void: play("warp_whoosh", -4.0))
		ship.warp_dropped.connect(func() -> void: play("warp_drop", -3.0))
		ship.gear_changed.connect(func(_d: bool) -> void: play("gear_motor", -15.0, 1.0, _ext_bus_gain()))
		ship.mode_changed.connect(func(_m: int) -> void: play_ui("hud_mode", -16.0))
		ship.hud_message.connect(_on_ship_message)
		if ship.has_signal("touchdown"):
			ship.connect("touchdown", _on_touchdown)
		if ship.has_signal("sonic_boom"):
			ship.connect("sonic_boom", func() -> void: play("sonic_boom", -2.0))


# ------------------------------------------------------------------ settings

func set_volume(bus: String, v: float) -> void:
	volumes[bus] = clampf(v, 0.0, 1.0)
	_apply_volume(bus)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("audio", bus.to_lower(), volumes[bus])
	cfg.save(SETTINGS_PATH)


func get_volume(bus: String) -> float:
	return float(volumes.get(bus, 1.0))


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		for b: String in DEFAULTS:
			volumes[b] = clampf(float(cfg.get_value("audio", b.to_lower(), DEFAULTS[b])), 0.0, 1.0)
	for b: String in volumes:
		_apply_volume(b)


func _apply_volume(bus: String) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	var v: float = volumes[bus]
	AudioServer.set_bus_mute(idx, v <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.001)))


# ------------------------------------------------------------------ buses

func _bus(bus_name: String, send: String, effects: Array) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		return idx
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, send)
	for e: AudioEffect in effects:
		AudioServer.add_bus_effect(idx, e)
	return idx


func _setup_buses() -> void:
	if AudioServer.get_bus_effect_count(0) == 0:
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.5
		AudioServer.add_bus_effect(0, lim)
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.88
	rev.damping = 0.45
	rev.spread = 1.0
	rev.wet = 0.42
	rev.dry = 0.75
	rev.hipass = 0.15
	var mlp := AudioEffectLowPassFilter.new()
	mlp.cutoff_hz = 6500.0
	_bus("Music", "Master", [rev, mlp])
	var comp := AudioEffectCompressor.new()
	comp.threshold = -14.0
	comp.ratio = 3.0
	comp.attack_us = 2000.0
	comp.release_ms = 180.0
	_sfx_lp = AudioEffectLowPassFilter.new()
	_sfx_lp.cutoff_hz = 20000.0
	_bus("SFX", "Master", [comp, _sfx_lp])
	_roar_lp = AudioEffectLowPassFilter.new()
	_roar_lp.cutoff_hz = 2000.0
	_bus("Roar", "SFX", [_roar_lp])
	_wind_lp = AudioEffectLowPassFilter.new()
	_wind_lp.cutoff_hz = 1200.0
	var whp := AudioEffectHighPassFilter.new()
	whp.cutoff_hz = 140.0
	_bus("Wind", "SFX", [_wind_lp, whp])
	_bus("UI", "Master", [])
	# re-resolve the effect instances when the buses already existed (scene reload)
	_roar_lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("Roar"), 0) as AudioEffectLowPassFilter
	_wind_lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("Wind"), 0) as AudioEffectLowPassFilter
	_sfx_lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("SFX"), 1) as AudioEffectLowPassFilter


# ------------------------------------------------------------------ playback helpers

func _on_bank_ready() -> void:
	build_ms = int(bank.get("_build_ms", 0))
	print("[audio] sound bank synthesized in %d ms (%d sounds)" % [build_ms, bank.size() - 1])
	for i in 14:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		p.process_mode = Node.PROCESS_MODE_PAUSABLE
		add_child(p)
		_pool.append(p)
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_ui_pool.append(p)
	var defs := {
		"hum": ["engine_hum", "SFX"], "turbine": ["turbine", "SFX"], "roar": ["noise_pink", "Roar"],
		"cabin": ["cockpit_hum", "SFX"], "wind": ["noise_white", "Wind"], "rumble": ["noise_brown", "SFX"],
		"crackle": ["crackle", "SFX"], "rcs": ["rcs_hiss", "SFX"], "warp": ["warp_loop", "SFX"],
		"breath": ["breath", "SFX"], "amb": ["noise_pink", "Wind"],
	}
	for k: String in defs:
		var p := AudioStreamPlayer.new()
		p.bus = defs[k][1]
		p.stream = bank.get(defs[k][0])
		p.volume_db = -80.0
		p.process_mode = Node.PROCESS_MODE_PAUSABLE
		add_child(p)
		_loops[k] = {"p": p, "amp": 0.0, "pitch": 1.0}
	music.start(bank)


## One-shot on the SFX bus (pausable). `gain` multiplies the level (0..1+).
func play(key: String, vol_db := 0.0, pitch := 1.0, gain := 1.0) -> void:
	if not bank.has(key) or _pool.is_empty() or gain <= 0.001:
		return
	var p := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = bank[key]
	p.pitch_scale = pitch
	p.volume_db = vol_db + linear_to_db(gain * maxf(fade, 0.05))
	p.play()


## UI sound (keeps playing while paused).
func play_ui(key: String, vol_db := -10.0, pitch := 1.0) -> void:
	if not bank.has(key) or _ui_pool.is_empty():
		return
	for p in _ui_pool:
		if not p.playing:
			p.stream = bank[key]
			p.volume_db = vol_db
			p.pitch_scale = pitch
			p.play()
			return


## Static convenience for UI scripts (no-op before the bank exists).
static func ui(key: String, vol_db := -10.0, pitch := 1.0) -> void:
	if instance and is_instance_valid(instance):
		instance.play_ui(key, vol_db, pitch)


## Smoothly drives a loop toward `amp` (linear) and `pitch`; stops it when silent.
func _drive(key: String, amp: float, pitch: float, dt: float, rate := 5.0) -> void:
	var L: Dictionary = _loops.get(key, {})
	if L.is_empty():
		return
	var p: AudioStreamPlayer = L["p"]
	var a: float = lerpf(float(L["amp"]), maxf(amp, 0.0), 1.0 - exp(-dt * rate))
	var pt: float = lerpf(float(L["pitch"]), pitch, 1.0 - exp(-dt * 3.0))
	L["amp"] = a
	L["pitch"] = pt
	var lin := a * fade
	if lin > 0.0015:
		if not p.playing:
			p.play(_rng.randf() * maxf(p.stream.get_length() - 0.1, 0.0))
		p.volume_db = linear_to_db(lin)
		p.pitch_scale = clampf(pt, 0.05, 4.0)
	elif p.playing:
		p.stop()


func _ext_bus_gain() -> float:
	return 1.0


# ------------------------------------------------------------------ events

func _on_touchdown(speed: float) -> void:
	var g := clampf(speed / 3.0, 0.25, 1.6)
	play("thump", -6.0 + 6.0 * log(g) / log(2.0), randf_range(0.92, 1.05))
	if speed > 0.8:
		play("clunk", -16.0, 0.8)


func _on_ship_message(t: String) -> void:
	if t.contains("BLOCKED") or t.contains("LOCKED") or t.contains("CRITICAL") or t.contains("ABORTED") \
			or t.contains("EMERGENCY"):
		play_ui("hud_warn", -14.0)


func _on_footstep(surface: String, sprint: bool) -> void:
	var s := surface if surface in ["sand", "grass", "rock", "snow"] else "sand"
	var k := "step_%s_%d" % [s, _rng.randi() % 4]
	var air := _air_at_listener()
	# in vacuum the step is heard through the suit only (muffled, quieter)
	var v := -15.0 + (2.5 if sprint else 0.0) - (7.0 if air < 0.05 else 0.0)
	play(k, v, _rng.randf_range(0.9, 1.08) * (0.8 if air < 0.05 else 1.0))


func _on_player_landed(fall_speed: float) -> void:
	if fall_speed > 2.0:
		play("land_foot", -12.0 + clampf(fall_speed - 2.0, 0.0, 8.0), 1.0)


# ------------------------------------------------------------------ frame update

func _process(dt: float) -> void:
	if bank.is_empty():
		if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
			WorkerThreadPool.wait_for_task_completion(_task)
			_task = -1
			bank = _bank_tmp
			_bank_tmp = {}
			_on_bank_ready()
		return
	fade = move_toward(fade, fade_target, dt / 3.0)
	music.level = fade
	if get_tree().paused:
		_sfx_lp.cutoff_hz = 700.0
		return
	_sfx_lp.cutoff_hz = 20000.0
	if ship == null or game == null:
		return
	_hook_player()
	_hook_visual()
	_update_music()
	_update_ship_layers(dt)
	_update_foot_layers(dt)


func _hook_player() -> void:
	var pl := game.player
	if pl == null or pl == _player_hooked:
		return
	_player_hooked = pl
	if pl.has_signal("footstep"):
		pl.connect("footstep", _on_footstep)
	pl.landed.connect(_on_player_landed)


func _hook_visual() -> void:
	if ship.visual == null or ship.visual == _visual_hooked:
		return
	_visual_hooked = ship.visual
	ship.visual.hatch_changed.connect(func(_o: bool) -> void:
		var g := _proximity()
		play("hatch_servo", -13.0, 1.0, g))


func _listener_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	return cam.global_position if cam else ship.global_position


func _air_at_listener() -> float:
	return Universe.get_atmosphere_density(_listener_pos())


## Exterior proximity gain of the ship for the listener (1 when piloting / close).
func _proximity() -> float:
	if game.state == GameMode.State.SHIP:
		return 1.0
	var d := _listener_pos().distance_to(ship.global_position)
	return 1.0 / (1.0 + pow(d / 35.0, 1.6))


func _update_music() -> void:
	var m := MusicPad.Mood.SPACE
	if game.state == GameMode.State.ON_FOOT:
		m = MusicPad.Mood.ON_FOOT
	elif ship.body is Planet and ship.altitude < 40000.0:
		m = MusicPad.Mood.PLANET
	music.set_mood(m)
	# duck the music a little under loud flight events
	var duck := 1.0 - 0.35 * ship.heat - 0.3 * float(ship.warp_state != Ship.WarpState.IDLE)
	music.level = fade * duck


func _update_ship_layers(dt: float) -> void:
	var piloting := game.state == GameMode.State.SHIP
	var fx := ship.get_node_or_null("FX") as ShipFX
	var rig := ship.camera_rig as ShipCameraRig
	var cockpit := piloting and rig != null and rig.view == ShipCameraRig.View.COCKPIT
	_cockpit_k = lerpf(_cockpit_k, 1.0 if cockpit else 0.0, 1.0 - exp(-dt * 4.0))
	var prox := _proximity()
	var air_l := _air_at_listener()
	var ext := smoothstep(0.0, 0.12, air_l)                 # sound carries through air
	var inside := 1.0 if piloting else 0.0                   # structure-borne sounds
	var thr: float = ship.visual.thrust if ship.visual else 0.0
	if ship.landed and not piloting:
		thr = 0.0
	var boost := ship.boost_t
	var s := ship.vel.length()
	var dens := ship.density
	# --- engines
	var hum := (0.2 + 0.55 * thr) * inside + ext * prox * (0.1 + 0.5 * thr) * (1.0 - inside)
	if thr < 0.005 and not piloting:
		hum = 0.0
	_drive("hum", hum * 0.55, 0.72 + 0.6 * thr + 0.12 * boost, dt)
	_drive("turbine", pow(thr, 0.8) * 0.16 * maxf(inside * 0.8, ext * prox), 0.55 + 0.8 * thr + 0.1 * boost, dt)
	var roar := pow(thr, 1.3) * (ext * prox * 0.95 + inside * 0.3)
	_drive("roar", roar, 0.9 + 0.25 * thr, dt, 8.0)
	var cut := lerpf(240.0, 500.0 + 5200.0 * thr, ext) * lerpf(1.0, 0.35, _cockpit_k)
	_roar_lp.cutoff_hz = clampf(cut, 120.0, 12000.0)
	_drive("cabin", (0.1 + 0.1 * _cockpit_k) * inside, 1.0, dt, 2.0)
	# --- wind / air rush (needs air around the ship; the cockpit muffles it)
	_gust_t -= dt
	if _gust_t <= 0.0:
		_gust_t = _rng.randf_range(0.8, 3.0)
		_gust = _rng.randf_range(-0.25, 0.3)
	var w := clampf(sqrt(dens) * s / 240.0, 0.0, 1.25) * (1.0 + _gust * 0.4)
	w *= (inside * lerpf(1.0, 0.45, _cockpit_k) + (1.0 - inside) * prox * ext)
	_drive("wind", w * 0.6, 0.85 + clampf(s / 2000.0, 0.0, 0.5), dt, 4.0)
	_wind_lp.cutoff_hz = clampf(350.0 + s * 10.0, 350.0, 9000.0) * lerpf(1.0, 0.4, _cockpit_k)
	# --- re-entry (rumble felt through the hull, crackle of the plasma)
	var h := ship.heat
	_drive("rumble", h * 0.9 * maxf(inside, prox), 0.8 + 0.3 * h, dt, 3.0)
	_drive("crackle", pow(h, 1.4) * 0.5 * maxf(inside, prox * ext), 0.9 + 0.2 * h, dt, 5.0)
	# --- RCS
	var rcs: float = fx.rcs_level if fx else 0.0
	var rcs_g := maxf(inside * 0.6, ext * prox)
	_drive("rcs", rcs * 0.22 * rcs_g, 1.0, dt, 12.0)
	_puff_cd -= dt
	if rcs > _prev_rcs + 0.18 and _puff_cd <= 0.0:
		play("rcs_puff", -18.0, _rng.randf_range(0.85, 1.15), rcs_g)
		_puff_cd = 0.12
	_prev_rcs = lerpf(_prev_rcs, rcs, 1.0 - exp(-dt * 6.0))
	# --- warp
	var wa: float = fx.warp_amount if fx else 0.0
	_drive("warp", wa * 0.55 * inside, 0.8 + 0.4 * wa, dt, 3.0)
	if ship.warp_state == Ship.WarpState.SPOOL and _prev_warp == Ship.WarpState.IDLE:
		play("warp_spool", -5.0)
	_prev_warp = ship.warp_state


func _update_foot_layers(dt: float) -> void:
	var on_foot := game.state == GameMode.State.ON_FOOT and game.player != null
	var air := _air_at_listener()
	var pl := game.player
	var sprint := on_foot and pl.get_horizontal_speed() > pl.walk_speed + 0.5
	_drive("breath", (0.13 if on_foot and air < 0.05 else 0.0), 1.25 if sprint else 1.0, dt, 1.5)
	_drive("amb", (air * 0.16 * (1.0 + _gust) if on_foot else 0.0), 0.7, dt, 1.0)
