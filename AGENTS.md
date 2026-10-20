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

1. Get the repository into `~/claude-limits`:
   - not there: `git clone https://github.com/flydge/claude-limits.git ~/claude-limits`
   - already there: `git -C ~/claude-limits pull --ff-only`
2. Run `~/claude-limits/install.sh` and act on its exit code:

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

- `--no-menubar`: skip the menu bar app (no Swift build, no LaunchAgent).
- `--no-mod`: skip the desktop app plugin.
- `--force-statusline`: replace an existing `statusLine` after backing up `settings.json`.
- `--no-statusline`: leave the status line and `settings.json` alone.

## Do not

- Do not edit `~/.claude/settings.json` by hand: the script merges, backs up and checks it.
- Do not use `sudo`; everything installs into the user's home folder.
- Do not replace someone else's `statusLine` without the user's yes.

## Updating and removing

- Update: `git -C ~/claude-limits pull --ff-only && ~/claude-limits/install.sh`
- Remove: `~/claude-limits/install.sh uninstall`

## Working on the code

See `README.md` § Разработка for the test commands. All tests must pass before a commit:
`bash statusline/test/run.sh && bash menubar/test.sh && claude plugin test mod/limit-rings && bash tests/install.test.sh`.
