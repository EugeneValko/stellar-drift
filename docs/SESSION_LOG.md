# Журнал сессий

## 2026-11-01 — Сессия 1, этап 0 (навигатор)
- Создана структура проекта, документация, `CLAUDE.md`.
- Установлены Godot 4.7.2 + шаблоны, lavapipe, Xvfb, ffmpeg, Blender 5.2.3. Скрипт `tools/setup_env.sh`.
- Проверено: скриншот Forward+ из облака (~25 с/кадр), Blender headless → GLB, локальная сборка `.exe` (105 МБ).
- Добавлен CI: `.github/workflows/build-windows.yml` (nightly-релиз).
- CI исправлен (чтение versions.env), первый успешный nightly: StellarDrift-windows-33e96fc.zip (38 МБ).
- Запущены 4 агента параллельно (worktrees): космос+звезда, рельеф планет, атмосфера/океан/газ-гигант, корабль (Blender).
- Подключена локальная сессия на ПК пользователя (Remote Control, RTX 3060): рендер 1080p ≈ 1.8 с/кадр. Скрипты `tools/*.ps1`, `docs/LOCAL_RENDER.md`.
- Влит этап 3a: корабль v1 (ветка worktree-agent-a62c838b704c1bb67). Отчёт `docs/reports/stage3_ship_model.md`. Замечания: силуэт как у реактивного самолёта, дуги кабины, створки шасси.
- Влит этап 1 (ветка worktree-agent-a228ea92ec0c026a4): небо, звезда Helios, блики, окружение. Отчёт `docs/reports/stage1_space.md`. Находка: far/near ≤ 1e7 → scaled space.
- Влит этап 2b (ветка worktree-agent-a4754233eca952b1c): атмосфера, облака, океан, газ-гигант, кольца; shader_globals `sun_direction/sun_color/sun_intensity` в project.godot. Отчёт `docs/reports/stage2_atmosphere.md`.
- Влит этап 2a (ветка worktree-agent-ae8880ba5a545a7ba): рельеф планет, 6 пресетов. Отчёт `docs/reports/stage2_terrain.md`.
- Навигатор: autoload `Universe` (реестр тел, гравитация, плотность атмосферы, floating origin), `Controls` (раскладка + текст F1). Planet реализует интерфейс тела.
- Влита волна 2D (ветка worktree-agent-a39a69a1827d2ebad): Player, GameMode, HUD, F1. Отчёт `docs/reports/wave2_player_ui.md` (там же инструкция по подключению в main).
- Влита волна 2C (ветка worktree-agent-a375ead7b7a66ef87): флора и камни. Отчёт `docs/reports/wave2_flora.md`.
- Влита волна 2B (ветка worktree-agent-a78af03e5256bca68): летающий корабль. Отчёт `docs/reports/wave2_ship_flight.md`. TODO интеграции: terra_nova atmosphere_height 8000 → ~24000 (видимая атмосфера 24 км); ship — прямой ребёнок world_root.
- Влита волна 2A (ветка worktree-agent-a9f715c4003145118): вся система в `scenes/main.tscn`, scaled space, освещение по группам тел, экспозиция, FreeCamera, доработки облаков/рельефа/Ignis. Отчёт `docs/reports/wave2_system.md`. Волна 2 завершена.
- Влита волна 3 (ветка worktree-agent-ab914c52ff93137f9): первая играбельная сборка, playtest 20/20. Отчёт `docs/reports/wave3_integration.md`. Известно: корабль тёмный со спины/в тени, жёсткие посадки на Selene, загрузка ~20 с.
- Влита ветка `perf-gpu` (локальная сессия на RTX 3060): квадовый 2×2 raymarch облаков/атмосферы (~2× дешевле), уровни качества флоры. FPS: terra_orbit 77→94, terra_ground 60→70, ocean_glint 59→85. Отчёт `docs/reports/perf_gpu.md`. Дальше: тени (8192→4096, сплиты) и шейдер рельефа (~7 мс у земли).
- Решение пользователя: оптимизацию отложить, волна 4 — только красота и доводка до финального билда; ПК пользователя в план не закладывать. Запущены 4 агента (4A–4D).
- Влита волна 4C (ветка worktree-agent-a1fe75c82a2246a92): красота поверхности, playtest 20/20. Отчёт `docs/reports/wave4_ground.md`. Примечание: рендер main.tscn в облаке ~20 мин и ~3 ГБ RAM — не рендерить параллельно.
