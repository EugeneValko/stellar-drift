# Волна 2D — персонаж пешком, режимы игры, HUD, F1

Скриншоты (1920×1080): `docs/screenshots/s4/` — `onfoot_fp`, `onfoot_tp`, `hud_ship`, `help`.

## Что сделано
| Файл | Назначение |
|---|---|
| `scenes/player/player.tscn`, `src/player/player.gd` | `Player` (CharacterBody3D): сферическая гравитация, ходьба/бег/прыжок, склоны, ступеньки, страховка от провала, камера 1-го/3-го лица, покачивание головы, пыль из-под ног, модель космонавта из примитивов |
| `src/core/game_mode.gd` | `GameMode` (Node в сцене): состояния SHIP / ON_FOOT / FREECAM, посадка/высадка с затемнением, рампа, подсказка «[F] Сесть в корабль», свободная камера через `load()` |
| `scenes/ui/hud.tscn`, `src/ui/hud.gd` | `Hud` (CanvasLayer): процедурный HUD корабля и пешехода + полноэкранное затемнение |
| `scenes/ui/help_overlay.tscn`, `src/ui/help_overlay.gd` | `HelpOverlay`: F1-панель из `Controls.HELP` в две колонки + стартовая подсказка «F1 — управление» |
| `src/player/test_ship_stub.gd` | `TestShipStub`: **только для тестов** — заглушка контракта корабля поверх `ship_visual.tscn` |
| `scenes/test/onfoot_test.tscn` (+`.gd`) | Тестовая сцена: Selene, небо, солнце, Terra Nova в небе, приземлённый корабль, игрок; пресеты съёмки |
| `tools/dev/test_onfoot.gd` | Headless-тест: обход большого круга на сфере и на рельефе Selene |
| `src/core/controls.gd` | **добавлена** строка HELP: `Esc — курсор мыши` (ничего не переименовано) |

## Player (`class_name Player`, `scenes/player/player.tscn`)
- Начало координат узла — **ступни**. Капсула r = 0,33, h = 1,8. Слой коллизии 2, маска 1 (рельеф/корабль на слое 1).
- Каждый физический кадр: `up = Universe.get_up(pos)`, `g = Universe.get_gravity(pos)`, `up_direction = up`;
  тело плавно доворачивается к локальной вертикали (`align_rate`, быстрее при большом рассогласовании),
  горизонтальная скорость **параллельно переносится** при смене вертикали — «вперёд» идёт по большому кругу,
  в том числе по «низу» планеты.
- На земле вертикальная составляющая скорости заменяется прижатием `g·dt` (иначе на выпуклой поверхности
  `is_on_floor()` мигает, а на гребнях персонажа подбрасывает). Склоны: `floor_max_angle = 46°`,
  `floor_constant_speed`, `floor_stop_on_slope`, snap 0,45 м + зависимость от скорости.
- **Ступеньки** до `step_height = 0,35 м` (камни, швы LOD, обрывчики рельефа) — `_try_step_up()` через `test_move`.
- **Страховка**: если аналитическая высота (`body.get_altitude_global`) говорит, что ступни ниже рельефа больше
  чем на `rescue_depth` (коллизия чанка ещё не подгружена), игрок поднимается на поверхность и считается стоящим
  (`analytic_grounded`, счётчик `rescue_count`).
- Мышь: рыскание вокруг локального up (`rotate_yaw`), тангаж головы ±86°. WASD, Shift — бег, Space — прыжок
  (`jump_height` 1 м при любой g). C — 1-е/3-е лицо (SpringArm3D у правого плеча, исключает себя).
- Модель (скафандр, шлем с золотым визором и лампой, ранец с баллонами, оранжевые полосы, ботинки) живёт на
  визуальном слое 20 (`MODEL_LAYER`), который камера 1-го лица не рисует, — тень от себя видна. Ноги/руки качаются
  в такт шагам. Пыль — два `CPUParticles3D` (мировые координаты, сбрасываются при сдвиге origin).
- Floating origin: фокус ставит GameMode (`Universe.set_focus(player)`); в мировых координатах игрок ничего не кэширует.

API:
```gdscript
set_active(on)                  # ввод + физика + камера + видимость
get_camera() -> Camera3D        # активная (1-е или 3-е лицо)
set_third_person(on)            # сигнал camera_mode_changed(bool)
place_at(xform: Transform3D)    # ступни в xform.origin, вертикально по локальному up, лицом по -Z xform
look_at_point(world_pos) / set_pitch_deg(deg) / rotate_yaw(rad)
is_grounded() -> bool           # is_on_floor() или аналитическая страховка
get_flat_forward() / get_horizontal_speed()
var input_enabled, use_sim_input, sim_move/sim_sprint/sim_jump   # для тестов
var rescue_count, step_count, altitude, current_up, current_gravity
signal landed(fall_speed)
```

## GameMode (`class_name GameMode`, узел сцены)
- `@export ship_path`, `player_path` (если пусто — инстанцирует `player.tscn` под `Universe.world_root`),
  `hud_path`, `start_state` (SHIP / ON_FOOT), `interact_distance = 4`, `hatch_open_distance = 10`, `fade_time`.
- **ON_FOOT → SHIP**: F в радиусе 4 м от точки входа (`ship.get_entry_point()` или маркер `ExitPoint` из ShipVisual)
  → затемнение → игрок скрыт/заморожен → `ship.enter_pilot()` → камера корабля (`ship.get_camera()` или первая
  `Camera3D` внутри корабля) → `Universe.set_focus(ship)` → рампа закрывается → проявление.
  Рампа (`ShipVisual.set_hatch`) открывается сама, когда игрок ближе 10 м, и закрывается, когда отходит.
- **SHIP → ON_FOOT**: F при `ship.can_exit()` → затемнение → `xf = ship.exit_pilot()` → `player.place_at(xf)`
  (вертикально по локальному up) → фокус на игрока. Если `can_exit()` = false — сообщение «Сначала посадите корабль».
  Если корабль сам испустит `pilot_exited(xf)` (не через GameMode) — игрок тоже появится.
- **FREECAM**: V. Если `res://src/core/free_camera.gd` существует — `load(...).new()`, добавляется в `world_root`,
  ставится в трансформ текущей камеры, `make_current()` (сам узел или дочерняя Camera3D), опционально
  `set_active(true/false)`, фокус Universe на неё. Игрок замораживается (не падает), у корабля выключается ввод,
  если у него есть свойство `input_enabled` или метод `set_input_enabled(bool)`. Повторное V возвращает прежнее состояние.
  Если файла нет — сообщение «Свободная камера недоступна».
- Esc — показать/захватить курсор; клик в окно — захватить снова.
- Для загрузки/скриптов: `ensure_started()`, `force_on_foot()`, `force_ship()` (без затемнения),
  `set_hatch_open(open, instant)`, `distance_to_hatch()`, `get_state_name()`, сигнал `state_changed(state)`.

### Как подключить в `scenes/main.tscn` (с настоящими Ship и FreeCamera)
```
Main
├─ ... (окружение, солнце, менеджер системы)
├─ World (Node3D)            ← Universe.set_world_root(World)
│  ├─ планеты ...
│  └─ Ship (src/ship/ship.gd)
├─ GameMode (src/core/game_mode.gd)   ship_path = ../World/Ship, hud_path = ../Hud, start_state = SHIP
├─ Hud (scenes/ui/hud.tscn)
└─ HelpOverlay (scenes/ui/help_overlay.tscn)
```
Требования к `Ship` (контракт из задачи + необязательные расширения, которые GameMode/HUD используют, если есть):
- обязательно: `is_piloted`, `enter_pilot()`, `exit_pilot() -> Transform3D` (ступни пилота, −Z = взгляд),
  `can_exit() -> bool`, сигналы `pilot_entered`, `pilot_exited(exit_xform)`, `get_hud_data() -> Dictionary`
  (speed, vertical_speed, mode, mode_name, mode_max_speed, altitude, body_name, target_name, target_distance,
  throttle, gear_down, landed, flight_assist, atmosphere_density, heat, autopilot);
- желательно: `get_camera() -> Camera3D` (иначе берётся первая Camera3D в корабле; если корабль сам делает
  камеру текущей в `enter_pilot()`, это тоже работает), `get_entry_point() -> Vector3` (иначе маркер ExitPoint),
  `get_visual() -> ShipVisual` (иначе первый ShipVisual внутри), свойство `input_enabled` (для FREECAM);
- ключи HUD-данных сверх контракта: `velocity` (Vector3, мир) — иначе HUD оценивает скорость по смещению узла
  (с учётом `origin_shifted`); `target_position` (Vector3) — иначе ищется тело с `get_body_name() == target_name`;
  `target_radius`; `mode_count` (по умолчанию 5; `mode` считается 0-базовым: 0 Hover … 4 Warp).
- Коллизия корабля не должна перекрывать капсулу 1,8 м в `ExitPoint` (в заглушке над открытой рампой коллайдер поднят).
- Ввод корабля при пилотировании — пусть корабль обрабатывает его только при `is_piloted` (C в корабле = кабина/сзади,
  пешком C обрабатывает Player — конфликта нет, т.к. активен только один).
- Фокус рельефа: `Planet.auto_focus_camera = true` (по умолчанию) — LOD и коллизия строятся вокруг текущей камеры;
  в режиме 3-го лица это 3,4 м от игрока — достаточно (radius коллизии 300 м).

## HUD (`class_name Hud`, `scenes/ui/hud.tscn`)
Всё рисуется в `_draw` (линии 1,2–1,6 px с тёмной подложкой и мягким свечением, текст с тёмным контуром —
читается и на ярком реголите, и на чёрном небе). Шрифты — `SystemFont`: моноширинный для чисел
(JetBrains Mono / Cascadia Mono / **Consolas** на Windows / DejaVu Sans Mono), текстовый
(**Bahnschrift** на Windows / Segoe UI / DejaVu Sans). Масштаб — от высоты окна (дизайн под 1080p).
- Корабль: прицел (4 дуги + риски), маркер вектора скорости (prograde; retrograde — кружок с крестом, если
  скорость направлена за спину), цель: уголки-скобки по угловому размеру тела + имя + дистанция, а вне экрана —
  стрелка на краю (эллипс с отступом) с именем/дистанцией; слева сверху TARGET; слева снизу скорость
  (m/s → km/s → Mm/s), режим скорости, полоса скорость/макс., ромбики режимов 1–5, вертикальная полоса тяги
  (обратная тяга — янтарная); справа снизу высота (m/km/Mm), V/S со стрелкой (красная при быстром снижении
  у земли), плотность атмосферы, имя тела; сверху флаги LANDED, GEAR, FA OFF, AUTOPILOT, RE-ENTRY (heat > 0,25,
  мигает), HEAT CRITICAL (> 0,7).
- Пешком: маленький прицел, компас (С/СВ/В…, север = ось +Y тела) с курсом и маркером корабля (дистанция до рампы),
  имя тела, g и скорость; подсказка взаимодействия с «клавишей».
- API: `set_mode(Hud.Mode.SHIP|ON_FOOT|NONE)`, `ship`, `player`, `set_prompt(text, key="F")`, `clear_prompt()`,
  `flash_message(text, sec)`, `fade_to(alpha, time)` (await), `toggle()/set_shown()/is_shown()`, `camera_override`,
  статические `fmt_speed()`, `fmt_dist()`. H — показать/скрыть (затемнение не скрывается).
- При `Capture.active` HUD скрыт, если не передан `--hud`.

## F1 (`class_name HelpOverlay`)
Панель по центру (полупрозрачная, скругления, тонкая рамка), заголовок «УПРАВЛЕНИЕ», строки `Controls.HELP` в две
колонки: клавиши — «клавиши-колпачки» (`W / S` → [W] / [S], `Tab, 1–5` → [Tab] [1–5]), описание — по-русски.
При старте (кроме съёмки) справа внизу 7 с показывается «[F1] — управление», пока игрок хотя бы раз не открыл
панель (запоминается в `user://ui_state.cfg`). API: `toggle()`, `set_open(on, instant)`, `show_hint(sec)`.

## Тестовая сцена `scenes/test/onfoot_test.tscn`
Selene (g = 1,62), небо `space_backdrop`, солнце с тенями, Terra Nova в небе (placeholder-грунт + настоящий
шейдер атмосферы; `--sky_planet=0` отключает), заглушка корабля на самом ровном месте (поиск по 220 кандидатам),
игрок рядом. Играбельна: WASD/мышь/F/C/V/H/F1.
```bash
tools/shot.sh scenes/test/onfoot_test.tscn --shots=onfoot_fp,onfoot_tp,hud_ship,help --outdir=docs/screenshots/s4 --hud
```

## Headless-тест `tools/dev/test_onfoot.gd`
```bash
godot --headless --fixed-fps 60 -s tools/dev/test_onfoot.gd -- [sphere|terrain|all] [stations=36] [gravity=9.81]
ONFOOT_VERBOSE=1 ...   # посекундный журнал непрерывного забега + профиль рельефа при упоре
```
Критерии (после приземления, каждый кадр): стоит на настоящей коллизии (не на страховке), отклонение оси тела от
локальной вертикали < 3°, ступни в пределах [−0,25; +0,35] м (рельеф: +0,6 м) от аналитической поверхности, 0 спасений.

РЕЗУЛЬТАТЫ_ТЕСТА

## Известные проблемы / что слабее
- **Рельеф Selene содержит микро-обрывы** (до ~1,4 м на 10 см) на границах ячеек кратеров (`TerrainGenerator`,
  блок кратеров: при смене ячейки скачут `rad`/порог, а хвост вала ещё не нулевой). Игрок их перешагивает (≤ 0,35 м),
  а большие обходит — в непрерывном забеге десятки «ступенек». Нужна правка генератора (предложена отдельная задача).
- Коллизия рельефа — половинного разрешения (шаг ~0,5–1 м): у ступней возможна разница с видимой сеткой в пару см.
- Анимация космонавта — простое качание конечностей; нет анимации посадки в кабину (только затемнение).
- Заглушка корабля статична, коллайдер — коробки; настоящий `Ship` должен дать свой коллайдер.
- HUD рисуется каждый кадр через `_draw` (~200 примитивов) — дёшево, но не через шейдер.
- На Linux-скриншотах шрифты DejaVu/JetBrains Mono; на Windows будут Bahnschrift/Consolas (вид чуть другой).
- Выход из корабля в воздухе запрещён `can_exit()`; «выпрыгнуть» нельзя (по задумке).

## Изменения общих файлов
- `src/core/controls.gd`: добавлена одна строка в `HELP` (`Esc`). Действия не менялись.
- Остальное — только новые файлы. `project.godot`, `main.tscn`, `universe.gd`, `src/ship/*` не трогал.
