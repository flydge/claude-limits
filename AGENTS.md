# Installing claude-limits (instructions for AI agents)

The user gave you this repository to install. Do the whole install yourself: the
user is not expected to read this file or run anything by hand. Report back in a
few lines at the end.

## What gets installed (macOS only)

- `~/.claude/statusline-limits.sh` and a `statusLine` entry in `~/.claude/settings.json`:
  5-hour and weekly limit bars in the terminal Claude Code status line.
- `~/Applications/ClaudeLimits.app` with a user LaunchAgent `com.flydge.claude-limits`:
  two rings in the macOS menu bar, started at login.
- The Claude Code plugin `limit-rings@flydge` from the marketplace `flydge/claude-limits`:
  rings above the prompt in the Claude desktop app's Code tab.

Nothing makes network calls or reads credentials; all three read the limits Claude Code
itself reports. They need a Claude Pro or Max subscription to show numbers.

## Steps

1. Get or update the repository and run the installer, in one command:

   ```bash
   git -C ~/claude-limits pull --ff-only 2>/dev/null || git clone https://github.com/flydge/claude-limits.git ~/claude-limits; ~/claude-limits/install.sh
   ```
2. Act on the installer's exit code:

   | Exit | Meaning | What you do |
   |---|---|---|
   | 0 | installed | go to step 3 |
   | 1 | a step failed | read the `fail` lines, fix what they name, rerun |
   | 2 | missing requirement or not macOS | the `fail` line gives the fix (`brew install jq`, `xcode-select --install`); run it if you can, else tell the user, then rerun |
   | 3 | the user already has another `statusLine` | nothing was changed. Ask the user whether to replace it (it is backed up beside `settings.json`). If yes: `~/claude-limits/install.sh --force-statusline`. If no: `~/claude-limits/install.sh --no-statusline` installs the menu bar and desktop parts and keeps theirs |

   The script is idempotent: rerunning it is always safe and changes only what is out of date.
   Every line on stdout is `ok|skip|fail <step>: <detail>`, and the last line is
   `done`, `incomplete` or `conflict`.
3. Run `~/claude-limits/install.sh check`. Exit 0 means every part is in place. A
   `skip data` line is normal right after installing: readings appear after the next
   Claude response. After `--no-statusline` (or `--no-menubar`, `--no-mod`), `check`
   reports the parts you left out as `fail`; that is expected.
4. Tell the user, in their language:
   - the menu bar rings are running now;
   - the terminal status line shows after the next response in a new `claude` session;
   - the desktop app shows the rings above the prompt in a new Code session, after its
     first response;
   - `~/claude-limits/install.sh uninstall` removes everything.

## Options

Install everything unless the user asked for less. Map their words to flags:

| The user wants | Flags |
|---|---|
| everything (default) | none |
| only the terminal status line | `--no-menubar --no-mod` |
| no menu bar icon | `--no-menubar` |
| only the desktop app rings | `--no-statusline --no-menubar` |
| to keep their own status line | `--no-statusline` |
| to replace their status line (after you asked) | `--force-statusline` |

Use `--no-menubar` too when `swiftc` is missing and Command Line Tools cannot be installed.

## Do not

- Do not edit `~/.claude/settings.json` by hand: the script merges, backs up and checks it.
- Do not use `sudo`; everything installs into the user's home folder.
- Do not replace someone else's `statusLine` without the user's yes.

## Updating and removing

- Update: `git -C ~/claude-limits pull --ff-only && ~/claude-limits/install.sh`
- Remove: `~/claude-limits/install.sh uninstall`

## Working on the code

How the parts fit:

```
Claude Code (terminal) --stdin JSON--> statusline/statusline-limits.sh --> status line
Claude app (Code tab)  --$.session---> mod/limit-rings               --> rings above the prompt
                both write ~/.claude/limits.json --> menubar/ (ClaudeLimits.app) --> menu bar rings
```

- Data: only what Claude Code reports (`rate_limits.five_hour|seven_day` on the status
  line's stdin; `$.session.usage()` and `session.measure` in the mod). Never add network
  calls, credentials, cookies or the OAuth token.
- `~/.claude/limits.json`: `{"updated_at": <epoch s>, "five_hour": {"used_percentage": <0-100>,
  "resets_at": <epoch s>}, "seven_day": {...}}`, a missing window left out, written atomically.
  Write it only for a fresh reading: the status line when its session's numbers change, the mod
  on `session.measure`. An idle session must not overwrite a newer reading.
- Shared rules: green below 60 %, yellow (`systemOrange` in the menu bar) below 85 %, red from 85 %;
  data older than 30 min is grey in the menu bar; the forecast shows only after 10 minutes of a
  window and only when the current pace runs out before the reset.
- Plugin names starting with `claude-` are reserved, hence `limit-rings`.
- Check icon changes without a screenshot:
  `bash menubar/build.sh && build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --preview build/preview.png`.

All tests must pass before a commit (CI runs the same on macOS):

```bash
bash statusline/test/run.sh && bash menubar/test.sh && claude plugin test mod/limit-rings && bash tests/install.test.sh
```
