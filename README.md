# claude-limits

[![test](https://github.com/flydge/claude-limits/actions/workflows/test.yml/badge.svg)](https://github.com/flydge/claude-limits/actions/workflows/test.yml)

Your Claude subscription limits, 5-hour and weekly, in the Claude Code status line, the macOS
menu bar and above the prompt in the Claude app. It reads only what Claude Code itself reports:
no tokens, no cookies, no network.

## Install

Tell Claude Code:

```
Install https://github.com/flydge/claude-limits
```

Or run it yourself:

```bash
git -C ~/claude-limits pull --ff-only 2>/dev/null || git clone https://github.com/flydge/claude-limits.git ~/claude-limits; ~/claude-limits/install.sh
```

> **AI agents:** follow [AGENTS.md](AGENTS.md).

## What it looks like

**Terminal status line**

![Status line with 5-hour and weekly bars](docs/images/statusline.svg)

**Claude app, above the prompt**

![Rings above the prompt in the Claude app](docs/images/band.svg)

**macOS menu bar**, details on click

![Two rings in the menu bar](docs/images/menubar.png)
![Menu with both limits and their resets](docs/images/menu.png)

Green below 60 %, orange below 85 %, red above. When the current pace runs out before the
reset, a forecast appears. Text follows the macOS language, English or Russian (the menu above
is Russian); `install.sh --lang en|ru|auto` pins it.
