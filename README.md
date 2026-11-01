# Stellar Drift

Прототип космического симулятора на **Godot 4.7**: одна звёздная система, полёт корабля в космосе и атмосфере,
посадка на планеты с любой стороны, прогулка пешком. Главный фокус — максимально красивый космос и планеты,
полностью процедурные (код + шейдеры).

## Скачать и поиграть (Windows)
**[Последняя сборка → Releases / nightly](https://github.com/EugeneValko/stellar-drift/releases/tag/nightly)** —
распаковать zip и запустить `StellarDrift.exe`. В игре **F1** — подсказки по управлению.

## Документация
| Файл | Что внутри |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | Текущее состояние проекта, следующий шаг |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Этапы и задачи |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Масштабы, режимы скорости, устройство систем |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Журнал технических решений |
| [docs/SESSION_LOG.md](docs/SESSION_LOG.md) | Журнал сессий работы |
| [docs/TOOLS.md](docs/TOOLS.md) | Инструменты: скриншоты, видео, сборка, Blender |
| [docs/screenshots/](docs/screenshots/) | Скриншоты по этапам |
| [CLAUDE.md](CLAUDE.md) | Правила для AI-агентов |

## Разработка
```bash
tools/setup_env.sh     # Godot 4.7.2, шаблоны экспорта, Blender, рендер без GPU
tools/check.sh         # проверка скриптов
tools/shot.sh scenes/main.tscn out.png
tools/build_windows.sh # локальная сборка .exe
```
Открыть проект в редакторе: Godot 4.7.2 → Import → `project.godot`.
