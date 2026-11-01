extends Node
## Controls (autoload): registers all input actions in code (single source of truth, no
## project.godot conflicts). Help text for F1 is generated from HELP below.

const KEYS := {
	# shared movement (ship thrust axes / on-foot movement)
	"move_forward": [KEY_W], "move_back": [KEY_S],
	"move_left": [KEY_A], "move_right": [KEY_D],
	"move_up": [KEY_SPACE], "move_down": [KEY_CTRL],
	"roll_left": [KEY_Q], "roll_right": [KEY_E],
	"boost": [KEY_SHIFT],
	# ship
	"speed_mode_next": [KEY_TAB],
	"mode_1": [KEY_1], "mode_2": [KEY_2], "mode_3": [KEY_3], "mode_4": [KEY_4], "mode_5": [KEY_5],
	"ship_stop": [KEY_X],
	"gear_toggle": [KEY_G],
	"target_next": [KEY_T],
	"autopilot": [KEY_R],
	"flight_assist_toggle": [KEY_Z],
	# common
	"interact": [KEY_F],
	"camera_toggle": [KEY_C],
	"freecam_toggle": [KEY_V],
	"help": [KEY_F1],
	"hud_toggle": [KEY_H],
	"screenshot": [KEY_F12],
	"pause_menu": [KEY_ESCAPE],
	"mouse_sens_down": [KEY_BRACKETLEFT],
	"mouse_sens_up": [KEY_BRACKETRIGHT],
}

## Displayed by the F1 overlay. Keep in sync with gameplay code.
const HELP := [
	["Мышь", "Тангаж / рыскание (корабль), обзор (пешком)"],
	["W / S", "Тяга вперёд / назад · идти"],
	["A / D", "Смещение влево / вправо"],
	["Space / Ctrl", "Вверх / вниз · прыжок"],
	["Q / E", "Крен"],
	["Shift", "Форсаж · бег"],
	["Tab, 1–5", "Режим скорости: посадка / атмосфера / космос / круиз / варп"],
	["X", "Полная остановка"],
	["G", "Шасси"],
	["T", "Следующая цель"],
	["R", "Автопилот к цели"],
	["Z", "Flight assist вкл/выкл"],
	["F", "Выйти из корабля / сесть"],
	["C", "Камера: кабина / сзади"],
	["V", "Свободная камера (колесо — скорость)"],
	["H", "Скрыть HUD"],
	["F12", "Скриншот"],
	["Esc", "Курсор мыши: показать / захватить"],
	["[ / ]", "Чувствительность мыши − / +"],
	["F1", "Эта подсказка"],
]


## Global mouse-look multiplier (ship stick, on-foot look, free camera); `[` / `]` change it in
## steps of x1.25, saved in user://settings.cfg.
var mouse_scale := 1.0
const SETTINGS_PATH := "user://settings.cfg"
signal mouse_scale_changed(scale: float)


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		mouse_scale = clampf(float(cfg.get_value("input", "mouse_scale", 1.0)), 0.1, 10.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed("mouse_sens_up"):
		set_mouse_scale(mouse_scale * 1.25)
	elif event.is_action_pressed("mouse_sens_down"):
		set_mouse_scale(mouse_scale / 1.25)


func set_mouse_scale(v: float) -> void:
	mouse_scale = clampf(v, 0.1, 10.0)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("input", "mouse_scale", mouse_scale)
	cfg.save(SETTINGS_PATH)
	mouse_scale_changed.emit(mouse_scale)


func _enter_tree() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
