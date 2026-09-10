#!/usr/bin/env bash
# Ghostty + tmux setup from:
# https://samuellawrentz.com/blog/ghostty-tmux-productivity/
#
# Ghostty is the outer shell. tmux holds named sessions that survive window
# close. This script installs tmux, writes a matching ~/.tmux.conf, and patches
# Ghostty so copy/paste and a couple of shortcuts reach tmux.
#
# Works on macOS (Homebrew + pbcopy + Cmd keybinds) and Ubuntu/Debian
# (apt + xclip/wl-copy + Ctrl+Shift keybinds). macOS behavior is unchanged.
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
BASHRC="${HOME}/.bashrc"
OS_NAME="$(uname -s)"

AUTO_ATTACH=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --auto-attach) AUTO_ATTACH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
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

is_macos() { [[ "$OS_NAME" == "Darwin" ]]; }
is_linux() { [[ "$OS_NAME" == "Linux" ]]; }

need_brew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi
  if [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
    return 0
  fi
  echo "Homebrew is required to install tmux on macOS. Install it from https://brew.sh" >&2
  exit 1
}

apt_install() {
  local packages=("$@")
  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  log "installing with apt: ${missing[*]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] sudo apt-get update && sudo apt-get install -y %s\n' "${missing[*]}"
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install: ${missing[*]}" >&2
    exit 1
  fi
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
}

detect_clipboard() {
  if is_macos; then
    printf '%s' "pbcopy"
    return 0
  fi
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "wl-copy"
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "xclip -selection clipboard"
    return 0
  fi
  if command -v xsel >/dev/null 2>&1; then
    printf '%s' "xsel --clipboard --input"
    return 0
  fi
  # Prefer xclip after apt_install; fall back to wl-copy name for Wayland-only boxes.
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    printf '%s' "wl-copy"
  else
    printf '%s' "xclip -selection clipboard"
  fi
}

install_deps() {
  if command -v tmux >/dev/null 2>&1; then
    log "tmux already installed: $(tmux -V)"
  elif is_macos; then
    need_brew
    log "installing tmux with Homebrew"
    run brew install tmux
  elif is_linux && command -v apt-get >/dev/null 2>&1; then
    apt_install tmux
  else
    echo "tmux is not installed, and no supported package manager was found (brew / apt-get)." >&2
    exit 1
  fi

  if is_linux && command -v apt-get >/dev/null 2>&1; then
    local clip_pkgs=()
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
      clip_pkgs+=(wl-clipboard)
    fi
    clip_pkgs+=(xclip)
    apt_install "${clip_pkgs[@]}"
  fi
}

ensure_bin_path() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 0
  if grep -Eq 'HOME/bin|\$HOME/bin|~/bin' "$rc_file"; then
    return 0
  fi
  backup "$rc_file"
  log "adding ~/bin to PATH in $rc_file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  printf '\n# ghostty-tmux-setup: tm helper\ncase ":$PATH:" in\n  *:"$HOME/bin":*) ;;\n  *) export PATH="$HOME/bin:$PATH" ;;\nesac\n' >>"$rc_file"
}

write_tmux_conf() {
  local copy_cmd
  copy_cmd="$(detect_clipboard)"
  backup "$TMUX_CONF"
  log "writing $TMUX_CONF (clipboard: $copy_cmd)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  COPY_CMD="$copy_cmd" python3 - "$TMUX_CONF" <<'PY'
from pathlib import Path
import os, sys

dest = Path(sys.argv[1])
copy_cmd = os.environ["COPY_CMD"]
# Escape for embedding inside double-quoted tmux command strings.
copy_cmd_q = copy_cmd.replace("\\", "\\\\").replace('"', '\\"')

dest.write_text(f"""# Ghostty + tmux — prefix is Ctrl-b (tmux default).
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

bind r source-file ~/.tmux.conf \\; display-message "tmux reloaded"

bind | split-window -h -c "#{{pane_current_path}}"
bind - split-window -v -c "#{{pane_current_path}}"
bind c new-window -c "#{{pane_current_path}}"

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# prefix + s / Ghostty shortcut → pick a named session
bind s choose-tree -Zs
# prefix + S → write the paste buffer to a file (the blog's save-buffer)
bind S command-prompt -p "save-buffer:" "save-buffer '%%'"

setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "{copy_cmd_q}"
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "{copy_cmd_q}"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "{copy_cmd_q}"

bind -n M-Left previous-window
bind -n M-Right next-window
""")
PY
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
  # macOS: Cmd+s / Cmd+b. Linux: Ctrl+Shift+s / Ctrl+Shift+b (Super+s often
  # conflicts with the desktop). Both sets are written so one config travels.
  python3 - "$tmp" "$GHOSTTY_CONF" <<'PY'
import pathlib, sys
src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
text = text.rstrip() + "\n\n"
block = """# >>> ghostty-tmux-setup
# Ghostty splits are for scratch panes. tmux holds the real session.
# Disable auto-copy so mouse select hits tmux, not Ghostty.
copy-on-select = false

# Session picker → Ctrl-b s
keybind = cmd+s=text:\\x02\\x73
keybind = ctrl+shift+s=text:\\x02\\x73
# Zoom / unzoom current pane → Ctrl-b z
keybind = cmd+b=text:\\x02\\x7a
keybind = ctrl+shift+b=text:\\x02\\x7a
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
# Source from ~/.bashrc or ~/.zshrc:
#   source ~/.tmux_startup.sh
if [[ -z "${TMUX:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" && -z "${SSH_TTY:-}" && $- == *i* ]]; then
  exec tmux new-session -A -s main
fi
EOF
}

enable_auto_attach_in_rc() {
  local rc_file="$1"
  if [[ ! -f "$rc_file" ]]; then
    return 1
  fi
  if grep -q 'source ~/.tmux_startup.sh' "$rc_file"; then
    if grep -q '^[[:space:]]*source ~/.tmux_startup.sh' "$rc_file"; then
      log "auto-attach already enabled in $rc_file"
      return 0
    fi
    backup "$rc_file"
    log "uncommenting tmux auto-attach in $rc_file"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      return 0
    fi
    python3 - "$rc_file" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace("# source ~/.tmux_startup.sh", "source ~/.tmux_startup.sh")
p.write_text(text)
PY
    return 0
  fi
  backup "$rc_file"
  log "adding auto-attach to $rc_file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  printf '\n# Ghostty + tmux auto-attach\nsource ~/.tmux_startup.sh\n' >>"$rc_file"
  return 0
}

enable_auto_attach() {
  write_startup
  local enabled=0
  if enable_auto_attach_in_rc "$BASHRC"; then
    enabled=1
  fi
  if enable_auto_attach_in_rc "$ZSHRC"; then
    enabled=1
  fi
  if [[ "$enabled" -eq 0 ]]; then
    warn "neither $BASHRC nor $ZSHRC found; source ~/.tmux_startup.sh yourself"
  fi
}

print_cheatsheet() {
  local session_keys zoom_keys copy_hint reload_hint
  if is_macos; then
    session_keys="Ctrl-b s / Cmd+s"
    zoom_keys="Ctrl-b z / Cmd+b"
    copy_hint="copy mode (vim keys → macOS clipboard)"
    reload_hint="Reload Ghostty (Cmd+Shift+, then close/reopen, or just restart Ghostty)."
  else
    session_keys="Ctrl-b s / Ctrl+Shift+s"
    zoom_keys="Ctrl-b z / Ctrl+Shift+b"
    copy_hint="copy mode (vim keys → system clipboard)"
    reload_hint="Reload Ghostty (Ctrl+Shift+, then close/reopen, or just restart Ghostty)."
  fi

  cat <<EOF

Done. ${reload_hint}

Layers
  Ghostty  outer window + scratch splits (Ctrl-arrows you already have)
  tmux     named sessions that survive closing the window

Everyday
  tm                 attach/create session "main"
  tm work            editor + git log + server windows
  tm blog            any named session
  prefix             Ctrl-b
  ${session_keys}   session list
  ${zoom_keys}   zoom pane
  Ctrl-b |  /  -     split right / down
  Ctrl-b c           new window
  Ctrl-b d           detach (session keeps running)
  Ctrl-b [ then v/y  ${copy_hint}

Scratch panes: use Ghostty splits. The tmux session underneath stays put.

EOF
  if [[ "$AUTO_ATTACH" -eq 0 ]]; then
    cat <<EOF
To auto-join tmux when Ghostty opens:
  $SCRIPT_DIR/setup-tmux.sh --auto-attach
  (or uncomment  source ~/.tmux_startup.sh  in ~/.bashrc / ~/.zshrc after this script writes that file)

EOF
  fi
  if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    cat <<EOF
Note: open a new shell (or restart Ghostty) so ~/bin is on PATH and \`tm\` works.

EOF
  fi
}

main() {
  install_deps
  write_tmux_conf
  write_ghostty_conf
  write_tm_helper
  ensure_bin_path "$BASHRC"
  ensure_bin_path "$ZSHRC"
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
