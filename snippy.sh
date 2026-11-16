#!/usr/bin/env bash

# Snippet selector with type, yank (clipboard), and paste actions.
# Requires a GUI session (Wayland or X11) with appropriate tools installed:
# - Menu: rofi, rofi-wayland, wofi, or fzf
# - Typing: X11 uses xdotool. Wayland uses wtype when the compositor
#   accepts the virtual-keyboard protocol, else ydotool while ydotoold
#   is running, else wdotool.
# - Clipboard: wl-copy, xsel, xclip, or pbcopy
# Snippets are stored as files under a directory (default: $XDG_CONFIG_HOME/snippets).

# trace exit on error of program or pipe (or use of undeclared variable)
set -o errtrace -o errexit -o pipefail # -o nounset
# optionally debug output by supplying TRACE=1
[[ "${TRACE:-0}" == "1" ]] && set -x
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  shopt -s inherit_errexit
fi

PS4='+\t '
[[ ! -t 0 ]] && [[ -n "$DBUS_SESSION_BUS_ADDRESS" ]] && command -v notify-send > /dev/null 2>&1 && notify=1
error_handler() {
  trap - ERR
  set +o errexit
  local line="${1:-?}" status="${4:-1}" summary body="" start
  summary="Error: In ${BASH_SOURCE[0]}, Lines $1 and $2, Command $3 exited with Status $status"
  # Show the failing line in context, if `pr` is available and the line is known.
  if [[ "$line" =~ ^[0-9]+$ ]] && have pr; then
    start=$(( line > 3 ? line - 3 : 1 ))
    body=$(pr -tn "${BASH_SOURCE[0]}" | tail -n "+$start" | head -n7 | sed "$(( line - start + 1 ))s/^[[:space:]]*/>> /")
  fi
  printf '%s\n%s\n' "$summary" "$body" >&2
  [ -z "${notify:+x}" ] || notify-send --urgency=critical "$summary" "$body" || true
  exit "$status"
}
trap 'error_handler $LINENO "$BASH_LINENO" "$BASH_COMMAND" $?' ERR

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

action_default="type"
store_dir="${SNIPPY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/snippets}"
prompt_symbol="${SNIPPY_PROMPT_SYMBOL:-❯ }"
include_all=1
follow_symlinks=1
sort_recent=1
menu_pref="${SNIPPY_MENU:-auto}"

usage() {
  cat <<'EOF'
Usage: snippy.sh [--type|--clip|--paste] [--dir DIR] [--prompt STR] [--text-only] [--no-follow] [--alpha] [--menu TOOL]

Select a snippet file, strip YAML front matter, trim outer blank lines, then perform an action.

Actions:
  --type        Type into focused window (default).
  --clip        Yank to clipboard.
  --paste       Copy to clipboard then paste keystroke (fallback: type).

Selection keys (rofi and fzf):
  Enter         Perform default action.
  Ctrl+Y        Force clipboard copy.
  Ctrl+T        Force typing.
  Ctrl+P        Force paste.

Options:
  --dir DIR     Override snippet directory (default: ${XDG_CONFIG_HOME:-~/.config}/snippets).
  --prompt STR  Override menu prompt text (default: "❯ ").
  --text-only   Include only *.txt and *.md files (default: include all files).
  --no-follow   Disable symlink following in file discovery (default: follow).
  --alpha       Sort alphabetically (default: sort by mtime when stat supports it).
  --menu TOOL   Force menu tool: rofi|rofi-wayland|wofi|fzf|auto (default: auto).

Environment:
  SNIPPY_DIR, SNIPPY_PROMPT_SYMBOL, SNIPPY_MENU   Defaults for --dir, --prompt, --menu.
  SNIPPY_PASTE_KEY        Paste key: shift+insert (default), ctrl+v, ctrl+shift+v, insert.
  SNIPPY_PASTE_PREP       always (default) or never: type and erase "o" before pasting.
  SNIPPY_PASTE_PREP_DELAY_SEC  Delay after that preparation (default: 0.05).
  SNIPPY_VIM_PASTE        auto (default), always, never: use Vim paste handling.
  SNIPPY_VIM_PASTE_KEY    Paste key in Vim (default: shift+insert).
  SNIPPY_VIM_PASTE_DELAY_SEC   Delay before pasting in Vim (default: 0.05).
  TRACE=1                 Trace execution.
EOF
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --type) action_default="type"; shift ;;
    --clip|--clipboard|--yank) action_default="clip"; shift ;;
    --paste) action_default="paste"; shift ;;
    --dir) shift; [[ $# -gt 0 ]] || die "--dir requires a value"; store_dir="$1"; shift ;;
    --prompt) shift; [[ $# -gt 0 ]] || die "--prompt requires a value"; prompt_symbol="$1"; shift ;;
    --text-only) include_all=0; shift ;;
    --no-follow) follow_symlinks=0; shift ;;
    --alpha) sort_recent=0; shift ;;
    --menu) shift; [[ $# -gt 0 ]] || die "--menu requires a value"; menu_pref="$1"; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Print a snippet without BOM, CRs, YAML front matter, and leading or trailing
# blank lines. The output has no final newline so that typing or pasting it
# does not press Enter at the end.
render_snippet() {
  LC_ALL=C awk '
    function emit(line) {
      if (line ~ /^[[:space:]]*$/) { if (started) pending = pending "\n" line; return }
      printf "%s%s", (started ? pending "\n" : ""), line
      pending = ""; started = 1
    }
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; n = 0; fm[++n] = $0; next }
    in_fm {
      fm[++n] = $0
      if (/^(---|\.\.\.)[[:space:]]*$/) in_fm = 0
      next
    }
    { emit($0) }
    # Unterminated front matter is content, not metadata.
    END { if (in_fm) for (i = 1; i <= n; i++) emit(fm[i]) }
  ' <"$1"
}

copy_to_clipboard() {
  local file="$1"
  [[ -n "${clipboard_tool:-}" ]] || return 1
  # xsel/xclip daemonize after reading stdin; backgrounding races the CLIPBOARD grab
  case "$clipboard_tool" in
    wl-copy|pbcopy) "$clipboard_tool" <"$file" ;;
    xsel) xsel --clipboard --input <"$file" >/dev/null 2>&1 ;;
    xclip) xclip -selection clipboard -in <"$file" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

is_vim_context() {
  case "${SNIPPY_VIM_PASTE:-auto}" in
    always|1|yes|true) return 0 ;;
    never|0|no|false) return 1 ;;
  esac

  # Auto-detect works on X11 only: by a Vim GUI's window class, by Vim's
  # default title ("file (dir) - VIM", "- GVIM1", "- Nvim"), or by a title
  # that a shell sets to the running command ("vim file"). A title merely
  # containing "vim", say a browser tab on "vim-plugin", must not count:
  # pasting there would send Escape.
  if [[ -n "${DISPLAY:-}" ]] && have xdotool; then
    local wname wclass
    wname="$(xdotool getactivewindow getwindowname 2>/dev/null || true)"
    wclass="$(xdotool getactivewindow getwindowclassname 2>/dev/null || true)"
    wname="${wname,,}" wclass="${wclass,,}"
    [[ "$wclass" =~ ^(g?vim|n?vim|nvim-qt|neovide|gnvim|goneovim)$ ||
       "$wname" =~ \ -\ [gn]?vim[0-9]*$ ||
       "$wname" =~ ^(sudo(edit)?\ )?(g?vim|n?vim|nvim|vi|view|vimdiff|nvim-qt)(\ |$) ]]
    return
  fi

  return 1
}

# Send one key (escape, backspace, ctrl+v, ctrl+shift+v, shift+insert, insert)
# with $type_tool.
send_key() {
  local key="${1,,}" k
  case "$key" in
    ins) key=insert ;;
    shift+ins) key=shift+insert ;;
  esac
  case "${type_tool:-}" in
    xdotool|wdotool)
      case "$key" in
        escape) k=Escape ;;
        backspace) k=BackSpace ;;
        ctrl+v|ctrl+shift+v) k="$key" ;;
        shift+insert) k=shift+Insert ;;
        insert) k=Insert ;;
        *) return 1 ;;
      esac
      "$type_tool" key --clearmodifiers "$k"
      ;;
    wtype)
      case "$key" in
        escape) wtype -k Escape ;;
        backspace) wtype -k BackSpace ;;
        ctrl+v) wtype -M ctrl -k v -m ctrl ;;
        ctrl+shift+v) wtype -M ctrl -M shift -k v -m shift -m ctrl ;;
        shift+insert) wtype -M shift -k Insert -m shift ;;
        insert) wtype -k Insert ;;
        *) return 1 ;;
      esac
      ;;
    ydotool)
      # Linux input event codes: 1 Esc, 14 BackSpace, 29 LeftCtrl, 42 LeftShift, 47 V, 110 Insert
      case "$key" in
        escape) ydotool key 1:1 1:0 ;;
        backspace) ydotool key 14:1 14:0 ;;
        ctrl+v) ydotool key 29:1 47:1 47:0 29:0 ;;
        ctrl+shift+v) ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
        shift+insert) ydotool key 42:1 110:1 110:0 42:0 ;;
        insert) ydotool key 110:1 110:0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

send_text() {
  case "${type_tool:-}" in
    xdotool) xdotool type --clearmodifiers --delay 0 -- "$1" ;;
    wtype) wtype -- "$1" ;;
    ydotool) ydotool type -- "$1" ;;
    wdotool) wdotool type --delay 0 --clearmodifiers -- "$1" ;;
    *) return 1 ;;
  esac
}

# `-s 1` connects and sleeps 1ms. It types nothing. Failure means this
# compositor has no virtual-keyboard protocol (Mutter, KWin).
wtype_protocol() {
  have wtype || return 1
  wtype -s 1 >/dev/null 2>&1
}

ydotool_ready() {
  have ydotool || return 1
  pgrep -x ydotoold >/dev/null 2>&1
}

send_paste_keystroke() {
  local paste_key="${SNIPPY_PASTE_KEY:-shift+insert}"
  local vim_paste="${SNIPPY_VIM_PASTE_KEY:-shift+insert}"
  local prep_mode="${SNIPPY_PASTE_PREP:-always}"               # always|never
  local prep_delay="${SNIPPY_PASTE_PREP_DELAY_SEC:-0.05}"      # 50ms default
  local vim_delay="${SNIPPY_VIM_PASTE_DELAY_SEC:-0.05}"

  [[ -n "${type_tool:-}" ]] || return 1

  if is_vim_context; then
    send_key escape && send_text "o" && send_key backspace &&
      sleep "$vim_delay" && send_key "$vim_paste"
    return
  fi

  if [[ "$prep_mode" != "never" ]]; then
    send_text "o" && send_key backspace && sleep "$prep_delay" || return 1
  fi

  send_key "$paste_key"
}

type_text() {
  local file="$1"
  [[ -n "${type_tool:-}" ]] || die "No typing tool available"
  case "$type_tool" in
    xdotool)
      # Type line by line since the undocumented `xdotool type --file` switch fails.
      local line first=1
      if while IFS= read -r line || [[ -n "$line" ]]; do
           if (( first )); then
             first=0
             xdotool sleep 0.1 type --clearmodifiers --delay 10 -- "$line"
           else
             xdotool key Return
             xdotool type --clearmodifiers --delay 1 -- "$line"
           fi
         done <"$file"; then
        # Due to stuck modifier keys https://github.com/jordansissel/xdotool/issues/43
        xdotool sleep 0.4 keyup Meta_L Meta_R Alt_L Alt_R Super_L Super_R Control_L Control_R Shift_L Shift_R
      else
        die "xdotool typing failed"
      fi
      ;;
    wtype)
      wtype - <"$file"
      ;;
    ydotool)
      ydotool type --file - <"$file"
      ;;
    wdotool)
      wdotool type --delay 0 --clearmodifiers --file "$file"
      ;;
    *)
      die "Unknown typing tool: $type_tool"
      ;;
  esac
}

select_menu_tool() {
  local forced="$1"
  if [[ "$forced" != "auto" ]]; then
    have "$forced" || die "Menu tool not found: $forced"
    printf '%s\n' "$forced"
    return 0
  fi

  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && have rofi-wayland; then
    printf '%s\n' rofi-wayland
  elif have rofi; then
    printf '%s\n' rofi
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && have wofi; then
    printf '%s\n' wofi
  elif have fzf; then
    printf '%s\n' fzf
  else
    die "No menu tool found (rofi-wayland/rofi/wofi/fzf)"
  fi
}

# Print "ACTION<TAB>SELECTION"; both are empty if the menu was cancelled.
# A command on the left of && or || triggers neither errexit nor the ERR trap,
# so a cancelled menu is not reported as an error.
menu_select() {
  local tool="$1"
  local -n _entries="$2"
  local out rc=0 key="" sel="" action=""

  case "$tool" in
    rofi|rofi-wayland)
      out="$("$tool" -dmenu -i -sort -matching fuzzy -p "$prompt_symbol" \
        -kb-custom-1 "Control+y" -kb-custom-2 "Control+t" -kb-custom-3 "Control+p" \
        < <(printf '%s\n' "${_entries[@]}"))" || rc=$?
      sel="$out"
      case "$rc" in
        0) action="$action_default" ;;
        10) action="clip" ;;
        11) action="type" ;;
        12) action="paste" ;;
      esac
      ;;
    wofi)
      out="$(wofi --dmenu -p "$prompt_symbol" < <(printf '%s\n' "${_entries[@]}"))" || rc=$?
      if (( rc == 0 )); then
        sel="$out"
        action="$action_default"
      fi
      ;;
    fzf)
      out="$(fzf --prompt="$prompt_symbol" --layout=reverse --height=40% \
        --expect=ctrl-y,ctrl-t,ctrl-p < <(printf '%s\n' "${_entries[@]}"))" || rc=$?
      # 1: no match, 130: cancelled; 2: error, such as no terminal.
      (( rc != 2 )) || die "fzf failed (it needs a terminal; install rofi or wofi for a key binding)"
      if (( rc == 0 )); then
        { IFS= read -r key; IFS= read -r sel; } <<<"$out" || :
        case "$key" in
          ctrl-y) action="clip" ;;
          ctrl-t) action="type" ;;
          ctrl-p) action="paste" ;;
          *) action="$action_default" ;;
        esac
      fi
      ;;
    *)
      die "Unknown menu tool: $tool"
      ;;
  esac

  printf '%s\t%s\n' "$action" "$sel"
}

detect_io_tools() {
  local clipboards=() tool
  type_tool=""
  clipboard_tool=""

  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    if wtype_protocol; then
      type_tool="wtype"
    elif ydotool_ready; then
      type_tool="ydotool"
    elif have wdotool; then
      type_tool="wdotool"
    fi
    clipboards=(wl-copy pbcopy xsel xclip)
  elif [[ -n "${DISPLAY:-}" ]]; then
    if have xdotool; then
      type_tool="xdotool"
    fi
    clipboards=(xsel xclip pbcopy)
  else
    die "No Wayland or X11 display detected"
  fi

  for tool in "${clipboards[@]}"; do
    if have "$tool"; then
      clipboard_tool="$tool"
      break
    fi
  done
}

stat_style="none"
detect_stat_style() {
  have stat || { stat_style="none"; return 0; }
  if stat -c %Y -- "$store_dir" >/dev/null 2>&1; then
    stat_style="gnu"
  elif stat -f %m -- "$store_dir" >/dev/null 2>&1; then
    stat_style="bsd"
  else
    stat_style="none"
  fi
}

file_mtime() {
  local f="$1" deref=()
  (( follow_symlinks )) && deref=(-L)
  case "$stat_style" in
    gnu) stat "${deref[@]}" -c %Y -- "$f" ;;
    bsd) stat "${deref[@]}" -f %m -- "$f" ;;
    *) printf '0\n' ;;
  esac
}

main() {
  [[ -d "$store_dir" ]] || die "Snippet directory not found: $store_dir"
  store_dir="$(cd -P -- "$store_dir" 2>/dev/null && pwd -P)" || die "Snippet directory invalid: $store_dir"

  detect_io_tools
  # `|| exit`: a die in the subshell already reported its error, so the
  # ERR trap must not report it again.
  menu_tool="$(select_menu_tool "$menu_pref")" || exit

  detect_stat_style

  find_args=()
  (( follow_symlinks )) && find_args+=(-L)

  entries=()
  while IFS= read -r -d '' f; do
    rel="${f#"$store_dir"/}"
    if (( include_all )); then
      entries+=("$rel")
    else
      case "$rel" in
        *.txt|*.md) entries+=("$rel") ;;
      esac
    fi
  done < <(
    find "${find_args[@]}" "$store_dir" -name .git -prune -o \
      -type f -not -name '.gitignore' -print0
  )
  ((${#entries[@]})) || die "No matching snippet files found under: $store_dir"

  sorted=()
  if (( sort_recent )) && [[ "$stat_style" != "none" ]]; then
    while IFS=$'\t' read -r _mtime rel; do
      sorted+=("$rel")
    done < <(
      for rel in "${entries[@]}"; do
        printf '%s\t%s\n' "$(file_mtime "$store_dir/$rel")" "$rel"
      done | LC_ALL=C sort -nr
    )
  else
    while IFS= read -r rel; do
      sorted+=("$rel")
    done < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)
  fi
  entries=("${sorted[@]}")

  menu_result="$(menu_select "$menu_tool" entries)" || exit

  action="${menu_result%%$'\t'*}"
  selection="${menu_result#*$'\t'}"
  [[ -n "$selection" && -n "$action" ]] || exit 0

  # Menus such as rofi also return typed text, so accept listed entries only;
  # this also keeps the selection inside the snippet directory.
  found=0
  for rel in "${entries[@]}"; do
    if [[ "$rel" == "$selection" ]]; then
      found=1
      break
    fi
  done
  (( found )) || die "Not a snippet: $selection"
  selected_file="$store_dir/$selection"
  [[ -f "$selected_file" ]] || die "Selected file not found: $selected_file"

  have mktemp || die "mktemp not found"
  tmp_file="$(mktemp -t snippy.XXXXXX)"
  trap 'rm -f -- "$tmp_file"' EXIT

  render_snippet "$selected_file" >"$tmp_file"

  case "$action" in
    clip)
      copy_to_clipboard "$tmp_file" || die "Clipboard tool not available (wl-copy/xsel/xclip/pbcopy)"
      ;;
    paste)
      if copy_to_clipboard "$tmp_file"; then
        send_paste_keystroke || die "Paste keystroke failed"
      else
        type_text "$tmp_file"
      fi
      ;;
    type)
      type_text "$tmp_file"
      ;;
    *)
      die "Unknown action: $action"
      ;;
  esac
}

main
