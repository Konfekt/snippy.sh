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
  summary="Error: In ${BASH_SOURCE[0]}, Lines $1 and $2, Command $3 exited with Status $4"
  body=$(pr -tn "${BASH_SOURCE[0]}" | tail -n+$(($1 - 3)) | head -n7 | sed '4s/^\s*/>> /')
  echo >&2 -en "$summary\n$body"
  [ -z "${notify:+x}" ] || notify-send --urgency=critical "$summary" "$body"
  exit "$4"
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

strip_yaml_front_matter() {
  local file="$1"
  if ! have awk; then
    cat -- "$file"
    return 0
  fi
  awk '
    NR==1 { sub(/^\357\273\277/, "", $0) }
    { sub(/\r$/, "", $0) }
    NR==1 && $0 ~ /^---[[:space:]]*$/ { in_fm=1; buf=$0 ORS; next }
    in_fm {
      buf = buf $0 ORS
      if ($0 ~ /^(---|\.\.\.)[[:space:]]*$/) { in_fm=0; stripped=1; buf=""; next }
      next
    }
    { print }
    END { if (in_fm && !stripped) printf "%s", buf }''
  ' <"$file"
}

trim_outer_blank_lines() {
  have sed || { cat; return 0; }
  # strip initial and trailing whitespace/newlines
  sed -e '1{/^[[:space:]]*$/d;}' -e '${/^[[:space:]]*$/d;}'
}

copy_to_clipboard() {
  local file="$1"
  [[ -n "${clipboard_tool:-}" ]] || return 1
  case "$clipboard_tool" in
    wl-copy|pbcopy)
      "$clipboard_tool" "${clipboard_args[@]}" <"$file"
      ;;
    xsel|xclip)
      # xsel/xclip daemonize after reading stdin; backgrounding races the CLIPBOARD grab
      "$clipboard_tool" "${clipboard_args[@]}" <"$file" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

is_vim_context() {
  case "${SNIPPY_VIM_PASTE:-auto}" in
    always|1|yes|true) return 0 ;;
    never|0|no|false) return 1 ;;
  esac

  # Auto-detect works best for GVim/Neovim GUI on X11.  
  if [[ -n "${DISPLAY:-}" ]] && have xdotool; then
    local wname wclass
    wname="$(xdotool getactivewindow getwindowname 2>/dev/null || true)"
    wclass="$(xdotool getactivewindow getwindowclassname 2>/dev/null || true)"
    printf '%s\n%s\n' "$wname" "$wclass" | LC_ALL=C grep -Eiq '(^|[^[:alnum:]])(g?vim|n?vim|neovim)([^[:alnum:]]|$)'
    return $?
  fi

  return 1
}

xdotool_combo() {
  local combo="${1,,}"
  case "$combo" in
    ctrl+v) xdotool key --clearmodifiers ctrl+v ;;
    ctrl+shift+v) xdotool key --clearmodifiers ctrl+shift+v ;;
    shift+insert|shift+ins) xdotool key --clearmodifiers Shift+Insert ;;
    insert|ins) xdotool key --clearmodifiers Insert ;;
    *) return 1 ;;
  esac
}

wtype_combo() {
  local combo="${1,,}"
  case "$combo" in
    ctrl+v) wtype -M ctrl -k v -m ctrl ;;
    ctrl+shift+v) wtype -M ctrl -M shift -k v -m shift -m ctrl ;;
    shift+insert|shift+ins) wtype -M shift -k Insert -m shift ;;
    insert|ins) wtype -k Insert ;;
    *) return 1 ;;
  esac
}

ydotool_combo() {
  local combo="${1,,}"
  case "$combo" in
    ctrl+v) ydotool key 29:1 47:1 47:0 29:0 ;;
    ctrl+shift+v) ydotool key 29:1 42:1 47:1 47:0 42:0 29:0 ;;
    shift+insert|shift+ins) ydotool key 42:1 110:1 110:0 42:0 ;;
    insert|ins) ydotool key 110:1 110:0 ;;
    *) return 1 ;;
  esac
}

wdotool_combo() {
  local combo="${1,,}"
  case "$combo" in
    ctrl+v) wdotool key --clearmodifiers ctrl+v ;;
    ctrl+shift+v) wdotool key --clearmodifiers ctrl+shift+v ;;
    shift+insert|shift+ins) wdotool key --clearmodifiers shift+Insert ;;
    insert|ins) wdotool key --clearmodifiers Insert ;;
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

_send_text_literal() {
  case "${paste_tool:-}" in
    xdotool) xdotool type --clearmodifiers --delay 0 -- "$1" ;;
    wtype) wtype -- "$1" ;;
    ydotool) ydotool type -- "$1" ;;
    wdotool) wdotool type --delay 0 --clearmodifiers -- "$1" ;;
    *) return 1 ;;
  esac
}

_send_key_backspace() {
  case "${paste_tool:-}" in
    xdotool) xdotool key --clearmodifiers BackSpace ;;
    wtype) wtype -k BackSpace ;;
    ydotool) ydotool key 14:1 14:0 ;;
    wdotool) wdotool key --clearmodifiers BackSpace ;;
    *) return 1 ;;
  esac
}

_send_key_escape() {
  case "${paste_tool:-}" in
    xdotool) xdotool key --clearmodifiers Escape ;;
    wtype) wtype -k Escape ;;
    ydotool) ydotool key 1:1 1:0 ;;
    wdotool) wdotool key --clearmodifiers Escape ;;
    *) return 1 ;;
  esac
}

_send_combo_any() {
  local combo="${1:-}"
  case "${paste_tool:-}" in
    xdotool) xdotool_combo "$combo" ;;
    wtype) wtype_combo "$combo" ;;
    ydotool) ydotool_combo "$combo" ;;
    wdotool) wdotool_combo "$combo" ;;
    *) return 1 ;;
  esac
}

send_paste_keystroke() {
  local paste_key="${SNIPPY_PASTE_KEY:-shift+insert}"
  local vim_paste="${SNIPPY_VIM_PASTE_KEY:-shift+insert}"
  local prep_mode="${SNIPPY_PASTE_PREP:-always}"               # always|never
  local prep_delay="${SNIPPY_PASTE_PREP_DELAY_SEC:-0.05}"      # 50ms default
  local vim_delay="${SNIPPY_VIM_PASTE_DELAY_SEC:-0.05}"

  [[ -n "${paste_tool:-}" ]] || return 1

  if is_vim_context; then
    _send_key_escape
    _send_text_literal "o"
    _send_key_backspace
    sleep "$vim_delay"
    _send_combo_any "$vim_paste" || return 1
    return 0
  fi

  if [[ "$prep_mode" != "never" ]]; then
    _send_text_literal "o"
    _send_key_backspace
    sleep "$prep_delay"
  fi

  _send_combo_any "$paste_key" || return 1
}

type_text() {
  local file="$1"
  [[ -n "${type_tool:-}" ]] || die "No typing tool available"
  case "$type_tool" in
    xdotool)
      # Instead of `{ ... } < "$file"` the undocumented `xdotool ... --file $file` switch fails:
      if {
      	  IFS= read -r LINE
      	  xdotool sleep 0.1 type --clearmodifiers --delay 10 -- "$LINE"
      	  while IFS= read -r LINE; do
      	  xdotool key Return
      	  xdotool type --clearmodifiers --delay 1 -- "$LINE"
      	  done
      	} < "$file"; then
      	# Due to stuck modifier keys https://github.com/jordansissel/xdotool/issues/43
      	xdotool sleep 0.4 keyup Meta_L Meta_R Alt_L Alt_R Super_L Super_R Control_L Control_R Shift_L Shift_R
      else
      	die "xdotool typing failed"
      fi
      ;;
    wtype)
      cat -- "$file" | wtype -
      ;;
    ydotool)
      cat -- "$file" | ydotool type --file -
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

menu_select() {
  local tool="$1"
  local -n _entries="$2"
  local out rc key sel action

  case "$tool" in
    rofi|rofi-wayland)
      local rofi_args=(-dmenu -i -sort -matching fuzzy -p "$prompt_symbol" -kb-custom-1 "Control+y" -kb-custom-2 "Control+t" -kb-custom-3 "Control+p")

      # Save and disable errexit and errtrace for rofi invocation
      errtrace_was_set=0
      errexit_was_set=0
      [[ "$-" == *E* ]] && errtrace_was_set=1
      [[ "$-" == *e* ]] && errexit_was_set=1
      old_err_trap="$(trap -p ERR)"
      set +eE
      trap ':' ERR

      out="$(printf '%s\n' "${_entries[@]}" | "$tool" "${rofi_args[@]}")"
      rc=$?

      # Restore errexit and errtrace settings
      (( errtrace_was_set )) && set -E
      (( errexit_was_set )) && set -e
      eval "$old_err_trap"

      sel="$out"
      case "$rc" in
        0) action="$action_default" ;;
        10) action="clip" ;;
        11) action="type" ;;
        12) action="paste" ;;
        *) action="";;
      esac
      ;;
    wofi)
      set +e
      out="$(printf '%s\n' "${_entries[@]}" | wofi --dmenu -p "$prompt_symbol")"
      rc=$?
      set -e
      [[ "$rc" -eq 0 ]] || { printf '%s\t%s\n' "" ""; return 0; }
      sel="$out"
      action="$action_default"
      ;;
    fzf)
      set +e
      out="$(printf '%s\n' "${_entries[@]}" | fzf --prompt="$prompt_symbol" --layout=reverse --height=40% --expect=ctrl-y,ctrl-t,ctrl-p)"
      rc=$?
      set -e
      [[ "$rc" -eq 0 ]] || { printf '%s\t%s\n' "" ""; return 0; }
      key="$(printf '%s\n' "$out" | sed -n '1p')"
      sel="$(printf '%s\n' "$out" | sed -n '2p')"
      case "$key" in
        ctrl-y) action="clip" ;;
        ctrl-t) action="type" ;;
        ctrl-p) action="paste" ;;
        *) action="$action_default" ;;
      esac
      ;;
    *)
      die "Unknown menu tool: $tool"
      ;;
  esac

  printf '%s\t%s\n' "${action:-}" "${sel:-}"
}

detect_io_tools() {
  type_tool=""
  clipboard_tool=""
  paste_tool=""
  clipboard_args=()

  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    if wtype_protocol; then
      type_tool="wtype"
      paste_tool="wtype"
    elif ydotool_ready; then
      type_tool="ydotool"
      paste_tool="ydotool"
    elif have wdotool; then
      type_tool="wdotool"
      paste_tool="wdotool"
    fi

    if have wl-copy; then
      clipboard_tool="wl-copy"
      clipboard_args=()
    elif have pbcopy; then
      clipboard_tool="pbcopy"
      clipboard_args=()
    elif have xsel; then
      clipboard_tool="xsel"
      clipboard_args=(--clipboard --input)
    elif have xclip; then
      clipboard_tool="xclip"
      clipboard_args=(-selection clipboard -in)
    fi
  elif [[ -n "${DISPLAY:-}" ]]; then
    have xdotool && type_tool="xdotool" && paste_tool="xdotool"
    if have xsel; then
      clipboard_tool="xsel"
      clipboard_args=(--clipboard --input)
    elif have xclip; then
      clipboard_tool="xclip"
      clipboard_args=(-selection clipboard -in)
    elif have pbcopy; then
      clipboard_tool="pbcopy"
      clipboard_args=()
    fi
  else
    if have fzf; then
      die "No GUI session detected for typing or pasting"
    else
      die "No Wayland or X11 display detected"
    fi
  fi
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
  local f="$1"
  case "$stat_style" in
    gnu) stat -c %Y -- "$f" ;;
    bsd) stat -f %m -- "$f" ;;
    *) printf '0\n' ;;
  esac
}

main() {
  [[ -d "$store_dir" ]] || die "Snippet directory not found: $store_dir"
  store_dir="$(cd -P -- "$store_dir" 2>/dev/null && pwd -P)" || die "Snippet directory invalid: $store_dir"

  detect_io_tools
  menu_tool="$(select_menu_tool "$menu_pref")"

  detect_stat_style

  find_args=()
  (( follow_symlinks )) && find_args+=(-L)

  files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(
    find "${find_args[@]}" "$store_dir" -type f \
      -not -path '*/.git/*' -not -name '.gitignore' \
      -print0
  )

  ((${#files[@]})) || die "No snippet files found under: $store_dir"

  entries=()
  if (( include_all )); then
    for f in "${files[@]}"; do
      entries+=("${f#"$store_dir"/}")
    done
  else
    for f in "${files[@]}"; do
      rel="${f#"$store_dir"/}"
      case "$rel" in
        *.txt|*.md) entries+=("$rel") ;;
      esac
    done
  fi
  ((${#entries[@]})) || die "No matching snippet files found under: $store_dir"

  if (( sort_recent )) && [[ "$stat_style" != "none" ]]; then
    sortable=()
    for f in "${files[@]}"; do
      rel="${f#"$store_dir"/}"
      if (( include_all )); then
        :
      else
        case "$rel" in *.txt|*.md) : ;; *) continue ;; esac
      fi
      sortable+=( "$(file_mtime "$f")"$'\t'"$rel" )
    done
    entries=()
    while IFS=$'\t' read -r _mtime rel; do
      entries+=("$rel")
    done < <(printf '%s\n' "${sortable[@]}" | LC_ALL=C sort -nr)
  else
    entries_sorted=()
    while IFS= read -r line; do entries_sorted+=("$line"); done < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort)
    entries=("${entries_sorted[@]}")
  fi

  menu_result="$(menu_select "$menu_tool" entries)"

  action="${menu_result%%$'\t'*}"
  selection="${menu_result#*$'\t'}"
  [[ -n "${selection:-}" ]] || exit 0
  [[ -n "${action:-}" ]] || exit 0

  selected_file="$store_dir/$selection"
  [[ -f "$selected_file" ]] || die "Selected file not found: $selected_file"

  if (( follow_symlinks )); then
    :
  else
    if have realpath; then
      real_selected="$(realpath -- "$selected_file")" || die "Failed to resolve selected path"
      [[ "$real_selected" == "$store_dir/"* ]] || die "Refuse path traversal outside store_dir: $selection"
      selected_file="$real_selected"
    else
      case "$selection" in
        /*|*'..'*) die "Refuse suspicious selection path: $selection" ;;
        *) ;;
      esac
    fi
  fi

  have mktemp || die "mktemp not found"
  tmp_file="$(mktemp -t snippy.XXXXXX)"
  trap 'rm -f -- "$tmp_file"' EXIT

  strip_yaml_front_matter "$selected_file" | trim_outer_blank_lines >"$tmp_file"

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

main "$@"
