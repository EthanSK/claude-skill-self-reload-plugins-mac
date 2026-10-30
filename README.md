# claude-skill-self-reload-plugins-mac

A Claude Code skill that lets the running Claude session self-recover from MCP/plugin disconnects by dispatching `/reload-plugins` into its own terminal window — no human intervention required.

**macOS port.** For the Windows version, see the counterpart repo: [EthanSK/claude-skill-self-reload-plugins-windows](https://github.com/EthanSK/claude-skill-self-reload-plugins-windows).

## What it does

When Claude detects that an expected MCP server, plugin, or tool has dropped mid-session, this skill:

1. Finds the macOS terminal window whose title contains **"Claude"** (case-insensitive).
2. Dispatches `/reload-plugins` directly into that session via AppleScript / System Events.
3. Returns control to Claude with the freshly reloaded toolset.

Supported terminals: iTerm2 (preferred — no focus change), Terminal.app, Ghostty, WezTerm, kitty, Alacritty.

## Install

```bash
mkdir -p ~/.claude/skills/self-reload-plugins
cp -r ./skill.md ./scripts ~/.claude/skills/self-reload-plugins/
chmod +x ~/.claude/skills/self-reload-plugins/scripts/reload.sh
```

That's it. Claude auto-discovers skills from `~/.claude/skills/`.

## Title requirement

The Claude Code terminal **MUST** have "Claude" somewhere in its window or tab title for the skill to find it. If your shell prompt doesn't already set one:

```bash
# bash
PROMPT_COMMAND='printf "\033]0;Claude\007"'

# zsh
precmd() { print -Pn "\e]0;Claude\a" }
```

There is no blind-frontmost fallback — `/reload-plugins` will never accidentally land in a Chrome address bar, text editor, or other unrelated window. If no Claude-titled window is found, the script exits non-zero with a clear error.

## Trigger phrases

The skill triggers when the user (or Claude itself) says:

- "reload my plugins" / "reload plugins"
- "mcp server dropped" / "chrome-devtools disconnected"
- "refresh my tools"
- "can you reload plugins yourself" / "self-reload"

Or implicitly when Claude notices an expected MCP tool has stopped responding mid-session.

## Logging

Writes structured NDJSON events to `~/.claude/logs/skills.log` (when the unified skill-log infrastructure is present) for post-hoc debugging.

## Counterpart

- **Windows**: [EthanSK/claude-skill-self-reload-plugins-windows](https://github.com/EthanSK/claude-skill-self-reload-plugins-windows) — process-tree walk + `claude.exe` parent fallback.

Both share the goal: recover from MCP drops without asking the human to type `/reload-plugins`.

## Weekly update checks

The agent checks the configured public source on first skill use when a week has passed, using a shared local lease to avoid duplicate checks. When an update is available, it explains the changes and asks if you want it first. It installs only after you agree, preserves local edits and respects opt-outs. Declining or ignoring the offer leaves your installed skill unchanged. No background process is installed. Python 3 is needed for the date/lease helper; the skill can still be used without it. Copied installations need a trustworthy installation baseline; plugin installations use their host updater. See [the update procedure](references/public-updates.md).


## License

Source-available under [Ethan Source-Available No-Sale Terms 1.0](LICENSE). You can use and modify the covered code, including internally at work, and share it without charge. Selling the software, modified versions, paid access, or bundles requires a separate commercial license. Earlier licenses and third-party rights remain in force. See [scope and release policy](LICENSING.md).
