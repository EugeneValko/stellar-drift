# HANDOFF — как продолжить проект с локального компьютера

> Этот файл — точка входа для **любой новой сессии/агента**. Прочитать целиком перед работой.
> Написан 2026-11-02 навигатором облачной сессии при переходе на локальную разработку (Windows + RTX 3060).

---

## 1. Где мы сейчас (кратко)

**Stellar Drift** — прототип на Godot 4.7.2: одна звёздная система (звезда Helios, планеты Ignis, Terra Nova + луна Selene,
Glacia, газовый гигант Aurelion с кольцами + луны Vex и Nyx), один корабль, полёт космос ↔ атмосфера ↔ поверхность,
посадка в любой точке сферы, выход пешком. Цель №1 — максимальная красота. Платформа — Windows.

| Что | Состояние |
|---|---|
| `main` | **Играбельно + вся волна 4 влита**: корабль v2, яркие закаты/ночь/туманность, красота поверхности, процедурный звук, экран загрузки, меню паузы (Esc), кинокамера, мягкие посадки. Playtest **20/20** (2026-11-02, на объединённой версии). |
| Nightly-сборка | https://github.com/EugeneValko/stellar-drift/releases/tag/nightly — собирается CI на каждый пуш в `main` |
| Волна 4 | Влита в main через `wave4-combined`, но агенты были остановлены лимитом: **часть проверок не сделана вживую** (см. §4) |
| Дальше | Живая проверка волны 4 на ПК и мелкие доделки (§4) → волна 5 (финал, релиз v0.1) → (опционально) оптимизация |

Готовность ≈ 85–90 %. Подробности: `docs/STATUS.md`, `docs/ROADMAP.md`, журнал — `docs/SESSION_LOG.md`.

---

## 2. Настройка локального компьютера (Windows) — один раз

1. Git, PowerShell 5+ (есть в Windows), Claude Code (Desktop app → Code, или CLI).
2. `git clone https://github.com/EugeneValko/stellar-drift` (у пользователя уже склонирован).
3. **Godot + шаблоны экспорта:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools/setup_windows.ps1
   ```
   Ставит Godot 4.7.2 (console exe) в `C:\Tools\Godot`, шаблоны в `%APPDATA%\Godot\export_templates\4.7.2.stable`,
   пишет путь в `tools/.godot_path.txt` (gitignored). Версия — в `tools/versions.env` (единый источник для CI и локально).
4. Опционально: **Blender 5.2** (перегенерация корабля/флоры: `blender -b -P tools/blender/<script>.py -- assets/models/<name>.glb`),
   **ffmpeg** на PATH (видео), **Python 3 + numpy** (`tools/textures/make_ground_textures.py`, `tools/dev/sky_sim.py`).
5. Проверка: `powershell -ExecutionPolicy Bypass -File tools/check.ps1` → `[check] OK`.

Открыть в редакторе: Godot 4.7.2 → Import → `project.godot`. Главная сцена — `scenes/main.tscn`.

### Инструменты (Windows `.ps1` / Linux `.sh`)
| Задача | Windows | Linux/облако |
|---|---|---|
| Проверка скриптов | `tools/check.ps1` | `tools/check.sh` |
| Скриншот(ы) | `tools/shot.ps1 <scene> out.png [--cam=preset]` / `--shots=a,b --outdir=dir` | `tools/shot.sh ...` |
| Видео | `tools/movie.ps1 <scene> out.mp4 <sec> [--cam=..]` | `tools/movie.sh ...` |
| Сквозной автотест | `tools/playtest.ps1` (≈ 3–5 мин на ПК) | `godot --headless --fixed-fps 60 -s tools/dev/playtest.gd -- all seed=7` |
| FPS | `tools/fps_bench.ps1 <scene> 20`, точнее `tools/dev/gpu_bench.ps1 -Views "main:terra_low,..."` | — |
| Сборка .exe | `tools/build_windows.ps1` → `build/windows/StellarDrift.exe` | `tools/build_windows.sh` |

Все `.ps1` используют `--fullscreen` (иначе на мониторе 1920×1080 окно ужимается панелью задач) и `--fixed-fps 60`
(детерминированное TIME → кадры воспроизводимы). Во время съёмки экран на 1–2 с занят Godot — это нормально.
Пресеты камер главной сцены (`scenes/main.gd`): `start, takeoff, takeoff_dust, orbit_chase, orbit_idle, cockpit_view, terra_orbit,
terra_limb_sunrise, terra_entry, terra_low, terra_ground, terra_sunset_ground, terra_night_ground, selene_orbit,
selene_surface_terra_rise, selene_landed_onfoot, landing_selene, ignis_low, ignis_orbit, glacia_low, glacia_orbit, vex_orbit,
vex_aurelion, aurelion_rings, aurelion_arrival, star_from_ignis, system_overview, warp_to_aurelion, warp_game, warp_dropout,
reentry_game, landing_selene, warp_dropout, orbit_idle, pause_menu, loading_screen, intro`. `--hud` показывает HUD на кадре.

Производительность на RTX 3060 (1080p, до волны 4): космос ~220 FPS, орбита 94, у земли 70, лес 50 — см. `docs/reports/perf_gpu.md`.

---

## 3. Карта репозитория

```
project.godot            autoloads: Capture, Universe, Controls; shader_globals sun_*
scenes/main.tscn/.gd      ГЛАВНАЯ сцена: SolarSystem + GameMode + Ship + HUD + F1 + capture-пресеты
scenes/test/*.tscn        тестовые сцены каждой подсистемы (space, planet, atmo, scatter, ship, flight, onfoot, sky)
src/core/                 universe.gd (тела, гравитация, floating origin), controls.gd (клавиши + текст F1),
                          capture.gd (скриншоты), game_mode.gd (корабль/пешком/свободная камера), free_camera.gd, system_def.gd
src/system/solar_system.gd  сборка системы, scaled space, свет по группам тел, экспозиция, вкл. флоры у ближней планеты
src/space/                небо (запечённый атлас), звезда Helios, space_environment.tres (ACES, glow)
src/planets/              planet.gd, planet_config.gd + presets/*.tres, planet_terrain.gd (quadtree LOD), terrain_generator.gd
src/planets/atmosphere/   атмосфера, облака, океан, газ-гигант, кольца (компоненты Planet)
src/planets/scatter/      флора и камни (PlanetScatter, ScatterBiome = CPU-копия биомов шейдера рельефа)
src/ship/                 ship.gd (полёт), ship_visual.gd (модель/материалы), ship_fx.gd, ship_camera.gd
src/player/, src/ui/      персонаж, HUD, F1, меню паузы, экран загрузки, интро
src/audio/                процедурный звук: synth, game_audio, music_pad
shaders/                  все шейдеры (+ include/)
tools/                    скрипты окружения/съёмки/сборки, blender/, dev/ (playtest, бенчи), textures/
assets/models/            GLB из Blender-скриптов (ship.glb, флора, камни, кристаллы); assets/textures/ — оффлайн-текстуры земли
docs/                     STATUS, ROADMAP, ARCHITECTURE, DECISIONS, SESSION_LOG, TOOLS, LOCAL_RENDER, HANDOFF (этот файл)
docs/reports/             отчёты каждой волны (API, параметры, известные проблемы) — читать отчёт системы перед правкой
docs/screenshots/         s0…s6 по этапам, local/ — рендеры с GPU пользователя
.github/workflows/build-windows.yml   CI: пуш в main → релиз nightly; тег v* → релиз
```

Отчёты (что внутри и где API): `stage1_space`, `stage2_terrain`, `stage2_atmosphere`, `stage3_ship_model`, `wave2_system`,
`wave2_ship_flight`, `wave2_player_ui`, `wave2_flora`, `wave3_integration`, `perf_gpu`, `wave4_ground`, `wave4_ship_v2`,
`wave4_sky`, `wave4_gameplay`.

---

## 4. Волна 4 — влита, но требует живой проверки

Агенты 4A/4B/4D были остановлены лимитом использования; незакоммиченное сохранено WIP-коммитами, три ветки объединены в
`wave4-combined` и **влиты в main** (2026-11-02): `tools/check.sh` OK, playtest **20/20** (посадка на Selene 1.4 м/с вместо 4.5,
на Terra 0.8 м/с). Ветки `wave4-ship-v2`, `wave4-sky`, `wave4-gameplay`, `worktree-agent-*` можно удалить — всё в main.

Что НЕ проверено (сделать первым на ПК, `docs/reports/wave4_*.md` — подробности):
- [ ] **Звук** (`src/audio/`: synth, game_audio, music_pad) — прослушать вживую: громкость, отсутствие щелчков, музыка не надоедает. Громкости — меню паузы (Esc).
- [ ] **Облёт камеры на стоянке** (через ~20 с без ввода) и выход из него любым вводом; кинокамера (пружина, тряска).
- [ ] Последний WIP 4D (`ship_fx.gd`, `hud.gd`, `ship_plasma.gdshader`) — визуально в полёте: плазма при входе, HUD.
- [ ] Корабль v2 с chase-камеры днём/ночью/в тени Selene; кабина (C); прожекторы ночью.
- [ ] Небо 4B: кадры «после» сняты не для всех видов (`docs/screenshots/s6/sky/`); отчёт `wave4_sky.md` — черновик, дописать.
- [ ] Отчёт `wave4_ship_v2.md`: строка `PLAYTEST_PLACEHOLDER` → «20/20 на объединённой версии 2026-11-02».
- [ ] **Время загрузки**: headless в облаке 48 с (было ~20 с; облако было нагружено) — замерить на ПК; если > 20 с — найти причину
      (новые текстуры земли? звуковой банк ~4 с? флора?).
- [ ] FPS после волны 4 (`tools/dev/gpu_bench.ps1`) — шейдер рельефа стал тяжелее (+≈25 выборок у земли); только замерить и записать.

## 5. Что осталось

### Волна 5 — финал v0.1
- [ ] Живая проверка на ПК (§4): звук, управление, FPS, загрузка; исправить найденное, playtest 20/20.
- [ ] Финальные скриншоты (`docs/screenshots/final/`) + 1–2 видео (взлёт с Terra Nova, варп к Aurelion, закат) через `tools/movie.ps1`.
- [ ] README: картинки, управление, ссылка на релиз.
- [ ] Релиз: `git tag v0.1 && git push origin v0.1` → CI создаст GitHub Release с zip.

### Известные слабые места (из отчётов, для полировки)
- Ignis сверху (нужны лавовые озёра и пепельные равнины в самой форме рельефа); горы издалека — гладкие конусы (нет эрозии);
  реки — шум, а не сток; хвойные всё ещё стилизованные; ледяные шпили/кристаллы плоскогранные (`wave4_ground.md`).
- Облака вблизи местами зернистые; кучевые с 30 км комковатые (частично исправлено в `wave4-sky`).
- Автопилот: качание тяги при облёте (исправлено в `wave4-gameplay`, проверить).
- Пиксельно малые планеты исчезают (нет точечных спрайтов дальних тел).
- Загрузка ~20 с (Terra рельеф 12 с, флора 4.5 с; в `wave4-gameplay` — экран загрузки с прогрессом).
- Physics interpolation выключена (floating origin сдвигает на 2 км внутри тика) — на 144 Гц возможна ступенчатость в варпе.
- TIME в Godot сбрасывается раз в час → прыжок волн/облаков раз в час.

### Оптимизация (отложена решением пользователя; делать после v0.1)
Цель — 60 FPS на RTX 2060 (≈ 80 на RTX 3060). Узкие места (замеры `docs/reports/perf_gpu.md`):
1. Тени ~3.9 мс у земли: `directional_shadow/size` 8192 → 4096, меньше сплитов, короче `shadow_max_distance` (SolarSystem, project.godot).
2. Шейдер рельефа ~7 мс у земли (+≈25 выборок после волны 4C): профилировать октавы шума в фрагменте, triplanar, `lod_factor`.
3. Флора: 600+ draw calls (слить мелкие слои в патче), тени флоры ~2.2 мс.
4. Облака/атмосфера уже ускорены ×2 (квадовый raymarch) — держать.
Инструмент: `tools/dev/gpu_bench.ps1`, `tools/dev/gpu_ab.ps1` (A/B со снимками).

---

## 6. Критичные знания (грабли, на которые уже наступили)

1. **Камера: far/near ≤ ~1e7**, иначе Godot 4.7 отсекает ВСЕ меши. Поэтому **scaled space**: визуал дальних групп тел масштабируется
   к камере (узел тела остаётся на истинной позиции). SolarSystem ставит `far = near × 4e6`. Near ≥ 0.1.
2. **Порядок обработки**: активная камера двигается ДО SolarSystem (`process_priority` −100; FreeCamera −1000), иначе дальние тела отстают на кадр.
3. **Floating origin** (`Universe`): всё плавающее — дети `Main/World` (`world_root`); корабль — **прямой** ребёнок world_root;
   сдвиг при > 2 км; истинные позиции — 64-bit `origin_x/y/z`. Кто кеширует мировые позиции — слушает `origin_shifted(delta)`.
4. **Свет**: один главный DirectionalLight с тенями + 4 «групповых» без теней (render layers). **Не добавлять свои DirectionalLight.**
   Солнце в шейдерах — глобальные `sun_direction/sun_color/sun_intensity` + per-body `body_sun_dir`.
5. **Прозрачные слои планет**: порядок через `render_priority` (океан −10, атмосфера −9/−8, облака −7, кольца −6), SolarSystem сортирует группы по дальности.
6. **ScatterBiome ↔ шейдер рельефа**: формулы биомов продублированы на CPU — меняешь одно, меняй другое (иначе лес на песке).
7. **Коллизия рельефа** строится вокруг фокуса (`Planet.set_focus_global`, второй фокус `set_focus2`) — если корабль далеко от камеры, фокус должен следовать за кораблём/игроком (GameMode это делает).
8. **Ввод** регистрируется в коде (`Controls`), не в project.godot; текст F1 — `Controls.HELP`.
9. **Скриншоты**: `--fixed-fps 60`; после перегенерации GLB — `godot --headless --import`; на CPU шейдеры компилируются асинхронно → больше `--warmup`.
10. **Облако (Linux без GPU)**: кадр main.tscn ~20 мин и ~3 ГБ RAM, два рендера параллельно → OOM. Локально на RTX 3060 — ~1–2 с. Поэтому работаем локально.
11. **Агенты и лимиты**: агент может оборваться в любой момент → коммитить и пушить после каждой подзадачи, отчёт писать по ходу.
12. **Документация после каждого шага**: STATUS / SESSION_LOG / ROADMAP / DECISIONS (см. CLAUDE.md).

---

## 7. Как вести работу агентами локально (процесс, который сработал)

- **Навигатор** (главная сессия) не пишет крупный код сам: делит работу на волны, раздаёт агентам **непересекающиеся зоны файлов**,
  проверяет их скриншоты глазами, сливает ветки, обновляет docs, отчитывается пользователю по-русски со скриншотами.
- Каждый агент — в своей git-ветке/worktree (`isolation: worktree`), коммитит часто, пушит ветку, пишет `docs/reports/<wave>_<area>.md`.
- Агент **не трогает** STATUS/ROADMAP/SESSION_LOG (это делает навигатор при слиянии) и чужие зоны (только описывает нужные изменения в отчёте).
- Перед слиянием: `tools/check.ps1`; для изменений полёта/рельефа/корабля/игрока — `tools/playtest.ps1` (20/20).
- Шаблон брифа агента (заполнить): цель и «почему»; что прочитать (CLAUDE.md, HANDOFF.md, нужные отчёты); зона файлов «твоё / не трогать»;
  конкретный список задач с критериями; какие пресеты снять и куда (`docs/screenshots/<этап>/<область>/`, ≤ 10 кадров);
  проверки (check, playtest); формат финального ответа (ветка, коммиты, пути скриншотов, что хорошо/плохо, изменения общих файлов).
- На ПК рендер быстрый — агенты могут итерировать по кадрам 1080p сразу; несколько агентов одновременно съёмку в fullscreen не делают
  (одно окно на экран) — съёмку можно сериализовать или снимать `--res` меньшего размера.

### Стартовый промпт для новой локальной сессии-навигатора
> Ты навигатор проекта Stellar Drift. Прочитай `CLAUDE.md`, `docs/HANDOFF.md`, `docs/STATUS.md`, последние записи `docs/SESSION_LOG.md`.
> Окружение: Windows, Godot через `tools/.godot_path.txt` (если нет — `tools/setup_windows.ps1`). Первая задача — §4 HANDOFF:
> живая проверка волны 4 (§4) и исправления, затем волна 5 (релиз v0.1). Отчитывайся мне по-русски
> по этапам со скриншотами; документацию обновляй после каждого шага.
