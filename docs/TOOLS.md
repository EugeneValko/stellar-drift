# Инструменты

## Окружение
`tools/setup_env.sh` — Godot (версия в `tools/versions.env`), шаблоны экспорта, `mesa-vulkan-drivers` (lavapipe),
Xvfb, ffmpeg, Blender. В облаке нет GPU: рендер идёт через **lavapipe** (Vulkan на CPU) в виртуальном X-сервере —
это настоящий Forward+ со всеми эффектами, просто медленно (секунды на кадр).

## Скриншоты — `tools/shot.sh`
```bash
tools/shot.sh scenes/main.tscn /tmp/a.png                       # один кадр
tools/shot.sh scenes/test/planet.tscn /tmp/a.png --cam=orbit     # пресет камеры
tools/shot.sh scenes/test/planet.tscn --shots=orbit,surface,atmo --outdir=docs/screenshots/s2
tools/shot.sh ... --res=960x540 --warmup=60                      # быстрый превью / дольше прогрев
```
Работает через автозагрузку `Capture` (`src/core/capture.gd`). Сцены поддерживают пресеты так:
узел в группе `capture_target` с методом `apply_capture_preset(name: String)`. Свои параметры читать из `Capture.args`.
`Capture.active == true`, когда идёт съёмка (можно отключить HUD, зафиксировать время и т.п.).

Рекомендуемые имена пресетов: `space_wide`, `star_close`, `orbit`, `atmo_entry`, `low_flight`, `surface`,
`surface_sunset`, `ocean`, `gasgiant`, `rings`, `moon_view`, `ship_hero`, `on_foot`.

## Видео — `tools/movie.sh`
```bash
FPS=30 RES=1280x720 tools/movie.sh scenes/test/flyby.tscn docs/screenshots/s1/flyby.mp4 6
```
Godot Movie Maker с фиксированным FPS — видео плавное независимо от скорости рендера (но рендерится долго).
`tools/dev/movie_av.sh` — то же, но со звуком игры (Movie Maker пишет `frame.wav` рядом с кадрами; WAV кладётся и рядом с mp4).
Демо-полёты главной сцены: `--demo=takeoff|landing` (синхронная загрузка, без интро).

## Звук — `tools/dev/audio_dump.gd`
`godot --headless -s tools/dev/audio_dump.gd -- out=<dir>` — процедурный банк звуков (`Synth.build_bank()`) в WAV
для проверки уровней/спектров без прослушивания.

## Проверка — `tools/check.sh`
Импорт + запуск на 5 кадров headless; падает при ошибках парсинга/скриптов.

## Плейтест игры — `tools/dev/playtest.gd`
`godot --headless --fixed-fps 60 -s tools/dev/playtest.gd -- all` — настоящий `main.tscn`, сценарий
взлёт → орбита → Selene (посадка, выход, 50 м пешком, вход) → варп к Aurelion → назад на Terra + extras (вода,
газовый гигант, звезда) + 3 мин случайного полёта; PASS/FAIL по шагам (`session|extras|soak`, `from=selene`,
`seed=N`, `soak_sec=N`). Подробно — `docs/reports/wave3_integration.md`.
`godot --headless -s tools/dev/terrain_continuity.gd -- preset=selene,nyx` — ступеньки поля высот.

## Сборка Windows
- Локально: `tools/build_windows.sh` → `build/windows/StellarDrift.exe` (PCK встроен в exe).
- CI: `.github/workflows/build-windows.yml`. Пуш в `main` → пре-релиз **nightly** (всегда свежая сборка).
  Тег `v*` → версионный релиз.

## Blender
`blender -b -P tools/blender/<script>.py -- assets/models/<name>.glb` — модель строится скриптом и экспортируется в GLB.
Godot импортирует GLB автоматически. Исходник модели — всегда Python-скрипт (воспроизводимо, правится параметрами).

## Прочее
- `tools/sky_preview.py` — собирает дамп атласа неба в панораму (отладка). Аргументы сцен неба: `--sky_face`, `--dump_sky`, `--tonemap`, `--time_scale`.
- На CPU-рендере шейдеры компилируются асинхронно: если тяжёлые меши пропадают на кадре — увеличить `--warmup`.
