# Журнал сессий

## 2026-11-01 — Сессия 1, этап 0 (навигатор)
- Создана структура проекта, документация, `CLAUDE.md`.
- Установлены Godot 4.7.2 + шаблоны, lavapipe, Xvfb, ffmpeg, Blender 5.2.3. Скрипт `tools/setup_env.sh`.
- Проверено: скриншот Forward+ из облака (~25 с/кадр), Blender headless → GLB, локальная сборка `.exe` (105 МБ).
- Добавлен CI: `.github/workflows/build-windows.yml` (nightly-релиз).
