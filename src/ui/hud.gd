class_name Hud
extends CanvasLayer
## Minimal sci-fi HUD, drawn procedurally (thin lines, soft glow, dark outline for readability on
## bright and dark backgrounds, monospace numbers). Two layouts:
##   SHIP    — reticle, prograde/retrograde marker, target bracket / off-screen arrow, speed + speed
##             mode bar, throttle, altitude / vertical speed / body, flags (GEAR, LANDED, FA OFF,
##             AUTOPILOT, re-entry heat), interaction prompt.
##   ON_FOOT — small crosshair, compass with ship bearing, body / gravity, interaction prompt.
## Data comes from `ship.get_hud_data()` (see src/player/test_ship_stub.gd for the contract) and
## from the Player node. H toggles. Hidden while Capture.active unless `--hud` is passed.
## A full-screen fade (`fade_to`) lives outside the toggleable part (used by GameMode).

enum Mode { NONE, SHIP, ON_FOOT }

const C_MAIN := Color(0.80, 0.96, 1.0, 0.96)
const C_DIM := Color(0.80, 0.96, 1.0, 0.55)
const C_FAINT := Color(0.80, 0.96, 1.0, 0.22)
const C_ACCENT := Color(1.0, 0.76, 0.34, 1.0)
const C_WARN := Color(1.0, 0.38, 0.27, 1.0)
const C_OK := Color(0.55, 1.0, 0.72, 1.0)
const C_PRO := Color(0.72, 1.0, 0.55, 1.0)
const C_SHADOW := Color(0.0, 0.015, 0.03, 0.5)
const MONO_FONTS := ["JetBrains Mono", "Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Menlo", "monospace"]
const TEXT_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans", "sans-serif"]
const COMPASS := {0: "С", 45: "СВ", 90: "В", 135: "ЮВ", 180: "Ю", 225: "ЮЗ", 270: "З", 315: "СЗ"}

@export var mode: Mode = Mode.NONE
var ship: Node3D
var player: Node3D
var prompt_key := ""
var prompt_text := ""
## For screenshots/tests: overrides the active camera used for projections.
var camera_override: Camera3D

var _root: Control
var _fade: ColorRect
var _mono: SystemFont
var _text_font: SystemFont
var _s := 1.0
var _time := 0.0
var _message := ""
var _message_t := 0.0
var _prev_ship_pos := Vector3.ZERO
var _have_prev := false
var _vel_est := Vector3.ZERO
var _fade_tween: Tween
# wave 4: animated transitions
var _mode_prev := -1
var _mode_t := 10.0            # s since the last speed-mode change
var _pip_x := -1.0             # animated position of the active mode pip
var _banner := ""
var _banner_t := 10.0
var _show_k := 1.0             # HUD reveal (0..1) when switching layouts
var _warp_ring := 0.0
var _land_k := 0.0             # landing-assist panel reveal
var _target_prev := ""
var _target_t := 10.0
var _prev_target_dist := -1.0
var _closing := 0.0


func _ready() -> void:
	layer = 5
	_root = get_node_or_null("Root") as Control
	if _root == null:
		_root = Control.new()
		_root.name = "Root"
		add_child(_root)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.draw.connect(_draw_hud)
	_fade = get_node_or_null("Fade") as ColorRect
	if _fade == null:
		_fade = ColorRect.new()
		_fade.name = "Fade"
		add_child(_fade)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(0, 0, 0, 0)
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(MONO_FONTS)
	_mono.font_weight = 500
	_mono.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	_text_font = SystemFont.new()
	_text_font.font_names = PackedStringArray(TEXT_FONTS)
	_text_font.font_weight = 500
	if Capture.active and not Capture.args.has("hud"):
		_root.visible = false
	if not Universe.origin_shifted.is_connected(_on_origin_shifted):
		Universe.origin_shifted.connect(_on_origin_shifted)


# ------------------------------------------------------------------ API

func set_mode(m: Mode) -> void:
	if m != mode:
		_show_k = 0.0
	mode = m
	_have_prev = false


func set_prompt(text: String, key := "F") -> void:
	prompt_text = text
	prompt_key = key if text != "" else ""


func clear_prompt() -> void:
	set_prompt("")


func flash_message(text: String, seconds := 2.5) -> void:
	# speed-mode names get the animated banner instead of a plain message
	if text in ["HOVER", "ATMOSPHERE", "SPACE", "CRUISE", "WARP"]:
		_banner = text
		_banner_t = 0.0
		return
	_message = text
	_message_t = seconds


func toggle() -> void:
	_root.visible = not _root.visible


func is_shown() -> bool:
	return _root.visible


func set_shown(on: bool) -> void:
	_root.visible = on


## Fades the whole screen to `alpha` (0 = clear, 1 = black) over `time` seconds; awaitable.
func fade_to(alpha: float, time: float) -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	if time <= 0.0:
		_fade.color.a = alpha
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade, "color:a", alpha, time).set_trans(Tween.TRANS_SINE)
	await _fade_tween.finished


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("hud_toggle") and not event.is_echo():
		toggle()
		get_viewport().set_input_as_handled()


func _on_origin_shifted(delta: Vector3) -> void:
	_prev_ship_pos -= delta


func _process(dt: float) -> void:
	_time += dt
	_message_t = maxf(_message_t - dt, 0.0)
	_mode_t += dt
	_banner_t += dt
	_target_t += dt
	_show_k = move_toward(_show_k, 1.0, dt / 0.45)
	_root.modulate.a = smoothstep(0.0, 1.0, _show_k)
	if mode == Mode.SHIP and ship and is_instance_valid(ship) and dt > 0.0:
		var p := ship.global_position
		if _have_prev:
			_vel_est = _vel_est.lerp((p - _prev_ship_pos) / dt, clampf(dt * 8.0, 0.0, 1.0))
		_prev_ship_pos = p
		_have_prev = true
	if _root.visible:
		_root.queue_redraw()


# ------------------------------------------------------------------ formatting

static func fmt_speed(v: float) -> Array:
	var a := absf(v)
	if a < 100.0:
		return ["%.1f" % v, "m/s"]
	if a < 1000.0:
		return ["%d" % roundi(v), "m/s"]
	if a < 1.0e6:
		return ["%.2f" % (v / 1000.0) if a < 1.0e4 else "%.1f" % (v / 1000.0), "km/s"]
	return ["%.2f" % (v / 1.0e6), "Mm/s"]


static func fmt_dist(d: float) -> Array:
	var a := absf(d)
	if a < 1000.0:
		return ["%d" % roundi(d), "m"]
	if a < 1.0e5:
		return ["%.2f" % (d / 1000.0) if a < 1.0e4 else "%.1f" % (d / 1000.0), "km"]
	if a < 1.0e6:
		return ["%d" % roundi(d / 1000.0), "km"]
	return ["%.2f" % (d / 1.0e6) if a < 1.0e8 else "%d" % roundi(d / 1.0e6), "Mm"]


# ------------------------------------------------------------------ drawing primitives

## Thin line with a dark under-stroke (readable on snow and on black) and a soft glow.
func _line(a: Vector2, b: Vector2, col: Color, w := 1.1) -> void:
	_root.draw_line(a, b, Color(C_SHADOW, C_SHADOW.a * 0.8), (w + 1.8) * _s, true)
	_root.draw_line(a, b, Color(col, col.a * 0.08), (w + 5.0) * _s, true)
	_root.draw_line(a, b, col, w * _s, true)


func _poly(pts: PackedVector2Array, col: Color, w := 1.1) -> void:
	_root.draw_polyline(pts, Color(C_SHADOW, C_SHADOW.a * 0.8), (w + 1.8) * _s, true)
	_root.draw_polyline(pts, Color(col, col.a * 0.08), (w + 5.0) * _s, true)
	_root.draw_polyline(pts, col, w * _s, true)


func _circle(c: Vector2, r: float, col: Color, w := 1.1, a0 := 0.0, a1 := TAU) -> void:
	var n := maxi(16, int(absf(a1 - a0) * r / _s * 0.14) + 8)
	_root.draw_arc(c, r, a0, a1, n, Color(C_SHADOW, C_SHADOW.a * 0.8), (w + 1.8) * _s, true)
	_root.draw_arc(c, r, a0, a1, n, Color(col, col.a * 0.08), (w + 5.0) * _s, true)
	_root.draw_arc(c, r, a0, a1, n, col, w * _s, true)


func _text_size(t: String, size: float, mono := true) -> Vector2:
	var f: Font = _mono if mono else _text_font
	return f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, int(size * _s)))


## Draws text with a dark outline. `align`: 0 left, 1 centre, 2 right (relative to pos.x).
func _text(pos: Vector2, t: String, size: float, col: Color, align := 0, mono := true) -> float:
	var f: Font = _mono if mono else _text_font
	var fs := maxi(1, int(size * _s))
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := pos
	if align == 1:
		p.x -= w * 0.5
	elif align == 2:
		p.x -= w
	_root.draw_string_outline(f, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, int(4.0 * _s)), C_SHADOW)
	_root.draw_string(f, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	return w


## Big number + small unit, aligned at the baseline. Returns total width.
func _value(pos: Vector2, num: String, unit: String, size: float, col: Color, align := 0) -> float:
	var wn := _text_size(num, size).x
	var wu := _text_size(unit, size * 0.42).x
	var gap := 6.0 * _s
	var total := wn + gap + wu
	var x := pos.x
	if align == 2:
		x -= total
	elif align == 1:
		x -= total * 0.5
	_text(Vector2(x, pos.y), num, size, col)
	_text(Vector2(x + wn + gap, pos.y), unit, size * 0.42, C_DIM)
	return total


func _camera() -> Camera3D:
	if camera_override and is_instance_valid(camera_override):
		return camera_override
	return _root.get_viewport().get_camera_3d()


# ------------------------------------------------------------------ main draw

func _draw_hud() -> void:
	var vs := _root.size
	_s = vs.y / 1080.0
	match mode:
		Mode.SHIP:
			_draw_ship(vs)
		Mode.ON_FOOT:
			_draw_on_foot(vs)
	_draw_prompt(vs)
	if _message_t > 0.0 and _message != "":
		var a := clampf(_message_t / 0.5, 0.0, 1.0) * clampf((2.5 - _message_t) / 0.15 + 0.3, 0.0, 1.0)
		_text(Vector2(vs.x * 0.5, vs.y * 0.3), _message, 19, Color(C_MAIN, a), 1, false)
	_draw_banner(vs)


## Speed-mode banner: letter-spaced name with hairlines drawing outward, fades after ~1.6 s.
func _draw_banner(vs: Vector2) -> void:
	if _banner == "" or _banner_t > 2.2 or mode != Mode.SHIP:
		return
	var t := _banner_t
	var a := smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(1.5, 2.2, t))
	var y := vs.y * 0.27
	var spaced := ""
	for ch in _banner:
		spaced += ch + " "
	spaced = spaced.strip_edges()
	var w := _text_size(spaced, 22, false).x
	_text(Vector2(vs.x * 0.5, y), spaced, 22, Color(C_MAIN, a), 1, false)
	var ext := (w * 0.5 + 18.0 * _s) + 90.0 * _s * smoothstep(0.0, 0.5, t)
	var inner := w * 0.5 + 18.0 * _s
	var ly := y - 7.0 * _s
	_line(Vector2(vs.x * 0.5 - ext, ly), Vector2(vs.x * 0.5 - inner, ly), Color(C_ACCENT, a * 0.8), 1.0)
	_line(Vector2(vs.x * 0.5 + inner, ly), Vector2(vs.x * 0.5 + ext, ly), Color(C_ACCENT, a * 0.8), 1.0)


func _draw_prompt(vs: Vector2) -> void:
	if prompt_text == "":
		return
	var y := vs.y * 0.74
	var fs := 19.0
	var tw := _text_size(prompt_text, fs, false).x
	var kw := maxf(_text_size(prompt_key, 16).x + 16.0 * _s, 30.0 * _s)
	var gap := 12.0 * _s
	var total := kw + gap + tw
	var x0 := vs.x * 0.5 - total * 0.5
	var kh := 30.0 * _s
	var rect := Rect2(x0, y - kh * 0.5, kw, kh)
	var pulse := 0.75 + 0.25 * sin(_time * 3.0)
	_root.draw_rect(rect.grow(2.0 * _s), C_SHADOW, false, 3.0 * _s)
	_root.draw_rect(rect, Color(0.02, 0.06, 0.09, 0.55), true)
	_root.draw_rect(rect, Color(C_ACCENT, pulse), false, 1.5 * _s)
	_text(Vector2(x0 + kw * 0.5, y + 6.0 * _s), prompt_key, 16, C_ACCENT, 1)
	_text(Vector2(x0 + kw + gap, y + 7.0 * _s), prompt_text, fs, C_MAIN, 0, false)


# ------------------------------------------------------------------ ship layout

func _draw_ship(vs: Vector2) -> void:
	if ship == null or not is_instance_valid(ship) or not ship.has_method("get_hud_data"):
		return
	var d: Dictionary = ship.get_hud_data()
	var c := vs * 0.5
	var cam := _camera()
	var mi := int(d.get("mode", 0))
	if mi != _mode_prev:
		if _mode_prev >= 0:
			_mode_t = 0.0
		_mode_prev = mi
	var tn := str(d.get("target_name", ""))
	if tn != _target_prev:
		_target_prev = tn
		_target_t = 0.0
	# reticle
	var rc := C_DIM
	_circle(c, 16.0 * _s, rc, 1.2, deg_to_rad(20), deg_to_rad(70))
	_circle(c, 16.0 * _s, rc, 1.2, deg_to_rad(110), deg_to_rad(160))
	_circle(c, 16.0 * _s, rc, 1.2, deg_to_rad(200), deg_to_rad(250))
	_circle(c, 16.0 * _s, rc, 1.2, deg_to_rad(290), deg_to_rad(340))
	for k in 4:
		var dir := Vector2.from_angle(k * PI * 0.5)
		_line(c + dir * 22.0 * _s, c + dir * 32.0 * _s, rc, 1.2)
	_root.draw_circle(c, 1.8 * _s, C_MAIN)
	if cam:
		_draw_prograde(d, cam, vs)
		_draw_target(d, cam, vs)
	_draw_speed_block(d, vs)
	_draw_alt_block(d, vs)
	_draw_flags(d, vs)
	_draw_target_readout(d, vs)
	_draw_warp_ring(d, c)
	_draw_heat(d, c)
	if cam:
		_draw_landing(d, cam, vs)


func _ship_velocity(d: Dictionary) -> Vector3:
	var v: Variant = d.get("velocity", null)
	if v is Vector3:
		return v
	return _vel_est


func _draw_prograde(d: Dictionary, cam: Camera3D, vs: Vector2) -> void:
	var v := _ship_velocity(d)
	if v.length() < 0.5:
		return
	var cp := cam.global_position
	var p := cp + v.normalized() * 1000.0
	var retro := cam.is_position_behind(p)
	if retro:
		p = cp - v.normalized() * 1000.0
		if cam.is_position_behind(p):
			return
	var sp := cam.unproject_position(p)
	if not Rect2(Vector2.ZERO, vs).grow(-20.0 * _s).has_point(sp):
		return
	var r := 9.0 * _s
	if not retro:
		_circle(sp, r, C_PRO, 1.6)
		_line(sp + Vector2(-r, 0), sp + Vector2(-r - 9.0 * _s, 0), C_PRO, 1.6)
		_line(sp + Vector2(r, 0), sp + Vector2(r + 9.0 * _s, 0), C_PRO, 1.6)
		_line(sp + Vector2(0, -r), sp + Vector2(0, -r - 8.0 * _s), C_PRO, 1.6)
		_root.draw_circle(sp, 1.6 * _s, C_PRO)
	else:
		_circle(sp, r, C_ACCENT, 1.6)
		var k := r * 0.7
		_line(sp + Vector2(-k, -k), sp + Vector2(k, k), C_ACCENT, 1.4)
		_line(sp + Vector2(-k, k), sp + Vector2(k, -k), C_ACCENT, 1.4)
		for a in [PI * 0.25, PI * 0.75, PI * 1.25, PI * 1.75]:
			var dv := Vector2.from_angle(a)
			_line(sp + dv * r, sp + dv * (r + 7.0 * _s), C_ACCENT, 1.4)


func _target_world(d: Dictionary) -> Variant:
	var tp: Variant = d.get("target_position", null)
	if tp is Vector3:
		return tp
	var tn: String = str(d.get("target_name", ""))
	if tn == "":
		return null
	for b in Universe.get_bodies():
		if b.has_method("get_body_name") and b.get_body_name() == tn:
			return b.global_position
	return null


func _target_radius(d: Dictionary) -> float:
	if d.has("target_radius"):
		return float(d["target_radius"])
	var tn: String = str(d.get("target_name", ""))
	for b in Universe.get_bodies():
		if b.has_method("get_body_name") and b.get_body_name() == tn:
			return b.get_body_radius()
	return 0.0


func _draw_target(d: Dictionary, cam: Camera3D, vs: Vector2) -> void:
	var tw: Variant = _target_world(d)
	if tw == null:
		return
	var tpos: Vector3 = tw
	var name_s := str(d.get("target_name", "")).to_upper()
	var dist := float(d.get("target_distance", cam.global_position.distance_to(tpos)))
	var ds := fmt_dist(dist)
	var dist_s := "%s %s" % [ds[0], ds[1]]
	var col := C_ACCENT
	var behind := cam.is_position_behind(tpos)
	var sp := cam.unproject_position(tpos)
	var margin := 70.0 * _s
	var safe := Rect2(Vector2.ZERO, vs).grow(-margin)
	if not behind and safe.has_point(sp):
		# bracket sized to the body's angular size (min 22 px)
		var rad := _target_radius(d)
		var half := 22.0 * _s
		if rad > 0.0:
			var dcam := cam.global_position.distance_to(tpos)
			var ang := atan(rad / maxf(dcam, 1.0))
			var px := tan(ang) / tan(deg_to_rad(cam.fov * 0.5)) * vs.y * 0.5
			half = clampf(px * 1.08, 22.0 * _s, vs.y * 0.35)
		var L := minf(12.0 * _s, half * 0.6)
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := sp + Vector2(sx, sy) * half
				_poly(PackedVector2Array([corner - Vector2(sx * L, 0), corner, corner - Vector2(0, sy * L)]), col, 1.5)
		_text(sp + Vector2(half + 10.0 * _s, -half + 12.0 * _s), name_s, 14, col, 0, false)
		_text(sp + Vector2(half + 10.0 * _s, -half + 30.0 * _s), dist_s, 13, C_MAIN)
		_root.draw_circle(sp, 1.6 * _s, col)
	else:
		# off-screen arrow on an inset ellipse
		var local := cam.global_transform.affine_inverse() * tpos
		var dir2 := Vector2(local.x, -local.y)
		if dir2.length() < 1e-4:
			dir2 = Vector2(0, 1)
		dir2 = dir2.normalized()
		var c := vs * 0.5
		var ex := vs.x * 0.5 - margin
		var ey := vs.y * 0.5 - margin
		var k := 1.0 / sqrt(pow(dir2.x / ex, 2.0) + pow(dir2.y / ey, 2.0))
		var p := c + dir2 * k
		var n := dir2.orthogonal()
		var tip := p + dir2 * 12.0 * _s
		var pts := PackedVector2Array([p - n * 9.0 * _s, tip, p + n * 9.0 * _s])
		_poly(pts, col, 1.8)
		_poly(PackedVector2Array([p - n * 6.0 * _s - dir2 * 8.0 * _s, tip - dir2 * 8.0 * _s, p + n * 6.0 * _s - dir2 * 8.0 * _s]), Color(col, 0.5), 1.2)
		var lp := p - dir2 * 34.0 * _s
		_text(lp + Vector2(0, -2.0 * _s), name_s, 13, col, 1, false)
		_text(lp + Vector2(0, 15.0 * _s), dist_s, 12, C_MAIN, 1)


func _draw_speed_block(d: Dictionary, vs: Vector2) -> void:
	var x0 := 78.0 * _s
	var yb := vs.y - 70.0 * _s
	var speed := float(d.get("speed", 0.0))
	var vmax := maxf(float(d.get("mode_max_speed", 1.0)), 1e-3)
	# throttle bar (vertical, left)
	var thr := clampf(float(d.get("throttle", 0.0)), -1.0, 1.0)
	var tx := 46.0 * _s
	var ty0 := yb - 132.0 * _s
	var ty1 := yb + 4.0 * _s
	_line(Vector2(tx, ty0), Vector2(tx, ty1), C_FAINT, 3.0)
	for i in 5:
		var y := lerpf(ty1, ty0, i / 4.0)
		_line(Vector2(tx - 6.0 * _s, y), Vector2(tx - 3.0 * _s, y), C_DIM, 1.0)
	if absf(thr) > 0.001:
		var yt := lerpf(ty1, ty0, absf(thr))
		_line(Vector2(tx, ty1), Vector2(tx, yt), C_ACCENT if thr < 0.0 else C_MAIN, 3.0)
		_line(Vector2(tx - 7.0 * _s, yt), Vector2(tx + 7.0 * _s, yt), C_MAIN, 1.4)
	_text(Vector2(tx, ty1 + 20.0 * _s), "THR", 11, C_DIM, 1)
	_text(Vector2(tx, ty0 - 9.0 * _s), "%d%%" % roundi(thr * 100.0), 11, C_MAIN, 1)
	# speed
	_text(Vector2(x0, yb - 112.0 * _s), "SPEED", 12, C_DIM, 0, false)
	var sv := fmt_speed(speed)
	_value(Vector2(x0, yb - 70.0 * _s), sv[0], sv[1], 42, C_MAIN)
	# speed mode
	var mode_name := str(d.get("mode_name", "")).to_upper()
	var mt := clampf(_mode_t / 0.45, 0.0, 1.0)
	var me := 1.0 - pow(1.0 - mt, 3.0)
	_text(Vector2(x0 + (1.0 - me) * 14.0 * _s, yb - 38.0 * _s), mode_name, 15, Color(C_ACCENT, me), 0, false)
	if mt < 1.0:
		# a light sweep along the speed bar on a mode change
		var sw := x0 + 300.0 * _s * me
		_line(Vector2(maxf(x0, sw - 60.0 * _s), yb - 26.0 * _s), Vector2(sw, yb - 26.0 * _s), Color(1, 1, 1, (1.0 - mt) * 0.8), 2.0)
	var mx := fmt_speed(vmax)
	_text(Vector2(x0 + 300.0 * _s, yb - 38.0 * _s), "MAX %s %s" % [mx[0], mx[1]], 11, C_DIM, 2)
	var bw := 300.0 * _s
	var by := yb - 26.0 * _s
	_line(Vector2(x0, by), Vector2(x0 + bw, by), C_FAINT, 4.0)
	var f := speed / vmax
	_line(Vector2(x0, by), Vector2(x0 + bw * clampf(f, 0.0, 1.0), by), C_WARN if f > 1.02 else C_MAIN, 4.0)
	for i in 5:
		var x := x0 + bw * i / 4.0
		_line(Vector2(x, by + 5.0 * _s), Vector2(x, by + 9.0 * _s), C_DIM, 1.0)
	# mode pips 1..N
	var count := int(d.get("mode_count", 5))
	var mi := int(d.get("mode", 0))
	var target_x := x0 + 7.0 * _s + mi * 24.0 * _s
	if _pip_x < 0.0:
		_pip_x = target_x
	_pip_x = lerpf(_pip_x, target_x, clampf(get_process_delta_time() * 12.0, 0.0, 1.0))
	for i in count:
		var px := x0 + 7.0 * _s + i * 24.0 * _s
		var py := yb + 4.0 * _s
		var r := 5.0 * _s
		var pts := PackedVector2Array([Vector2(px, py - r), Vector2(px + r, py), Vector2(px, py + r), Vector2(px - r, py), Vector2(px, py - r)])
		_poly(pts, C_ACCENT if i == mi else C_DIM, 1.0)
	# the active pip slides between positions
	var r2 := 5.0 * _s
	var py2 := yb + 4.0 * _s
	var ap := PackedVector2Array([Vector2(_pip_x, py2 - r2), Vector2(_pip_x + r2, py2), Vector2(_pip_x, py2 + r2), Vector2(_pip_x - r2, py2)])
	_root.draw_colored_polygon(ap, C_ACCENT)
	_text(Vector2(x0 + count * 24.0 * _s + 4.0 * _s, yb + 9.0 * _s), "TAB", 10, C_DIM)


func _draw_alt_block(d: Dictionary, vs: Vector2) -> void:
	var x1 := vs.x - 78.0 * _s
	var yb := vs.y - 70.0 * _s
	var body := str(d.get("body_name", ""))
	var alt := float(d.get("altitude", -1.0))
	var vsp := float(d.get("vertical_speed", 0.0))
	if body == "":
		return
	_text(Vector2(x1, yb + 4.0 * _s), body.to_upper(), 15, C_ACCENT, 2, false)
	if alt < 0.0 or alt > 500000.0:
		return
	_text(Vector2(x1, yb - 112.0 * _s), "ALTITUDE", 12, C_DIM, 2, false)
	var av := fmt_dist(alt)
	_value(Vector2(x1, yb - 70.0 * _s), av[0], av[1], 42, C_MAIN, 2)
	var vv := fmt_speed(absf(vsp))
	var up := vsp >= 0.0
	var vcol := C_MAIN if absf(vsp) < 0.05 else (C_OK if up else (C_WARN if vsp < -20.0 and alt < 2000.0 else C_MAIN))
	var w := _value(Vector2(x1, yb - 32.0 * _s), vv[0], vv[1], 20, vcol, 2)
	# arrow
	var ax := x1 - w - 16.0 * _s
	var ay := yb - 39.0 * _s
	var sgn := -1.0 if up else 1.0
	var tri := PackedVector2Array([Vector2(ax - 6.0 * _s, ay - sgn * 4.0 * _s), Vector2(ax, ay + sgn * 5.0 * _s), Vector2(ax + 6.0 * _s, ay - sgn * 4.0 * _s)])
	if absf(vsp) >= 0.05:
		_root.draw_colored_polygon(tri, vcol)
	_text(Vector2(ax - 14.0 * _s, yb - 32.0 * _s), "V/S", 11, C_DIM, 2)
	# atmosphere density
	var atm := float(d.get("atmosphere_density", 0.0))
	if atm > 0.001:
		var bw := 120.0 * _s
		var by := yb - 16.0 * _s
		_line(Vector2(x1 - bw, by), Vector2(x1, by), C_FAINT, 3.0)
		_line(Vector2(x1 - bw, by), Vector2(x1 - bw + bw * clampf(atm, 0.0, 1.0), by), C_DIM, 3.0)
		_text(Vector2(x1 - bw - 8.0 * _s, by + 4.0 * _s), "ATM %.2f" % atm, 10, C_DIM, 2)


func _draw_flags(d: Dictionary, vs: Vector2) -> void:
	var flags: Array = []   # [text, color, filled, blink]
	if bool(d.get("landed", false)):
		flags.append(["LANDED", C_OK, false, false])
	if bool(d.get("gear_down", false)):
		flags.append(["GEAR", C_ACCENT, false, false])
	if not bool(d.get("flight_assist", true)):
		flags.append(["FA OFF", C_WARN, false, false])
	if bool(d.get("autopilot", false)):
		flags.append(["AUTOPILOT", C_MAIN, true, false])
	var heat := float(d.get("heat", 0.0))
	if heat > 0.7:
		flags.append(["HEAT CRITICAL", C_WARN, true, true])
	elif heat > 0.25:
		flags.append(["RE-ENTRY", C_ACCENT, false, true])
	if flags.is_empty():
		return
	var fs := 12.0
	var pad := 10.0 * _s
	var h := 22.0 * _s
	var gap := 10.0 * _s
	var widths: Array[float] = []
	var total := 0.0
	for f in flags:
		var w := _text_size(f[0], fs).x + pad * 2.0
		widths.append(w)
		total += w
	total += gap * (flags.size() - 1)
	var x := vs.x * 0.5 - total * 0.5
	var y := 34.0 * _s
	for i in flags.size():
		var f: Array = flags[i]
		var col: Color = f[1]
		if f[3]:
			col.a *= 0.55 + 0.45 * (0.5 + 0.5 * sin(_time * 7.0))
		var r := Rect2(x, y, widths[i], h)
		_root.draw_rect(r.grow(1.5 * _s), C_SHADOW, false, 3.0 * _s)
		if f[2]:
			_root.draw_rect(r, Color(col, col.a * 0.85), true)
			_text(Vector2(x + widths[i] * 0.5, y + h * 0.5 + 4.5 * _s), f[0], fs, Color(0.02, 0.05, 0.07), 1)
		else:
			_root.draw_rect(r, Color(0.02, 0.06, 0.09, 0.35), true)
			_root.draw_rect(r, col, false, 1.2 * _s)
			_text(Vector2(x + widths[i] * 0.5, y + h * 0.5 + 4.5 * _s), f[0], fs, col, 1)
		x += widths[i] + gap


func _draw_target_readout(d: Dictionary, _vs: Vector2) -> void:
	var tn := str(d.get("target_name", ""))
	if tn == "":
		return
	var x0 := 78.0 * _s
	var y := 52.0 * _s
	var k := smoothstep(0.0, 0.5, _target_t)
	var a := k
	x0 += (1.0 - k) * -16.0 * _s
	_text(Vector2(x0, y), "TARGET", 11, Color(C_DIM, C_DIM.a * a), 0, false)
	_text(Vector2(x0, y + 22.0 * _s), tn.to_upper(), 16, Color(C_ACCENT, a), 0, false)
	var dist := float(d.get("target_distance", 0.0))
	var ds := fmt_dist(dist)
	_text(Vector2(x0, y + 42.0 * _s), "%s %s" % [ds[0], ds[1]], 14, Color(C_MAIN, a))
	# ETA from the closing speed (to the safe arrival altitude)
	var eta_s := _eta(d)
	var eta_txt := "ETA --:--" if eta_s < 0.0 else "ETA " + _fmt_time(eta_s)
	_text(Vector2(x0 + 150.0 * _s, y + 42.0 * _s), eta_txt, 12, Color(C_MAIN, C_MAIN.a * a * 0.8))
	var h := 46.0
	# body info card
	var b := _body_by_name(tn)
	if b:
		var rows := _body_card(b)
		var yy := y + 66.0 * _s
		for i in rows.size():
			var rk := smoothstep(0.15 + i * 0.08, 0.55 + i * 0.08, _target_t)
			_text(Vector2(x0, yy), str(rows[i][0]), 10, Color(C_DIM, C_DIM.a * rk), 0, false)
			_text(Vector2(x0 + 88.0 * _s, yy), str(rows[i][1]), 12, Color(C_MAIN, C_MAIN.a * rk * 0.9))
			yy += 17.0 * _s
		h = 66.0 + rows.size() * 17.0 - 8.0
	_line(Vector2(x0 - 12.0 * _s, y - 10.0 * _s), Vector2(x0 - 12.0 * _s, y + (h * k - 10.0) * _s), C_FAINT, 1.0)


func _body_by_name(n: String) -> Node3D:
	for b in Universe.get_bodies():
		if b.has_method("get_body_name") and b.get_body_name() == n:
			return b
	return null


static func _fmt_time(sec: float) -> String:
	var t := int(roundf(sec))
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


## Seconds to the target's safe arrival altitude at the current closing speed (-1 = not closing).
func _eta(d: Dictionary) -> float:
	var tp: Variant = d.get("target_position", null)
	var v := _ship_velocity(d)
	if not (tp is Vector3) or ship == null:
		return -1.0
	var to: Vector3 = (tp as Vector3) - ship.global_position
	var closing := v.dot(to.normalized())
	_closing = lerpf(_closing, closing, 0.1)
	var left := float(d.get("target_distance", 0.0)) - float(d.get("target_safe_alt", 0.0))
	if _closing < 1.0 or left <= 0.0:
		return -1.0
	return left / _closing


## Type / radius / gravity / atmosphere rows for the targeted body.
func _body_card(b: Node3D) -> Array:
	var kind := "PLANET"
	if b is Star:
		kind = "STAR"
	elif b is GasGiantBody:
		kind = "GAS GIANT"
	else:
		for def: Dictionary in SystemDef.bodies():
			if str(def["name"]) == b.get_body_name() and def.has("parent"):
				kind = "MOON · " + str(def["parent"]).to_upper()
	var rows: Array = [["TYPE", kind]]
	var rr := fmt_dist(b.get_body_radius())
	rows.append(["RADIUS", "%s %s" % [rr[0], rr[1]]])
	var g: float = b.get_surface_gravity()
	rows.append(["GRAVITY", "%.2f m/s²  (%.2f g)" % [g, g / 9.81]])
	var ah: float = b.get_atmosphere_height()
	if b is Star:
		rows.append(["SURFACE", "5 900 K"])
	elif ah > 0.0:
		var ad := fmt_dist(ah)
		rows.append(["ATMOSPHERE", "%s %s" % [ad[0], ad[1]]])
	else:
		rows.append(["ATMOSPHERE", "NONE"])
	return rows


## Warp spool ring around the reticle (fills while spooling, spins while in warp).
func _draw_warp_ring(d: Dictionary, c: Vector2) -> void:
	var ws := int(d.get("warp_state", 0))
	var sp := float(d.get("warp_spool", 0.0))
	_warp_ring = lerpf(_warp_ring, 1.0 if ws != 0 else 0.0, clampf(get_process_delta_time() * 6.0, 0.0, 1.0))
	if Capture.active:
		_warp_ring = 1.0 if ws != 0 else 0.0
	if _warp_ring < 0.02:
		return
	var a := _warp_ring
	var r := 46.0 * _s
	_circle(c, r, Color(C_FAINT, C_FAINT.a * a), 1.0)
	if ws == 1:
		var a1 := -PI * 0.5 + TAU * sp
		_circle(c, r, Color(C_MAIN, a), 2.0, -PI * 0.5, a1)
		_root.draw_circle(c + Vector2.from_angle(a1) * r, 2.6 * _s, Color(1, 1, 1, a))
		_text(c + Vector2(0, r + 22.0 * _s), "WARP SPOOL  %d%%" % roundi(sp * 100.0), 12, Color(C_MAIN, a), 1)
	else:
		for i in 6:
			var a0 := _time * 1.6 + TAU * i / 6.0
			_circle(c, r, Color(0.7, 0.85, 1.0, a * 0.9), 1.6, a0, a0 + 0.55)
		_text(c + Vector2(0, r + 22.0 * _s), "W A R P", 12, Color(0.7, 0.85, 1.0, a * 0.9), 1, false)


## Re-entry hull temperature: an arc left of the reticle, amber -> red, with a readout.
func _draw_heat(d: Dictionary, c: Vector2) -> void:
	var h := float(d.get("heat", 0.0))
	if h < 0.03:
		return
	var a := smoothstep(0.03, 0.12, h)
	var r := 74.0 * _s
	var a0 := PI * 0.78
	var a1 := PI * 1.22
	_circle(c, r, Color(C_FAINT, C_FAINT.a * a), 3.0, a0, a1)
	var col := C_ACCENT.lerp(C_WARN, smoothstep(0.45, 0.8, h))
	if h > 0.7:
		col.a *= 0.6 + 0.4 * (0.5 + 0.5 * sin(_time * 9.0))
	var af := a1 - (a1 - a0) * clampf(h, 0.0, 1.0)
	_circle(c, r, Color(col, col.a * a), 3.0, af, a1)
	var lp := c + Vector2.from_angle(PI) * (r + 14.0 * _s)
	_text(lp + Vector2(0, -6.0 * _s), "HULL TEMP", 10, Color(C_DIM, C_DIM.a * a), 2, false)
	_text(lp + Vector2(0, 10.0 * _s), "%d%%" % roundi(h * 100.0), 12, Color(col, a), 2)


## Landing assist (solid ground below ~300 m): radar-altitude tape right of the reticle with the
## sink rate (green / amber / red against the touchdown limit) and a touchdown marker projected on
## the ground under the ship.
func _draw_landing(d: Dictionary, cam: Camera3D, vs: Vector2) -> void:
	var solid := bool(d.get("solid_ground", false))
	var alt := float(d.get("pad_alt", -1.0))
	if alt < 0.0:
		alt = float(d.get("altitude", -1.0))
	var want := solid and alt >= -0.5 and alt < 300.0 and not bool(d.get("landed", false))
	_land_k = move_toward(_land_k, 1.0 if want else 0.0, get_process_delta_time() / 0.35)
	if Capture.active:
		_land_k = 1.0 if want else 0.0
	if _land_k <= 0.01:
		return
	var a := _land_k
	var vsp := float(d.get("vertical_speed", 0.0))
	var sink := maxf(-vsp, 0.0)
	var col := C_OK
	if sink > 2.0:
		col = C_ACCENT
	if sink > 5.0 or sink > float(d.get("descent_limit", 99.0)) + 1.0:
		col = C_WARN
	# tape: 0..300 m, square-root scale (fine near the ground)
	var c := vs * 0.5
	var x := c.x + 150.0 * _s
	var y0 := c.y + 110.0 * _s
	var y1 := c.y - 110.0 * _s
	var f := func(hh: float) -> float: return lerpf(y0, y1, sqrt(clampf(hh, 0.0, 300.0) / 300.0))
	_line(Vector2(x, y0), Vector2(x, y1), Color(C_FAINT, C_FAINT.a * a * 1.5), 1.0)
	for hh: float in [0.0, 5.0, 10.0, 25.0, 50.0, 100.0, 200.0, 300.0]:
		var yy: float = f.call(hh)
		var big := hh in [0.0, 10.0, 50.0, 100.0, 300.0]
		_line(Vector2(x, yy), Vector2(x + (8.0 if big else 4.0) * _s, yy), Color(C_DIM, C_DIM.a * a), 1.0)
		if big:
			_text(Vector2(x + 12.0 * _s, yy + 4.0 * _s), "%d" % int(hh), 9, Color(C_DIM, C_DIM.a * a * 0.9))
	var ya: float = f.call(alt)
	var tri := PackedVector2Array([Vector2(x - 2.0 * _s, ya), Vector2(x - 10.0 * _s, ya - 5.0 * _s), Vector2(x - 10.0 * _s, ya + 5.0 * _s)])
	_root.draw_colored_polygon(tri, Color(col, a))
	_text(Vector2(x - 14.0 * _s, ya + 4.0 * _s), "%.1f" % alt if alt < 100.0 else "%d" % roundi(alt), 13, Color(C_MAIN, a), 2)
	_text(Vector2(x - 14.0 * _s, ya + 20.0 * _s), "SINK %.1f" % sink, 10, Color(col, a), 2)
	_text(Vector2(x, y0 + 20.0 * _s), "RADAR ALT", 9, Color(C_DIM, C_DIM.a * a), 1, false)
	if bool(d.get("gear_suggest", false)) or (alt < 60.0 and not bool(d.get("gear_down", true))):
		var ga := a * (0.55 + 0.45 * sin(_time * 8.0))
		_text(Vector2(x, y1 - 12.0 * _s), "GEAR UP", 11, Color(C_WARN, ga), 1, false)
	# touchdown marker on the ground below the ship
	var up: Vector3 = ship.get("up_dir")
	var gp: Vector3 = ship.global_position - up * (alt + 2.95)
	if cam.is_position_behind(gp):
		return
	var sp := cam.unproject_position(gp)
	if not Rect2(Vector2.ZERO, vs).grow(-30.0 * _s).has_point(sp):
		return
	# ring flattened by the view angle onto the ground, with a slow pulse
	var to_cam := (cam.global_position - gp).normalized()
	var flat := clampf(absf(to_cam.dot(up)), 0.25, 1.0)
	var rad := clampf(900.0 / maxf(cam.global_position.distance_to(gp), 1.0), 10.0, 60.0) * _s
	var pts := PackedVector2Array()
	var pts2 := PackedVector2Array()
	var pulse := fmod(_time * 0.8, 1.0)
	for i in 33:
		var an := TAU * i / 32.0
		var e := Vector2(cos(an) * rad, sin(an) * rad * flat)
		pts.append(sp + e)
		pts2.append(sp + e * (1.0 + pulse * 0.6))
	_poly(pts, Color(col, a * 0.8), 1.2)
	_root.draw_polyline(pts2, Color(col, a * 0.35 * (1.0 - pulse)), 1.0 * _s, true)
	_line(sp + Vector2(-rad * 0.35, 0), sp + Vector2(rad * 0.35, 0), Color(col, a * 0.8), 1.0)
	_line(sp + Vector2(0, -rad * 0.35 * flat), sp + Vector2(0, rad * 0.35 * flat), Color(col, a * 0.8), 1.0)


# ------------------------------------------------------------------ on-foot layout

func _draw_on_foot(vs: Vector2) -> void:
	var c := vs * 0.5
	# crosshair: dot + 4 short ticks
	_root.draw_circle(c, 2.6 * _s, C_SHADOW)
	_root.draw_circle(c, 1.5 * _s, C_MAIN)
	for k in 4:
		var dv := Vector2.from_angle(k * PI * 0.5 + PI * 0.25)
		_line(c + dv * 7.0 * _s, c + dv * 12.0 * _s, C_DIM, 1.1)
	if player == null or not is_instance_valid(player):
		return
	var up: Vector3 = Universe.get_up(player.global_position)
	var body := Universe.get_dominant_body(player.global_position)
	_draw_compass(vs, up, body)
	# body / gravity / speed (bottom-left, small)
	if body:
		var x0 := 78.0 * _s
		var yb := vs.y - 70.0 * _s
		_text(Vector2(x0, yb - 26.0 * _s), str(body.get_body_name()).to_upper(), 15, C_ACCENT, 0, false)
		var g := Universe.get_gravity(player.global_position).length()
		var hs := 0.0
		if player.has_method("get_horizontal_speed"):
			hs = player.get_horizontal_speed()
		_text(Vector2(x0, yb - 4.0 * _s), "g %.2f m/s²   %.1f m/s" % [g, hs], 12, C_DIM)


func _heading_of(fwd: Vector3, up: Vector3, body: Node3D) -> float:
	var pole := body.global_basis.y if body else Vector3.UP
	var north := pole - up * pole.dot(up)
	if north.length_squared() < 1e-8:
		north = body.global_basis.z if body else Vector3.FORWARD
		north -= up * north.dot(up)
	north = north.normalized()
	var east := north.cross(up)
	return fposmod(rad_to_deg(atan2(fwd.dot(east), fwd.dot(north))), 360.0)


func _draw_compass(vs: Vector2, up: Vector3, body: Node3D) -> void:
	var cam := _camera()
	var fwd: Vector3 = -cam.global_basis.z if cam else -player.global_basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-8:
		fwd = -player.global_basis.z
	fwd = fwd.normalized()
	var hdg := _heading_of(fwd, up, body)
	var cx := vs.x * 0.5
	var y := 44.0 * _s
	var half_w := 260.0 * _s
	var span := 70.0   # degrees each side
	var ppd := half_w / span
	_line(Vector2(cx - half_w, y), Vector2(cx + half_w, y), C_FAINT, 1.0)
	var start := int(floor((hdg - span) / 5.0)) * 5
	for a in range(start, int(hdg + span) + 5, 5):
		var off := a - hdg
		if absf(off) > span:
			continue
		var x := cx + off * ppd
		var fade := 1.0 - pow(absf(off) / span, 2.0)
		var aa := posmod(a, 360)
		var big := aa % 45 == 0
		var mid := aa % 15 == 0
		var L := (10.0 if big else (6.0 if mid else 3.0)) * _s
		var col := Color(C_MAIN if big else C_DIM, (C_MAIN.a if big else C_DIM.a) * fade)
		_line(Vector2(x, y), Vector2(x, y + L), col, 1.2 if big else 1.0)
		if big:
			var lbl: String = COMPASS.get(aa, "")
			var lc := Color(C_ACCENT, fade) if aa == 0 else col
			_text(Vector2(x, y - 8.0 * _s), lbl, 14, lc, 1, false)
		elif mid:
			_text(Vector2(x, y - 8.0 * _s), "%d" % aa, 9, Color(C_DIM, C_DIM.a * fade * 0.8), 1)
	# centre caret + heading
	var tri := PackedVector2Array([Vector2(cx - 5.0 * _s, y + 20.0 * _s), Vector2(cx, y + 13.0 * _s), Vector2(cx + 5.0 * _s, y + 20.0 * _s)])
	_root.draw_colored_polygon(tri, C_MAIN)
	_text(Vector2(cx, y + 38.0 * _s), "%03d°" % roundi(hdg) if roundi(hdg) < 360 else "000°", 14, C_MAIN, 1)
	# ship bearing marker
	if ship and is_instance_valid(ship):
		var sp := ship.global_position
		if ship.has_method("get_entry_point"):
			sp = ship.get_entry_point()
		var to := sp - player.global_position
		var dist := to.length()
		to -= up * to.dot(up)
		if to.length() > 0.5:
			var b := _heading_of(to.normalized(), up, body)
			var off := wrapf(b - hdg, -180.0, 180.0)
			var clamped := absf(off) > span
			var x := cx + clampf(off, -span, span) * ppd
			var my := y + 4.0 * _s
			var r := 5.0 * _s
			var dia := PackedVector2Array([Vector2(x, my - r), Vector2(x + r, my), Vector2(x, my + r), Vector2(x - r, my), Vector2(x, my - r)])
			_poly(dia, C_OK, 1.4)
			if not clamped:
				var ds := fmt_dist(dist)
				_text(Vector2(x, my + 22.0 * _s), "%s %s" % [ds[0], ds[1]], 10, C_OK, 1)
			else:
				var sgn := signf(off)
				_poly(PackedVector2Array([Vector2(x + sgn * 9.0 * _s, my - 4.0 * _s), Vector2(x + sgn * 13.0 * _s, my), Vector2(x + sgn * 9.0 * _s, my + 4.0 * _s)]), C_OK, 1.2)
