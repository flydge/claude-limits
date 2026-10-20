# claude-limits

Показывает расход 5-часового и недельного лимита подписки Claude:

- в строке статуса Claude Code — гладкие полосы с процентом и временем до сброса;
- в строке меню macOS — два кольца с числами и меню с деталями.

```
5ч ████▎····· 42% 2ч10м   нед █▊········ 18% 4д3ч
```

Данные берутся только из JSON, который Claude Code сам передаёт скрипту строки статуса.
Без сети, без токенов и cookie. Строка меню читает копию этих данных из `~/.claude/limits.json`,
поэтому обновляется, пока вы работаете в Claude Code.

Требования: macOS 13+, `jq`, Command Line Tools (`swiftc`), подписка Claude Pro или Max.

## Установка

```bash
./install.sh
```

Затем добавьте в `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline-limits.sh",
  "refreshInterval": 60
}
```

Автозапуск строки меню при входе:

```bash
bash menubar/install-launch-agent.sh
```

## Удаление

```bash
launchctl bootout "gui/$(id -u)/com.flydge.claude-limits"; rm -f ~/Library/LaunchAgents/com.flydge.claude-limits.plist
rm -rf ~/Applications/ClaudeLimits.app ~/.claude/statusline-limits.sh ~/.claude/limits.json
```

И уберите `statusLine` из `~/.claude/settings.json`.

## Разработка

```bash
bash statusline/test/run.sh      # тесты строки статуса
bash menubar/test.sh             # тесты логики строки меню
bash menubar/build.sh            # сборка build/ClaudeLimits.app
build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --preview build/preview.png   # все состояния значка
```

Дизайн: [docs/superpowers/specs/2026-10-20-claude-limits-design.md](docs/superpowers/specs/2026-10-20-claude-limits-design.md).
