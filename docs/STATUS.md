# STATUS — где мы сейчас

**Обновлено:** 2026-11-01 · **Текущий этап:** волна 2 (интеграция системы, полёт, флора, пешком+HUD)

## Готово (в main)
- Этап 0: инфраструктура, CI (nightly-релиз на каждый пуш), локальный GPU-рендер на ПК пользователя (RTX 3060, `docs/LOCAL_RENDER.md`).
- Этап 1: небо, звезда Helios, блики, окружение — `scenes/test/space_test.tscn`, отчёт `docs/reports/stage1_space.md`.
- Этап 2a: рельеф планет (quadtree LOD), 6 пресетов — `scenes/test/planet_test.tscn`, `docs/reports/stage2_terrain.md`.
- Этап 2b: атмосфера, облака, океан, газ-гигант, кольца — `scenes/test/atmo_test.tscn`, `docs/reports/stage2_atmosphere.md`.
- Этап 3a: модель корабля v1 — `scenes/test/ship_test.tscn`, `docs/reports/stage3_ship_model.md`.
- Контракты: autoload `Universe` (тела, гравитация, floating origin), `Controls` (клавиши + F1).

## В работе (волна 2, агенты в worktree-ветках)
- 2A: сборка всей системы в `scenes/main.tscn`, scaled space, свободная камера, освещение; доводка облаков/рельефа.
- 2B: летающий корабль `scenes/ship/ship.tscn`: 6DOF, режимы скорости, автопилот, посадка, VFX.
- 2C: растительность и камни (`src/planets/scatter`), модели Blender.
- 2D: персонаж пешком, GameMode (корабль/пешком/свободная камера), HUD, F1.
- Локальная сессия (ПК): GPU-рендер всех тестовых сцен + замер FPS → `docs/screenshots/local/wave1/`.

## Известные проблемы
- **Производительность (RTX 3060, 1080p):** космос 220 FPS, рельеф 116–146, атмосфера+облака+океан 57–80 (худший — `ocean_glint` 57). Для RTX 2060 нужен проход оптимизации облаков/океана. Подробно: `docs/screenshots/local/wave1/perf.md`.
- far/near камеры ≤ 1e7 (Godot) → нужен scaled space (делает 2A).
- Микро-обрывы до 1.4 м на границах ячеек кратеров (TerrainGenerator) — мешают ходьбе по лунам → исправить в волне 3.
- Облака с орбиты «попкорн», высоты рельефа преувеличены, корабль похож на самолёт (v2 позже).
- В nightly-сборке пока тестовая сцена (main.tscn ещё не собран).

## Следующий шаг
- Влить волну 2 → интеграция GameMode + Ship + Player в main → первый играбельный билд → GPU-проверка на ПК.

## Как продолжить после обрыва сессии
1. `tools/setup_env.sh`
2. Прочитать этот файл, `ROADMAP.md`, последние записи `SESSION_LOG.md`, `git log --oneline -20`, `git branch -r` (ветки агентов `worktree-agent-*`).
3. Незавершённые ветки агентов: проверить отчёты `docs/reports/*` в ветках, влить готовые.
