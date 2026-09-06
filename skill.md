---
name: self-reload-plugins
description: Self-recover from MCP/plugin disconnects by triggering `/reload-plugins` on Claude's own running terminal session via AppleScript. Use when the user says "reload my plugins", "reload plugins", "mcp server dropped", "chrome-devtools disconnected", "refresh my tools", "can you reload plugins yourself", "self-reload", or when you detect that an expected MCP tool/plugin is missing or has stopped responding mid-session.
---

# self-reload-plugins

Finds the macOS terminal window whose title contains **"Claude"**
(case-insensitive) and dispatches `/reload-plugins` into it, so Claude can
recover from a dropped MCP server or crashed plugin without asking Ethan to
type it manually.

## How it works

`scripts/reload.sh` searches known terminal apps in this priority order:

1. **iTerm2** — iterates `windows` / `tabs` / `sessions`, finds the first one
   whose title contains "claude", then calls
   `tell ... to write text "/reload-plugins"` directly on that session. No
   focus change, no keystroke. Cleanest path.
2. **Terminal.app** — iterates `windows` / `tabs`, matches on `custom title`
   or `name`, raises the matching window with `set frontmost`, then
   `System Events` `keystroke` + Return.
3. **Ghostty, WezTerm, kitty, Alacritty** — queries the System Events
   accessibility tree for an `AXWindow` whose `title` contains "claude",
   runs `perform action "AXRaise"`, then keystrokes into that process.

If no Claude-titled window is found anywhere, the script exits non-zero with
a clear error message to stderr. **There is no blind-frontmost fallback** —
that was removed so `/reload-plugins` can't accidentally land in a Chrome
address bar or text editor.

## Title requirement

The Claude Code terminal MUST have "Claude" somewhere in its window or tab
title for this skill to find it. Claude Code's own output often sets a
matching title, but if yours doesn't, configure one via:

- **bash/zsh**: `PROMPT_COMMAND='printf "\033]0;Claude\007"'` or
  `precmd() { print -Pn "\e]0;Claude\a" }`.
- **iTerm2**: Profiles → General → Tab title → "Claude".
- **Terminal.app**: View → Show Tab Bar, then right-click the tab → Edit
  Title.
- **Ghostty/WezTerm/kitty/Alacritty**: their respective `title` config
  options, or an OSC-0 escape from the shell prompt as above.

## Usage

```bash
bash ~/.claude/skills/self-reload-plugins/scripts/reload.sh
```

No arguments. On success, the script prints the app and window title it
targeted to stdout, e.g.:

```
Sent /reload-plugins to iTerm2 window/tab: "ethan — claude — 120×40"
```

On failure, exits non-zero with a stderr message explaining no
Claude-titled window was found.

## When to use

- A previously-working MCP tool is now missing from the available tool list
  mid-session.
- An MCP plugin emitted a disconnect error (e.g. Telegram bun crash,
  chrome-devtools dropped, context7 unreachable).
- User explicitly asks you to reload plugins yourself.

After running, expect the Claude CLI to process `/reload-plugins` and
re-announce its MCP servers. If the reload happens inside this same running
session, the newly-loaded tools become available without restart.

## Prerequisites

Whatever process runs `osascript` (ultimately the Claude Code CLI, via the
Bash tool) needs macOS **Automation** permission to control "System Events"
and, for each targeted terminal, that terminal's app ("iTerm2",
"Terminal", "Ghostty", etc.). On a fresh machine these are gated by TCC and
will produce a permission prompt or a silent failure.

Pre-allowing via TCC so the first run doesn't block is covered in the
TCC pre-allow feedback memory under
`~/.claude/projects/-Users-ethansarif-kattan/memory/` — check there if
the script errors with `-1743` or similar `errAEEventNotPermitted`.

## Caveats

- **No blind-frontmost fallback.** If no Claude-titled window exists, the
  script refuses to dispatch. This is deliberate: blind keystroking into
  whatever happens to be front is dangerous (wrong app receives the
  command).
- **Keystroke path still focus-dependent.** For Terminal.app and the
  generic/AX path, we raise the matched window first, but keystroke
  delivery still goes to "whatever the process receives next." The
  150ms `delay` before keystroking usually suffices; if focus is stolen
  between raise and keystroke, the keys land in the wrong place. iTerm2's
  native `write text` is immune.
- **No confirmation of success.** The script can't verify that Claude
  actually processed `/reload-plugins`. Check the next turn's tool list to
  confirm plugins came back.
- **iTerm2 search cost.** We loop all windows → tabs → sessions. For Ethan's
  typical workload (a handful of iTerm2 windows) this is sub-100ms. If you
  have dozens of sessions and this becomes slow, short-circuit by checking
  tab titles only (skip the session-name fallback) or by caching the
  matched session ID.
- **Terminal.app `do script` intentionally avoided** — it opens a new tab
  instead of typing into the current one, which is not what we want.

## Weekly public updates

On first use in a task, or the next use after a week in a long task, follow [references/public-updates.md](references/public-updates.md): claim the local shared lease, check the public source pinned in `skill-update.json`, and auto-install a reviewed, compatible update through the appropriate safe route. This is agent-triggered, not a background service. Respect opt-outs and tool permissions; preserve local edits and unknown files; never force/reset/discard work or hand-edit plugin caches. Keep dates and locks outside the skill. Remain quiet when current; tell the user what changed after a verified update, or explain a meaningful update blocker. Updating files never authorizes the skill's domain actions.
