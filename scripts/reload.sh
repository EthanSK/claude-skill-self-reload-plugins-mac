#!/usr/bin/env bash
# self-reload-plugins: dispatch `/reload-plugins` into the running Claude Code
# terminal. Two-tier matching:
#
#   1. Process-tree match (preferred): find Claude CLI process(es) on the box,
#      read their controlling tty (e.g. /dev/ttys003), then ask each terminal
#      emulator which of its sessions owns that tty. Robust regardless of what
#      the window title says.
#
#   2. Title match (fallback): legacy behavior — find a window whose title
#      contains "Claude". Still useful when (a) the user is running Claude in
#      a terminal whose AppleScript surface doesn't expose tty, or (b) the
#      Claude CLI process has exited but the terminal is still open.
#
# We never blind-keystroke into the frontmost app. If neither tier finds a
# target, exit non-zero.
#
# Search priority within each tier: iTerm2 > Terminal.app > Ghostty / WezTerm /
# kitty / Alacritty (via System Events accessibility tree).

set -uo pipefail

LOG_SKILL="self-reload-plugins"
# shellcheck disable=SC1091
[ -f "$HOME/.claude/scripts/skill-log.sh" ] && . "$HOME/.claude/scripts/skill-log.sh"
_log() { command -v skill_log >/dev/null 2>&1 && skill_log "$@" || true; }
_log info "skill.start" "{}"

CMD="/reload-plugins"

osa() { osascript "$@"; }

# ---------------------------------------------------------------------------
# Tier 1 — find Claude CLI ttys
# ---------------------------------------------------------------------------
# Find Claude Code CLI processes. Two patterns cover both the npm-installed
# and the local ~/.claude install:
#   • node ... @anthropic-ai/claude-code/cli.js
#   • a `claude` binary launched directly
# We DON'T match on "claude" alone — too many false positives (claude-code-channel
# server, this script, etc.). We require either the cli.js path or an exact
# argv0 == "claude".
collect_claude_ttys() {
  local pid args tty ttypath
  local out=""
  while IFS= read -r line; do
    # ps -axo right-aligns the pid column with leading spaces. Strip them.
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%% *}"
    args="${line#* }"
    args="${args#"${args%%[![:space:]]*}"}"
    case "$args" in
      *"@anthropic-ai/claude-code/cli.js"*) ;;
      *"/claude "*|*"/claude") ;;
      "claude "*|"claude") ;;
      *) continue ;;
    esac
    # Skip our own pid and our parent chain (we are a child of bash invoked by
    # a tool inside the very Claude session we want to target — the tty is the
    # right one, but make sure we don't skip ourselves into oblivion).
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$tty" || "$tty" == "??" || "$tty" == "?" ]] && continue
    ttypath="/dev/${tty}"
    out+="${pid}|${ttypath}|${args}"$'\n'
  done < <(ps -axo pid=,command= 2>/dev/null)
  printf '%s' "$out"
}

# iTerm2: find a session whose tty matches and write to it.
try_iterm2_by_tty() {
  local target_tty="$1"
  local running
  running=$(osa -e 'tell application "System Events" to (name of processes) contains "iTerm2"' 2>/dev/null || echo "false")
  [[ "$running" != "true" ]] && return 1

  local match
  match=$(osa <<APPLESCRIPT 2>/dev/null || true
tell application "iTerm2"
  set hit to ""
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          repeat with s in sessions of t
            try
              set stty to tty of s
            on error
              set stty to ""
            end try
            if stty is "${target_tty}" then
              set hit to (id of w as string) & "|" & (index of t as string) & "|" & (unique id of s as string) & "|" & stty
              exit repeat
            end if
          end repeat
        end try
        if hit is not "" then exit repeat
      end repeat
    end try
    if hit is not "" then exit repeat
  end repeat
  return hit
end tell
APPLESCRIPT
)

  [[ -z "$match" ]] && return 1

  local win_id tab_idx sess_uid
  win_id="${match%%|*}"
  local rest="${match#*|}"
  tab_idx="${rest%%|*}"
  rest="${rest#*|}"
  sess_uid="${rest%%|*}"

  osa <<APPLESCRIPT >/dev/null
tell application "iTerm2"
  repeat with w in windows
    if (id of w as string) is "${win_id}" then
      tell w
        set current tab to tab ${tab_idx}
        repeat with s in sessions of tab ${tab_idx}
          if (unique id of s as string) is "${sess_uid}" then
            tell s to write text "${CMD}"
            exit repeat
          end if
        end repeat
      end tell
      exit repeat
    end if
  end repeat
end tell
APPLESCRIPT

  echo "Sent ${CMD} to iTerm2 session (tty ${target_tty})"
  return 0
}

# Terminal.app: find a tab whose tty matches and `do script` into it.
# Note: Terminal.app's `tabs of w` doesn't support `index of t` reliably (it
# silently errors mid-iteration). Match by tty alone, then dispatch via
# `do script "..." in tab whose tty is X` which preserves tab identity.
try_terminal_by_tty() {
  local target_tty="$1"
  local running
  running=$(osa -e 'tell application "System Events" to (name of processes) contains "Terminal"' 2>/dev/null || echo "false")
  [[ "$running" != "true" ]] && return 1

  local match
  match=$(osa <<APPLESCRIPT 2>/dev/null || true
tell application "Terminal"
  set hit to ""
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          set ttty to tty of t
        on error
          set ttty to ""
        end try
        if ttty is "${target_tty}" then
          set hit to (id of w as string)
          exit repeat
        end if
      end repeat
    end try
    if hit is not "" then exit repeat
  end repeat
  return hit
end tell
APPLESCRIPT
)

  [[ -z "$match" ]] && return 1

  # Dispatch /reload-plugins into the matched tab. `do script ... in <tab>`
  # writes-and-returns inline (it does NOT spawn a new tab when given an
  # existing tab).
  osa <<APPLESCRIPT >/dev/null
tell application "Terminal"
  repeat with w in windows
    if (id of w as string) is "${match}" then
      activate
      set frontmost of w to true
      repeat with t in tabs of w
        try
          if (tty of t as string) is "${target_tty}" then
            set selected of t to true
            do script "${CMD}" in t
            exit repeat
          end if
        end try
      end repeat
      exit repeat
    end if
  end repeat
end tell
APPLESCRIPT

  echo "Sent ${CMD} to Terminal.app tab (tty ${target_tty})"
  return 0
}

dispatch_by_tty() {
  local lines tty_target
  lines=$(collect_claude_ttys)
  [[ -z "$lines" ]] && return 1

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    tty_target="${line#*|}"
    tty_target="${tty_target%%|*}"
    if try_iterm2_by_tty "$tty_target"; then return 0; fi
    if try_terminal_by_tty "$tty_target"; then return 0; fi
    # Ghostty / WezTerm / kitty / Alacritty don't reliably expose tty via
    # AppleScript — let those fall through to the title-match tier.
  done <<<"$lines"
  return 1
}

# ---------------------------------------------------------------------------
# Tier 2 — legacy title match (fallback)
# ---------------------------------------------------------------------------
try_iterm2_by_title() {
  local running
  running=$(osa -e 'tell application "System Events" to (name of processes) contains "iTerm2"' 2>/dev/null || echo "false")
  [[ "$running" != "true" ]] && return 1

  local match
  match=$(osa <<'APPLESCRIPT' 2>/dev/null || true
tell application "iTerm2"
  set hit to ""
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          set tt to name of t
        on error
          set tt to ""
        end try
        set lowered to do shell script "printf %s " & quoted form of tt & " | tr '[:upper:]' '[:lower:]'"
        if lowered contains "claude" then
          set hit to (id of w as string) & "|" & (index of t as string) & "|" & tt
          exit repeat
        end if
        try
          repeat with s in sessions of t
            try
              set sn to name of s
            on error
              set sn to ""
            end try
            set lowered2 to do shell script "printf %s " & quoted form of sn & " | tr '[:upper:]' '[:lower:]'"
            if lowered2 contains "claude" then
              set hit to (id of w as string) & "|" & (index of t as string) & "|" & sn
              exit repeat
            end if
          end repeat
        end try
        if hit is not "" then exit repeat
      end repeat
    end try
    if hit is not "" then exit repeat
  end repeat
  return hit
end tell
APPLESCRIPT
)

  [[ -z "$match" ]] && return 1

  local win_id tab_idx title
  win_id="${match%%|*}"
  local rest="${match#*|}"
  tab_idx="${rest%%|*}"
  title="${rest#*|}"

  osa <<APPLESCRIPT >/dev/null
tell application "iTerm2"
  repeat with w in windows
    if (id of w as string) is "${win_id}" then
      tell w
        set current tab to tab ${tab_idx}
        tell current session of tab ${tab_idx}
          write text "${CMD}"
        end tell
      end tell
      exit repeat
    end if
  end repeat
end tell
APPLESCRIPT

  echo "Sent ${CMD} to iTerm2 window/tab (title match): \"${title}\""
  return 0
}

try_terminal_by_title() {
  local running
  running=$(osa -e 'tell application "System Events" to (name of processes) contains "Terminal"' 2>/dev/null || echo "false")
  [[ "$running" != "true" ]] && return 1

  local match
  match=$(osa <<'APPLESCRIPT' 2>/dev/null || true
tell application "Terminal"
  set hit to ""
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          set tt to custom title of t
        on error
          set tt to ""
        end try
        if tt is missing value or tt is "" then
          try
            set tt to name of t
          on error
            set tt to ""
          end try
        end if
        set lowered to do shell script "printf %s " & quoted form of (tt as string) & " | tr '[:upper:]' '[:lower:]'"
        if lowered contains "claude" then
          set hit to (id of w as string) & "|" & (tt as string)
          exit repeat
        end if
      end repeat
    end try
    if hit is not "" then exit repeat
  end repeat
  return hit
end tell
APPLESCRIPT
)

  [[ -z "$match" ]] && return 1

  local win_id title
  win_id="${match%%|*}"
  title="${match#*|}"

  osa <<APPLESCRIPT >/dev/null
tell application "Terminal"
  activate
  repeat with w in windows
    if (id of w as string) is "${win_id}" then
      set frontmost of w to true
      exit repeat
    end if
  end repeat
end tell
delay 0.15
tell application "System Events"
  tell process "Terminal"
    keystroke "${CMD}"
    key code 36
  end tell
end tell
APPLESCRIPT

  echo "Sent ${CMD} to Terminal.app window (title match): \"${title}\""
  return 0
}

try_generic_by_title() {
  local app_name="$1"
  local proc_running
  proc_running=$(osa -e "tell application \"System Events\" to (name of processes) contains \"${app_name}\"" 2>/dev/null || echo "false")
  [[ "$proc_running" != "true" ]] && return 1

  local title
  title=$(osa <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "${app_name}"
    set hit to ""
    try
      repeat with w in windows
        try
          set t to title of w
        on error
          set t to ""
        end try
        set lowered to do shell script "printf %s " & quoted form of t & " | tr '[:upper:]' '[:lower:]'"
        if lowered contains "claude" then
          set hit to t
          perform action "AXRaise" of w
          exit repeat
        end if
      end repeat
    end try
    return hit
  end tell
end tell
APPLESCRIPT
)

  [[ -z "$title" ]] && return 1

  osa <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "${app_name}"
    set frontmost to true
  end tell
end tell
delay 0.15
tell application "System Events"
  tell process "${app_name}"
    keystroke "${CMD}"
    key code 36
  end tell
end tell
APPLESCRIPT

  echo "Sent ${CMD} to ${app_name} window (title match): \"${title}\""
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if dispatch_by_tty; then
  _log info "skill.end" "{\"match\":\"tty\"}"
  exit 0
fi

if try_iterm2_by_title; then _log info "skill.end" "{\"match\":\"title\",\"app\":\"iTerm2\"}"; exit 0; fi
if try_terminal_by_title; then _log info "skill.end" "{\"match\":\"title\",\"app\":\"Terminal\"}"; exit 0; fi
for app in "Ghostty" "WezTerm" "wezterm-gui" "kitty" "Alacritty"; do
  if try_generic_by_title "$app"; then
    _log info "skill.end" "{\"match\":\"title\",\"app\":\"$app\"}"
    exit 0
  fi
done

_log error "skill.error" "{\"err\":\"no Claude tty or claude-titled window found\"}"
echo "self-reload-plugins: could not locate the Claude Code terminal." >&2
echo "  Tried: process-tree match (claude CLI tty → iTerm2/Terminal session)" >&2
echo "  Then:  title match (\"Claude\" in window/tab title)" >&2
echo "  Searched apps: iTerm2, Terminal, Ghostty, WezTerm, kitty, Alacritty." >&2
exit 1
