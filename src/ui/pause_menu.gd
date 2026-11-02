class_name PauseMenu
extends CanvasLayer
## Esc pause menu: frosted game view, a slim left column — "STELLAR DRIFT" / ПАУЗА / Продолжить,
## Управление, Звук, Графика, Выход — and a right panel for the controls list, the sound settings
## (Общая громкость / Музыка / Эффекты / Чувствительность мыши) or the graphics options
## (GraphicsSettings: сглаживание, качество неба). Keyboard (↑ ↓ Enter Esc) and
## mouse. Pauses the tree; music keeps playing, effects are paused. Opens by itself when the
## window loses focus. Releases the mouse while open, recaptures it on close.

const C_TEXT := Color(0.88, 0.96, 1.0, 0.96)
const C_DIM := Color(0.78, 0.92, 1.0, 0.5)
const C_ACCENT := Color(1.0, 0.76, 0.34, 1.0)
const C_LINE := Color(0.6, 0.9, 1.0, 0.25)
const TEXT_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans", "sans-serif"]
const MONO_FONTS := ["JetBrains Mono", "Cascadia Mono", "Consolas", "DejaVu Sans Mono", "monospace"]
const BLUR_SHADER := preload("res://shaders/ui_pause_blur.gdshader")

signal opened
signal closed

var is_open := false
## Set by main when the session runs (no pause during loading / captures without it).
var enabled := true
var _scaler: Control
var _root: Control
var _bg: ColorRect
var _bg_mat: ShaderMaterial
var _column: VBoxContainer
var _panel: PanelContainer
var _panel_box: VBoxContainer
var _buttons: Array[Button] = []
var _section := ""
var _font: SystemFont
var _font_thin: SystemFont
var _mono: SystemFont
var _tween: Tween
var _mouse_before := Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("pause_menu")
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(TEXT_FONTS)
	_font.font_weight = 500
	_font_thin = SystemFont.new()
	_font_thin.font_names = PackedStringArray(TEXT_FONTS)
	_font_thin.font_weight = 300
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(MONO_FONTS)
	_mono.font_weight = 600
	_build()
	get_viewport().size_changed.connect(_fit)
	_fit()
	_root.visible = false


func _fit() -> void:
	var vs := get_viewport().get_visible_rect().size
	var k := maxf(vs.y / 1080.0, 0.1)
	_scaler.scale = Vector2(k, k)
	_scaler.size = vs / k
	_bg.size = vs


# ------------------------------------------------------------------ API

func toggle() -> void:
	set_open(not is_open)


func set_open(on: bool, instant := false) -> void:
	if on == is_open or (on and not enabled):
		return
	is_open = on
	if _tween and _tween.is_valid():
		_tween.kill()
	if on:
		_mouse_before = Input.mouse_mode
		get_tree().paused = true
		_show_section("")
		_root.visible = true
		if not Capture.active:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_buttons[0].grab_focus()
		GameAudio.ui("ui_click", -12.0, 0.8)
		if instant:
			_root.modulate.a = 1.0
			_bg_mat.set_shader_parameter("amount", 1.0)
		else:
			_root.modulate.a = 0.0
			_tween = create_tween().set_parallel(true)
			_tween.tween_property(_root, "modulate:a", 1.0, 0.18)
			_tween.tween_method(func(v: float) -> void: _bg_mat.set_shader_parameter("amount", v), 0.0, 1.0, 0.25)
			_column.position.x = -24.0
			_tween.tween_property(_column, "position:x", 0.0, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		opened.emit()
	else:
		get_tree().paused = false
		GameAudio.ui("ui_back", -12.0)
		if not Capture.active and DisplayServer.get_name() != "headless":
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if instant:
			_root.visible = false
		else:
			_tween = create_tween()
			_tween.tween_property(_root, "modulate:a", 0.0, 0.14)
			_tween.tween_callback(func() -> void: _root.visible = false)
		closed.emit()


## Opens a section ("", "controls", "sound") — also used by capture presets.
func show_section(sec: String) -> void:
	_show_section(sec)


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("pause_menu") and not event.is_echo():
		if _section != "":
			_show_section("")
			GameAudio.ui("ui_back", -12.0)
		else:
			set_open(false)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and enabled and not is_open and not Capture.active \
			and DisplayServer.get_name() != "headless" and is_inside_tree():
		set_open(true)


# ------------------------------------------------------------------ building

func _label(text: String, size: int, col: Color, font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font if font else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _menu_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(340, 54)
	b.add_theme_font_override("font", _font_thin)
	b.add_theme_font_size_override("font_size", 28)
	b.add_theme_color_override("font_color", Color(C_TEXT, 0.72))
	b.add_theme_color_override("font_hover_color", C_TEXT)
	b.add_theme_color_override("font_focus_color", C_TEXT)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0)
	normal.content_margin_left = 22
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.6, 0.9, 1.0, 0.06)
	hover.border_color = C_ACCENT
	hover.border_width_left = 2
	hover.content_margin_left = 22
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(func() -> void:
		GameAudio.ui("ui_click", -10.0)
		cb.call())
	b.mouse_entered.connect(func() -> void:
		b.grab_focus())
	b.focus_entered.connect(func() -> void: GameAudio.ui("ui_hover", -20.0))
	return b


func _build() -> void:
	_root = Control.new()
	_root.name = "PauseRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_bg = ColorRect.new()
	_bg_mat = ShaderMaterial.new()
	_bg_mat.shader = BLUR_SHADER
	_bg.material = _bg_mat
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bg)
	_scaler = Control.new()
	_scaler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_scaler)
	# left column
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.add_theme_constant_override("margin_left", 130)
	margin.add_theme_constant_override("margin_top", 250)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scaler.add_child(margin)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 6)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_column)
	var kicker := _label("S T E L L A R   D R I F T", 14, Color(C_ACCENT, 0.9))
	_column.add_child(kicker)
	var title := _label("Пауза", 64, C_TEXT, _font_thin)
	_column.add_child(title)
	var line := ColorRect.new()
	line.color = C_LINE
	line.custom_minimum_size = Vector2(340, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(line)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 18)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(sp)
	_buttons.append(_menu_button("Продолжить", func() -> void: set_open(false)))
	_buttons.append(_menu_button("Управление", func() -> void: _show_section("controls")))
	_buttons.append(_menu_button("Звук", func() -> void: _show_section("sound")))
	_buttons.append(_menu_button("Графика", func() -> void: _show_section("graphics")))
	_buttons.append(_menu_button("Выход", func() -> void: get_tree().quit()))
	for b in _buttons:
		_column.add_child(b)
	var sp2 := Control.new()
	sp2.custom_minimum_size = Vector2(0, 26)
	sp2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(sp2)
	_column.add_child(_label("Esc — назад", 15, C_DIM))
	# right panel
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.04, 0.065, 0.72)
	sb.border_color = C_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 30
	sb.content_margin_bottom = 30
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.position = Vector2(620, 250)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_scaler.add_child(_panel)
	_panel_box = VBoxContainer.new()
	_panel_box.add_theme_constant_override("separation", 14)
	_panel.add_child(_panel_box)


func _clear_panel() -> void:
	for c in _panel_box.get_children():
		c.queue_free()


func _show_section(sec: String) -> void:
	_section = sec
	_clear_panel()
	_panel.visible = sec != ""
	_panel.size = Vector2.ZERO
	match sec:
		"controls":
			_build_controls()
		"sound":
			_build_sound()
		"graphics":
			_build_graphics()


func _build_controls() -> void:
	_panel_box.add_child(_label("Управление", 30, C_TEXT, _font_thin))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 9)
	_panel_box.add_child(grid)
	var rows: Array = Controls.HELP
	var half := ceili(rows.size() / 2.0)
	for i in half:
		for c in 2:
			var j := i + c * half
			if j < rows.size():
				var k := _label(str(rows[j][0]), 16, C_ACCENT, _mono)
				k.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				k.custom_minimum_size = Vector2(120, 0)
				grid.add_child(k)
				var d := _label(str(rows[j][1]), 16, C_TEXT)
				d.custom_minimum_size = Vector2(330, 0)
				d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				grid.add_child(d)
			else:
				grid.add_child(Control.new())
				grid.add_child(Control.new())


func _slider_row(title: String, value: float, cb: Callable, fmt := "%d%%", scale := 100.0) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var l := _label(title, 19, C_TEXT)
	l.custom_minimum_size = Vector2(250, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = value
	s.custom_minimum_size = Vector2(320, 28)
	s.focus_mode = Control.FOCUS_ALL
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(0.6, 0.9, 1.0, 0.85)
	grab.set_content_margin_all(2)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.6, 0.9, 1.0, 0.18)
	track.content_margin_top = 1
	track.content_margin_bottom = 1
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(C_ACCENT, 0.9)
	fill.content_margin_top = 1
	fill.content_margin_bottom = 1
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	row.add_child(s)
	var v := _label(fmt % (value * scale), 17, C_DIM, _mono)
	v.custom_minimum_size = Vector2(70, 0)
	row.add_child(v)
	s.value_changed.connect(func(x: float) -> void:
		v.text = fmt % (x * scale)
		cb.call(x))
	s.drag_ended.connect(func(_c: bool) -> void: GameAudio.ui("ui_click", -14.0))
	_panel_box.add_child(row)


func _build_sound() -> void:
	_panel_box.add_child(_label("Звук", 30, C_TEXT, _font_thin))
	var ga := GameAudio.instance
	for pair: Array in [["Общая громкость", "Master"], ["Музыка", "Music"], ["Эффекты", "SFX"]]:
		var bus: String = pair[1]
		_slider_row(pair[0], ga.get_volume(bus) if ga else float(GameAudio.DEFAULTS[bus]), func(x: float) -> void:
			if GameAudio.instance:
				GameAudio.instance.set_volume(bus, x))
	var sep := ColorRect.new()
	sep.color = C_LINE
	sep.custom_minimum_size = Vector2(0, 1)
	_panel_box.add_child(sep)
	# mouse sensitivity: slider 0..1 maps to x0.25..x4 (log)
	var ms := clampf(log(Controls.mouse_scale / 0.25) / log(16.0), 0.0, 1.0)
	_slider_row("Чувствительность мыши", ms, func(x: float) -> void:
		Controls.set_mouse_scale(0.25 * pow(16.0, x)), "×%.2f", 1.0)
	# the multiplier label shows the scale, not the slider position
	var last := _panel_box.get_child(_panel_box.get_child_count() - 1) as HBoxContainer
	var lbl := last.get_child(2) as Label
	lbl.text = "×%.2f" % Controls.mouse_scale
	(last.get_child(1) as HSlider).value_changed.connect(func(_x: float) -> void:
		lbl.text = "×%.2f" % Controls.mouse_scale)
	_panel_box.add_child(_label("Звук синтезируется процедурно при запуске — без файлов.", 14, C_DIM))


## One option row: title + mutually exclusive buttons (labels), `cb(index)` on change.
func _choice_row(title: String, labels: Array, current: int, cb: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := _label(title, 19, C_TEXT)
	l.custom_minimum_size = Vector2(250, 0)
	row.add_child(l)
	var group := ButtonGroup.new()
	for i in labels.size():
		var b := Button.new()
		b.text = str(labels[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == current
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(150, 40)
		b.add_theme_font_override("font", _font)
		b.add_theme_font_size_override("font_size", 17)
		b.add_theme_color_override("font_color", Color(C_TEXT, 0.6))
		b.add_theme_color_override("font_hover_color", C_TEXT)
		b.add_theme_color_override("font_focus_color", C_TEXT)
		b.add_theme_color_override("font_pressed_color", C_ACCENT)
		b.add_theme_color_override("font_hover_pressed_color", C_ACCENT)
		var off := StyleBoxFlat.new()
		off.bg_color = Color(0.6, 0.9, 1.0, 0.05)
		off.border_color = C_LINE
		off.set_border_width_all(1)
		off.set_corner_radius_all(4)
		var on := off.duplicate() as StyleBoxFlat
		on.bg_color = Color(C_ACCENT, 0.12)
		on.border_color = C_ACCENT
		var hover := off.duplicate() as StyleBoxFlat
		hover.bg_color = Color(0.6, 0.9, 1.0, 0.12)
		b.add_theme_stylebox_override("normal", off)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("focus", hover)
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
		b.toggled.connect(func(on_now: bool) -> void:
			if on_now:
				GameAudio.ui("ui_click", -10.0)
				cb.call(i))
		row.add_child(b)
	_panel_box.add_child(row)


func _build_graphics() -> void:
	_panel_box.add_child(_label("Графика", 30, C_TEXT, _font_thin))
	_choice_row("Сглаживание", ["MSAA 4x", "MSAA 2x", "TAA"], int(GraphicsSettings.aa), func(i: int) -> void:
		GraphicsSettings.aa = i as GraphicsSettings.AA
		GraphicsSettings.save_cfg()
		GraphicsSettings.apply_aa(get_viewport()))
	_choice_row("Облака и атмосфера", ["Высокое", "Среднее"], 1 - GraphicsSettings.sky_quality, func(i: int) -> void:
		GraphicsSettings.sky_quality = 1 - i
		GraphicsSettings.save_cfg()
		GraphicsSettings.apply(get_viewport(), get_tree().root.find_child("SolarSystem", true, false) as SolarSystem))
	var sep := ColorRect.new()
	sep.color = C_LINE
	sep.custom_minimum_size = Vector2(0, 1)
	_panel_box.add_child(sep)
	for t: String in ["MSAA 4x — самые гладкие края, дороже всего (+1,5 мс к 2x).",
			"MSAA 2x — по умолчанию: чётко в движении.",
			"TAA — чуть быстрее (−1 мс), мягче трава и зерно облаков, в движении картинка мягче.",
			"Среднее небо — меньше шагов облаков и атмосферы (−1,5…−2,5 мс у земли)."]:
		var l := _label(t, 14, C_DIM)
		l.custom_minimum_size = Vector2(560, 0)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_panel_box.add_child(l)
