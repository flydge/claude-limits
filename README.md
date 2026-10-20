# claude-limits

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

## Установка

Требования: macOS 13+, `jq`, Command Line Tools (`swiftc`), подписка Claude Pro или Max.

### Строка статуса и значок в строке меню

```bash
git clone https://github.com/flydge/claude-limits.git && cd claude-limits && ./install.sh
```

Затем добавьте в `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline-limits.sh",
  "refreshInterval": 60
}
```

Автозапуск значка при входе в систему:

```bash
bash menubar/install-launch-agent.sh
```

### Кольца над полем ввода в приложении Claude

В приложении: «+» рядом с полем ввода → Plugins → Add marketplace → `flydge/claude-limits` →
Add plugin → `limit-rings`.

Из терминала:

```bash
claude plugin install limit-rings --marketplace flydge/claude-limits
```

В терминальном Claude Code мод ничего не рисует, там уже есть строка статуса. Он только
обновляет `~/.claude/limits.json` для значка в строке меню.

## Удаление

```bash
launchctl bootout "gui/$(id -u)/com.flydge.claude-limits"; rm -f ~/Library/LaunchAgents/com.flydge.claude-limits.plist
rm -rf ~/Applications/ClaudeLimits.app ~/.claude/statusline-limits.sh ~/.claude/limits.json
claude plugin uninstall limit-rings
```

И уберите `statusLine` из `~/.claude/settings.json`.

## Устройство репозитория

| Папка | Что внутри |
|---|---|
| `statusline/` | bash-скрипт строки статуса и его тесты |
| `menubar/` | приложение строки меню на Swift/AppKit без Xcode-проекта: логика (`LimitsCore.swift`) отдельно от интерфейса |
| `mod/limit-rings/` | мод для приложения Claude: кольца над полем ввода |
| `tools/readme-images.py` | перерисовывает картинки этого README из настоящего кода |
| `docs/superpowers/` | спецификация и план реализации |

## Разработка

```bash
bash statusline/test/run.sh          # тесты строки статуса
bash menubar/test.sh                 # тесты логики строки меню
claude plugin test mod/limit-rings   # тесты мода
bash menubar/build.sh                # сборка build/ClaudeLimits.app
python3 tools/readme-images.py       # картинки для README
```
