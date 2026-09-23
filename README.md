# TabSignal

[![CI](https://github.com/MathiasClaesson/TabSignal/actions/workflows/ci.yml/badge.svg)](https://github.com/MathiasClaesson/TabSignal/actions/workflows/ci.yml)

Shows the state of a [Claude Code](https://claude.com/claude-code) session in the
Windows Terminal tab, together with the session name and the git branch, and starts
sessions with a project directory, a name and a tab color. Self-contained: no
server, no dependencies, one small `.exe` built from a single C# file.

Windows + Windows Terminal only.

## What you see in the tab

The state is Windows Terminal's progress ring, drawn in the tab's icon slot:

| State                                                              | The tab        |
|--------------------------------------------------------------------|----------------|
| Claude is working (including during long-running commands)          | spinning ring  |
| Claude needs you: done, asking permission, asking a question        | steady ring    |
| A new or ended session                                              | no ring        |

The ring's shape and color are Windows Terminal's own (the system accent color)
and cannot be changed. The icon slot can show either the profile icon or this
ring, so the ring is the only thing in that slot that can follow the session.
Claude Code's built-in progress ring is switched off in `~/.claude.json`
(`terminalProgressBarEnabled: false`) so that the two do not fight.

The tab title is the session name followed by the git branch, `name · branch`.
The hooks set it on every state change, so a `/rename` or a `git switch` shows up
at the next prompt. The branch is read straight from `.git/HEAD` (worktrees
included) without running git; a detached HEAD shows the short hash, and outside
a repository the title is just the name. The branch comes last, so it is what
Windows Terminal cuts off first when the tab is narrow. Claude Code's own title
glyphs (the working spinner, the done marker) are disabled via
`"env": { "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1" }` in `~/.claude/settings.json`.

No bell (BEL) is sent by default. `.\install.ps1 -Bell` adds one when Claude needs
you (bell glyph in the tab, flash according to `bellStyle`).

The tab *color* is a separate per-tab RGB color, see below. The terminal's color
scheme and Claude Code's theme are not affected.

## How it works

Claude Code runs hooks as subprocesses with no console of their own.
`TabSignal.exe` walks up the process tree to the shell that owns the tab, attaches
to its console (`AttachConsole`) and writes the sequences straight to `CONOUT$`:

- `ESC ] 9 ; 4 ; state ; progress BEL` — OSC 9;4, the progress ring
  (3 = spinning, 1;100 = steady, 0 = hidden)
- `ESC ] 4 ; 17 ; rgb:rr/gg/bb BEL` + `ESC [ 2 ; 15 ; 17 , |` — the tab color.
  OSC 4 redefines index 17 in that one tab's color table, and DECAC points the tab
  at it. Index 17 is used neither by the color scheme (0–15) nor by Claude Code,
  which draws in truecolor.
- `ESC ] 2 ; title BEL` — OSC 2, the tab title: session name and git branch
- `ESC ] 9 ; 9 ; "path" ESC \` — OSC 9;9, the current directory, so that
  "Duplicate tab" opens in the same place

Hooks: `UserPromptSubmit` starts the spin; `Stop`, `PermissionRequest`,
`AskUserQuestion` and `Notification` (permission, question, idle) give the steady
ring; `SessionStart` and `SessionEnd` hide it. This works whatever shell runs in
the tab (PowerShell, cmd and Git Bash are tested), because the hook always walks
up to the process directly below `WindowsTerminal.exe`.

## Install

Clone anywhere you like — nothing in the code assumes a particular location.

```powershell
git clone https://github.com/MathiasClaesson/TabSignal.git
cd TabSignal
.\install.ps1              # builds the exe + registers the hooks
.\install.ps1 -Bell        # same, but with a bell (BEL)
.\install.ps1 -Uninstall   # removes the hooks again
```

If PowerShell blocks the script, run it as
`powershell -ExecutionPolicy Bypass -File .\install.ps1`.

`install.ps1` does everything needed on a fresh machine, and is idempotent — run
it again after every change:

- builds `TabSignal.exe` and registers the hooks in `~/.claude/settings.json`
- sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` there
- turns off Claude Code's own progress ring in `~/.claude.json`
- adds the `tab` function and a `prompt` function to your PowerShell profile
- puts the repo folder on your user PATH
- applies the Windows Terminal settings listed below (skipped with a warning if
  that file contains comments — set them by hand in that case)

Options:

| Flag | Effect |
|------|--------|
| `-Bell` | send BEL when Claude needs you |
| `-StartingDirectory <path>` | also point new Windows Terminal tabs at `<path>` |
| `-SkipTerminalSettings` | leave `settings.json` for Windows Terminal alone |
| `-SkipPath` | do not touch your user PATH |
| `-SkipBuild` | skip the build step |
| `-Uninstall` | remove hooks, the title setting and the `tab` function, and re-enable Claude Code's ring |

PATH and the Windows Terminal settings are left in place by `-Uninstall`. A backup
(`.bak-<timestamp>`) is taken of every file that actually changes; a re-run that
would produce identical content rewrites nothing, so backups do not pile up.

Hooks you added yourself are never removed, including one sitting in the same
entry as a TabSignal hook. If your profile already defines a `prompt` function
(oh-my-posh, posh-git, your own), TabSignal leaves it alone and says so —
"Duplicate tab" then still opens in the session's directory inside Claude, just
not in a plain shell.

`-SettingsPath`, `-ClaudeJsonPath` and `-ProfilePath` override the files the
installer writes to; the tests use them to run a full install against a temp
directory.

Requirements: Windows (the compiler `csc.exe` ships with .NET Framework 4.x — no
SDK needed) and Windows Terminal 1.6 or later. Run the install while no Claude
session is running, since Claude Code writes to `~/.claude.json` itself.

## Starting a session: `tab`

```powershell
tab                          # project list -> session name -> tool -> color
tab "Name"                   # skips the name prompt
tab "Name" -Color cyan       # a chosen color
tab "Name" -Color none       # no tab color
tab -Dir C:\proj             # skips the project list
tab -NewTab                  # open the session in a new tab instead
tab -KeepTab                 # with -NewTab: leave the tab you ran tab in open
tab -Tool copilot            # skips the tool prompt (claude or copilot)
tab -Update                  # update the tool before starting, even if done today
tab -NoUpdate                # skip the daily update check
tab -Args "--resume"         # extra arguments for the tool (split on whitespace)
```

The flow: pick a project by number (0 = the current directory), confirm or type
a session name, pick the tool (Enter gives Claude Code, `2` gives GitHub Copilot
CLI), pick a color (Enter gives an automatic color derived from the name — the
same name always gives the same color; `none` gives no color).

You do not have to make up a name: Enter gives the project's display name from
`projects.txt` (the text after `|`), or the directory name when the project has
none or is not in the list. Since the title adds the git branch, the tab reads
e.g. `MeriterVy · feature/FAS-1234`. Type something at the prompt only when you
want a name of your own, or rename later with `/rename` in Claude. The session then takes over the tab you are standing in: the directory,
the title (name and git branch) and the color are set there and the tool starts.
Claude runs as `claude --name "Name"`, so the name shows up in the `--resume` list
too; Copilot has no `--name` and gets only `-Args`.

#### Updates

Before the tool starts, `tab` runs `claude update` or `copilot update` — at most
once a day per tool, so opening tabs stays fast. The time of the last run is kept
in `%LOCALAPPDATA%\TabSignal\update-<tool>.stamp`; a failed update is retried the
next day. `-Update` runs it regardless and `-NoUpdate` skips it.

#### Copilot

The hooks are Claude Code hooks, so a Copilot session has no progress ring and
its title is not refreshed while it runs: it gets the name and branch once, at
start. The tab color works as for Claude, and `TabSignal.exe recolor` covers
Copilot tabs too. With `-NewTab` the title is fixed
(`wt --suppressApplicationTitle`), so Copilot cannot replace it with its own.

Nothing is opened and nothing is closed, so no window can be lost on the way.
`tab` is a PowerShell function in your profile (added by `install.ps1`); from cmd,
`tab.cmd` works as well.

#### `-NewTab`

`tab -NewTab` opens the session in a new tab instead and closes the tab you ran
`tab` in — which only works when `tab` runs as the profile function, since it is
the dot-sourced script that can close the shell. The closing is guarded, because
closing the last tab in a window closes the window with it. The new tab reports
in through a marker file under `%TEMP%\TabSignal\ready` and writes the Windows
Terminal window it ended up in (the process id of its `WindowsTerminal.exe`, one
per window) into it; the old tab closes only if that is the same window it is in
itself. Otherwise it stays open with a line saying why: the new tab never came up
(`wt.exe` missing, or a cold start longer than 15 seconds), `wt.exe` put the
session in another window, or `tab` was not run in a Windows Terminal tab at all.
`-KeepTab` skips the handshake and keeps the tab you started from.

### The project list

`projects.txt` next to the script: one directory per line, an optional
`| Display name` after the path, `#` for a comment. It is yours to edit and is
not tracked by git.

```
C:\code\my-repo | My repo
C:\code\another
```

If the file is missing it is generated by scanning for directories containing
`.git`, `.claude` or `CLAUDE.md`, two levels deep. Two environment variables
control this:

- `TABSIGNAL_PROJECTS` — use a different projects file
- `TABSIGNAL_PROJECT_ROOTS` — `;`-separated roots to scan
  (default: the system drive root and your home directory)

### Colors

`red` `#cd3131`, `green` `#0dbc79`, `yellow` `#e5e510`, `blue` `#2472c8`,
`purple` `#bc3fbc`, `cyan` `#11a8cd`, `gray` `#666666` — or your own `#rrggbb`, or an xterm-256 index
`0`–`255`.

In `tab` the color is picked from a numbered menu where each row shows its color
as a swatch. `TabSignal.exe colors [--for <name>]` prints the palette as
`number|name|rrggbb` — that is what the menu is built from, so the palette is
defined in exactly one place, `Palette` in `TabSignal.cs`. Edit it there and run
`.\build.ps1`.

The palette is the Dark+ color scheme that ships with Windows Terminal, unchanged.
The active tab shows its color at full strength and therefore looks lighter than
the inactive ones, but the ring is still visible. `gray` is never picked automatically, so it means "I chose this myself".

Windows Terminal picks the tab text color itself: black if the tab color
composited over the tab row is light, white otherwise. With Windows in light mode
the tab row is light, so inactive tabs get black text while active and hovered
ones get white. That is why `install.ps1` installs a dark theme of its own
(`"theme": "TabSignal"`, tab row `#1c1c1c` both focused and unfocused); the text
then follows the tab color alone: white on the darker colors, black on the bright
ones (yellow, cyan, green), just as Windows Terminal draws them.
The theme only affects the window frame, not the terminal color scheme or Claude.

`TabSignal.exe recolor` re-sends the color to every open Claude tab (the color last
set, otherwise the one derived from the session name) — useful after editing the
palette. Do not use `wt --tabColor`: a tab started that way cannot be recolored
with escape sequences afterwards.

Change color mid-session (from the Claude prompt, prefixed with `!`):

```powershell
TabSignal.exe color purple
TabSignal.exe color "#3a7ca5"
TabSignal.exe color none
```

### Duplicate tab

Right-click the tab → "Duplicate tab" (or Ctrl+Shift+D) opens a new tab in the
**same directory**: TabSignal reports the session's directory to Windows Terminal
with OSC 9;9 on every hook event, `tab` does it at startup, and the `prompt`
function does it in ordinary shells. Color and title do not carry over —
Windows Terminal only copies the profile and the directory. Run `tab` in the new
tab: Enter on the project prompt takes the current directory, Enter on the name
gives the same default name as before, and the same name gives the same color.

## Windows Terminal settings that get applied

The `TabSignal` theme (above), and in `profiles.defaults`:

- `"bellStyle": ["window", "taskbar"]` — flash, no sound
- `"icon": "<repo>\\blank.png"` — a transparent profile icon, also set on the
  Windows PowerShell profile, which otherwise carries its own icon. The icon is
  only visible when the ring is hidden, i.e. in new tabs with no session. Remove
  the two `icon` lines to get the PowerShell icon back; `"icon": "none"` does not
  work, it gives Windows Terminal's fallback icon. The icon is per profile and
  cannot vary per tab.
- `"startingDirectory"` — only when you pass `-StartingDirectory`

Changes take effect a few seconds after the file is saved.

## Tests

```powershell
.\test.ps1
```

Three suites, all run on every push and pull request via GitHub Actions:

- **`tests/TabSignalTests.cs`** — the pure logic. Compiled together with
  `TabSignal.cs` into a separate test executable (`csc /main:`), so the shipped
  `TabSignal.exe` contains no test code. Covers which hook event produces which
  ring state (including that unknown events and non-`AskUserQuestion` tools leave
  the ring alone), how a color spec becomes an escape sequence, the automatic
  color derived from a session name, the clamping in `Progress`, the JSON field
  extraction, the sanitizing of a path before it goes into OSC 9;9, and the tab
  title: reading the branch from `.git/HEAD` (subdirectories, worktrees, a
  detached HEAD, no repository) and joining it to the name, and which processes
  count as a session for `recolor`.
- **`tests/Install.Tests.ps1`** — a full install / re-install / uninstall round
  trip driven against a temp directory via `-SettingsPath`, `-ClaudeJsonPath`,
  `-ProfilePath`, `-SkipBuild`, `-SkipPath` and `-SkipTerminalSettings`. Nothing
  outside that temp directory is touched. Covers idempotency, that hooks of your
  own survive both install and uninstall, `.claude.json` in its various shapes,
  the profile backup, and that an existing `prompt` function is not clobbered.
- **`tests/Tab.Tests.ps1`** — that the default starts the session in the tab you
  are in without going near `wt.exe`, and the `-NewTab` handshake that decides
  whether `tab` closes the tab it was run in, driven with a fake `wt.exe` and a
  fake `claude` so no window is ever opened. Also that Copilot starts without
  `--name`, and the daily update: run on first start, skipped the same day, due
  again after a day, forced by `-Update` and skipped by `-NoUpdate` — against a
  temp stamp directory.

Not covered, and not coverable without a real terminal and a live session:
`AttachConsole`, the walk up the process tree, whether Windows Terminal actually
renders what is sent, and the `-NewTab` `exit` that closes the old tab — `exit` from
a dot-sourced script only takes the shell down in an interactive host, so no
harness can observe it. Those stay manual:

```powershell
TabSignal.exe set 3            # spinning ring
TabSignal.exe set 1 100        # steady ring
TabSignal.exe clear            # no ring
TabSignal.exe color yellow
TabSignal.exe title "Test"     # tab title (replaced at the next hook event)
TabSignal.exe branch           # the git branch of the current directory
```

Troubleshooting: set `TABSIGNAL_LOG=C:\path\to\tabsignal.log` (or pass
`--log FILE`) to log the process chain and the sequences that were sent.

## Files

| File | |
|------|---|
| `TabSignal.cs` | the whole program: hooks, ring, color, title |
| `build.ps1` | compiles `TabSignal.exe` with `csc.exe` from .NET Framework |
| `install.ps1` | hooks, PowerShell profile, PATH, Windows Terminal settings |
| `tab.ps1` | the `tab` command: project, name, tool, color, update, session |
| `tab.cmd` | `tab` from cmd |
| `test.ps1`, `tests/` | the three test suites |
| `blank.png` | transparent 1×1 profile icon |

`TabSignal.exe`, `TabSignal.Tests.exe` and `projects.txt` are generated and not
tracked.

## Notes

This project was written with [Claude Code](https://claude.com/claude-code) —
the code, the scripts and this README are AI-generated, then tested and reviewed
by hand on Windows 11 with Windows Terminal. It relies on Claude Code hook names
and on Windows Terminal escape-sequence behavior, either of which may change in a
future version.

## License

MIT — see [LICENSE](LICENSE).
