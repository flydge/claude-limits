# claude-limits

**Установка:** вставьте в Claude Code (терминал или приложение Claude) одну фразу:

```
Установи https://github.com/flydge/claude-limits
```

Агент сам склонирует репозиторий, запустит установщик и проверит результат по [AGENTS.md](AGENTS.md).

> **For AI agents:** follow [AGENTS.md](AGENTS.md). In short: clone to `~/claude-limits`
> (or `git -C ~/claude-limits pull --ff-only`), run `~/claude-limits/install.sh`, act on its
> exit code (0 done, 1 fix the `fail` lines, 2 install the named requirement, 3 ask the user
> about their existing `statusLine`), then run `~/claude-limits/install.sh check`.

Расход 5-часового и недельного лимита подписки Claude (Pro или Max) всегда перед глазами,
в трёх местах:

| Где | Как выглядит |
|---|---|
| **Строка статуса Claude Code** в терминале | ![Строка статуса](docs/images/statusline.svg) |
| **Над полем ввода** во вкладке Code приложения Claude | ![Кольца над полем ввода](docs/images/band.svg) |
| **Строка меню macOS** — два кольца, детали по клику | ![Кольца в строке меню, светлая и тёмная тема](docs/images/menubar.png) |

Цвет следует порогам: зелёный до 60 %, жёлтый (оранжевый) до 85 %, дальше красный.
Если в текущем темпе лимит кончится раньше сброса, рядом появляется прогноз «кончится ~15:40».

## Почему своё, а не готовое расширение

Готовые расширения для claude.ai часто читают cookie `sessionKey` или OAuth-токен
из `~/.claude/.credentials.json` и ходят в недокументированные эндпоинты. Здесь ничего этого нет:

- **строка статуса** читает только JSON, который Claude Code сам передаёт ей на stdin
  (`rate_limits.five_hour` и `rate_limits.seven_day`);
- **мод для приложения** берёт те же цифры у движка Claude Code (`$.session.usage()`
  и событие `session.measure`);
- **значок в строке меню** читает копию этих данных из `~/.claude/limits.json`, которую пишут
  первые два.

Никакой сети, токенов и cookie.

```
Claude Code (терминал) ──stdin──▶ statusline-limits.sh ──▶ строка статуса
                                          │
Claude (приложение) ──$.session──▶ мод limit-rings ──▶ кольца над полем ввода
                                          │
                                          ▼
                              ~/.claude/limits.json ──▶ ClaudeLimits.app (строка меню)
```

Файл перезаписывается только свежими данными: простаивающая сессия не затирает то,
что недавно записала другая. Если данных нет больше 30 минут, кольца в строке меню сереют.

## Установка вручную

Требования: macOS 13+, `jq`, Command Line Tools (`swiftc`), подписка Claude Pro или Max.

```bash
git clone https://github.com/flydge/claude-limits.git ~/claude-limits && ~/claude-limits/install.sh
```

Установщик ставит все три части сразу и безопасен при повторном запуске:

- **строка статуса** — скрипт в `~/.claude/` и блок `statusLine` в `~/.claude/settings.json`
  (старый файл сохраняется рядом);
- **значок в строке меню** — `~/Applications/ClaudeLimits.app` и автозапуск при входе;
- **кольца в приложении** — плагин `limit-rings@flydge` из маркетплейса `flydge/claude-limits`.
  В терминальном Claude Code он ничего не рисует, там уже есть строка статуса.

Флаги: `--no-statusline`, `--no-menubar`, `--no-mod`, `--force-statusline` (заменить чужую
строку статуса). Проверка: `~/claude-limits/install.sh check`. Удаление:
`~/claude-limits/install.sh uninstall`. Обновление:
`git -C ~/claude-limits pull --ff-only && ~/claude-limits/install.sh`.

## Устройство репозитория

| Папка | Что внутри |
|---|---|
| `statusline/` | bash-скрипт строки статуса и его тесты |
| `menubar/` | приложение строки меню на Swift/AppKit без Xcode-проекта: логика (`LimitsCore.swift`) отдельно от интерфейса |
| `mod/limit-rings/` | мод для приложения Claude: кольца над полем ввода |
| `install.sh`, `tests/` | установщик для агентов и его тесты |
| `tools/readme-images.py` | перерисовывает картинки этого README из настоящего кода |
| `docs/superpowers/` | спецификация и план реализации |

## Разработка

```bash
bash statusline/test/run.sh          # тесты строки статуса
bash menubar/test.sh                 # тесты логики строки меню
claude plugin test mod/limit-rings   # тесты мода
bash tests/install.test.sh           # тесты установщика (временный HOME, заглушки claude и launchctl)
bash menubar/build.sh                # сборка build/ClaudeLimits.app
python3 tools/readme-images.py       # картинки для README
```
