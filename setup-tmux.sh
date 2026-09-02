#!/usr/bin/env bash
# Ghostty + tmux setup from:
# https://samuellawrentz.com/blog/ghostty-tmux-productivity/
#
# Ghostty is the outer shell. tmux holds named sessions that survive window
# close. This script installs tmux, writes a matching ~/.tmux.conf, and patches
# Ghostty so copy/paste and a couple of macOS shortcuts reach tmux.
#
# Usage:
#   ./setup-tmux.sh              # install + write configs
#   ./setup-tmux.sh --auto-attach  # also auto-join tmux when Ghostty opens
#   ./setup-tmux.sh --dry-run      # print what would change

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="${HOME}/.tmux.conf"
GHOSTTY_DIR="${HOME}/.config/ghostty"
GHOSTTY_CONF="${GHOSTTY_DIR}/config"
TM_BIN="${HOME}/bin/tm"
STARTUP_SH="${HOME}/.tmux_startup.sh"
ZSHRC="${HOME}/.zshrc"

AUTO_ATTACH=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --auto-attach) AUTO_ATTACH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

backup() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local dest="${path}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] backup %s -> %s\n' "$path" "$dest"
    return 0
  fi
  cp "$path" "$dest"
  log "backed up $path -> $dest"
}

need_brew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi
  echo "Homebrew is required to install tmux. Install it from https://brew.sh" >&2
  exit 1
}

install_tmux() {
  need_brew
  if command -v tmux >/dev/null 2>&1; then
    log "tmux already installed: $(tmux -V)"
    return 0
  fi
  log "installing tmux with Homebrew"
  run brew install tmux
}

write_tmux_conf() {
  backup "$TMUX_CONF"
  log "writing $TMUX_CONF"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  cat >"$TMUX_CONF" <<'EOF'
# Ghostty + tmux — prefix is Ctrl-b (tmux default).
# https://samuellawrentz.com/blog/ghostty-tmux-productivity/

set -g prefix C-b
bind C-b send-prefix
bind b last-window

set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g focus-events on
set -g status-interval 5
set -g set-titles on
set -g set-titles-string "#S · #W"
setw -g aggressive-resize on

set -g default-terminal "tmux-256color"
set -ag terminal-features "xterm-ghostty:RGB:clipboard,xterm-256color:RGB"
set -ag terminal-overrides ",xterm-256color:RGB,xterm-ghostty:RGB"
set -s set-clipboard on

set -g status-position bottom
set -g status-style "bg=default,fg=colour245"
set -g status-left "#[fg=colour39,bold] #S #[fg=colour240]│ "
set -g status-left-length 32
set -g status-right "#[fg=colour240]%H:%M "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[fg=colour39,bold] #I:#W "
setw -g pane-border-style "fg=colour238"
setw -g pane-active-border-style "fg=colour39"

bind r source-file ~/.tmux.conf \; display-message "tmux reloaded"

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# prefix + s / Cmd+s in Ghostty → pick a named session
bind s choose-tree -Zs
# prefix + S → write the paste buffer to a file (the blog's save-buffer)
bind S command-prompt -p "save-buffer:" "save-buffer '%%'"

setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "pbcopy"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "pbcopy"

bind -n M-Left previous-window
bind -n M-Right next-window
EOF
}

GHOSTTY_MARK_BEGIN="# >>> ghostty-tmux-setup"
GHOSTTY_MARK_END="# <<< ghostty-tmux-setup"

write_ghostty_conf() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would patch $GHOSTTY_CONF"
    return 0
  fi
  mkdir -p "$GHOSTTY_DIR"
  if [[ -f "$GHOSTTY_CONF" ]]; then
    backup "$GHOSTTY_CONF"
  else
    : >"$GHOSTTY_CONF"
  fi

  local tmp
  tmp="$(mktemp)"
  # Drop a previous managed block, keep everything else (including split binds).
  awk -v begin="$GHOSTTY_MARK_BEGIN" -v end="$GHOSTTY_MARK_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$GHOSTTY_CONF" >"$tmp"

  # Strip leftover blank lines at EOF, then append the block once.
  python3 - "$tmp" "$GHOSTTY_CONF" <<'PY'
import pathlib, sys
src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
text = text.rstrip() + "\n\n"
block = """# >>> ghostty-tmux-setup
# Ghostty splits are for scratch panes. tmux holds the real session.
# Disable auto-copy so mouse select hits tmux, not Ghostty.
copy-on-select = false

# Cmd+s → Ctrl-b s (session picker)
keybind = cmd+s=text:\\x02\\x73
# Cmd+b → Ctrl-b z (zoom / unzoom current pane)
keybind = cmd+b=text:\\x02\\x7a
# <<< ghostty-tmux-setup
"""
dest.write_text(text + block)
src.unlink()
PY
  log "patched $GHOSTTY_CONF (kept existing split keybinds)"
}

write_tm_helper() {
  mkdir -p "$(dirname "$TM_BIN")"
  backup "$TM_BIN"
  log "writing $TM_BIN"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  cat >"$TM_BIN" <<'EOF'
#!/usr/bin/env bash
# Named tmux sessions. Ghostty is the window; this is the session that survives.
#
#   tm              attach/create "main"
#   tm work         attach/create "work" with editor / git / server windows
#   tm blog         attach/create a named session
#   tm ls           list sessions
#   tm kill NAME    kill a session

set -euo pipefail

usage() {
  sed -n '2,10p' "$0"
}

has_session() {
  tmux has-session -t "$1" 2>/dev/null
}

create_work() {
  local root="${TMUX_WORK_DIR:-$HOME}"
  tmux new-session -d -s work -n editor -c "$root"
  tmux new-window -t work -n git -c "$root"
  tmux send-keys -t work:git "git log --oneline --decorate --graph -n 40" C-m
  tmux new-window -t work -n server -c "$root"
  tmux select-window -t work:editor
}

attach() {
  local name="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$name"
  else
    tmux attach-session -t "$name"
  fi
}

cmd="${1:-main}"
shift || true

case "$cmd" in
  -h|--help) usage; exit 0 ;;
  ls|list) tmux list-sessions ;;
  kill)
    [[ $# -ge 1 ]] || { echo "usage: tm kill NAME" >&2; exit 1; }
    tmux kill-session -t "$1"
    ;;
  work)
    if ! has_session work; then
      create_work
    fi
    attach work
    ;;
  *)
    if ! has_session "$cmd"; then
      tmux new-session -d -s "$cmd"
    fi
    attach "$cmd"
    ;;
esac
EOF
  chmod +x "$TM_BIN"
}

write_startup() {
  backup "$STARTUP_SH"
  log "writing $STARTUP_SH"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  cat >"$STARTUP_SH" <<'EOF'
# Auto-join tmux only in Ghostty, and only when not already inside tmux.
# Source from ~/.zshrc:
#   source ~/.tmux_startup.sh
if [[ -z "${TMUX:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" && -z "${SSH_TTY:-}" && $- == *i* ]]; then
  exec tmux new-session -A -s main
fi
EOF
}

enable_auto_attach() {
  write_startup
  if [[ ! -f "$ZSHRC" ]]; then
    warn "$ZSHRC not found; source ~/.tmux_startup.sh yourself"
    return 0
  fi
  if grep -q 'source ~/.tmux_startup.sh' "$ZSHRC"; then
    if grep -q '^[[:space:]]*source ~/.tmux_startup.sh' "$ZSHRC"; then
      log "auto-attach already enabled in $ZSHRC"
      return 0
    fi
    backup "$ZSHRC"
    log "uncommenting tmux auto-attach in $ZSHRC"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      return 0
    fi
    python3 - "$ZSHRC" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace("# source ~/.tmux_startup.sh", "source ~/.tmux_startup.sh")
p.write_text(text)
PY
    return 0
  fi
  backup "$ZSHRC"
  log "adding auto-attach to $ZSHRC"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  printf '\n# Ghostty + tmux auto-attach\nsource ~/.tmux_startup.sh\n' >>"$ZSHRC"
}

print_cheatsheet() {
  cat <<EOF

Done. Reload Ghostty (Cmd+Shift+, then close/reopen, or just restart Ghostty).

Layers
  Ghostty  outer window + scratch splits (Ctrl-arrows you already have)
  tmux     named sessions that survive closing the window

Everyday
  tm                 attach/create session "main"
  tm work            editor + git log + server windows
  tm blog            any named session
  prefix             Ctrl-b
  Ctrl-b s / Cmd+s   session list
  Ctrl-b z / Cmd+b   zoom pane
  Ctrl-b |  /  -     split right / down
  Ctrl-b c           new window
  Ctrl-b d           detach (session keeps running)
  Ctrl-b [ then v/y  copy mode (vim keys → macOS clipboard)

Scratch panes: use Ghostty splits. The tmux session underneath stays put.

EOF
  if [[ "$AUTO_ATTACH" -eq 0 ]]; then
    cat <<EOF
To auto-join tmux when Ghostty opens:
  $SCRIPT_DIR/setup-tmux.sh --auto-attach
  (or uncomment  source ~/.tmux_startup.sh  in ~/.zshrc after this script writes that file)

EOF
  fi
}

main() {
  install_tmux
  write_tmux_conf
  write_ghostty_conf
  write_tm_helper
  write_startup
  if [[ "$AUTO_ATTACH" -eq 1 ]]; then
    enable_auto_attach
  fi
  if [[ "$DRY_RUN" -eq 0 ]] && tmux info >/dev/null 2>&1; then
    tmux source-file "$TMUX_CONF" >/dev/null 2>&1 || true
  fi
  print_cheatsheet
}

main
