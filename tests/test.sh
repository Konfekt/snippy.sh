#!/usr/bin/env bash
# Run snippy.sh against stub menu, typing, and clipboard tools.
# Usage: tests/test.sh
set -o errexit -o nounset -o pipefail

script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/snippy.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
stubs="$work/bin" snippets="$work/snippets" log="$work/log"
mkdir -p "$stubs" "$snippets/sub" "$snippets/.git"
export LOG="$log"

# fzf prints $FZF_KEY and $FZF_PICK (or the first entry) and exits $FZF_RC.
cat >"$stubs/fzf" <<'STUB'
#!/usr/bin/env bash
mapfile -t entries
printf '%s\n' "${entries[@]}" >"$LOG.entries"
[[ "${FZF_RC:-0}" == 0 ]] || exit "$FZF_RC"
printf '%s\n%s\n' "${FZF_KEY:-}" "${FZF_PICK:-${entries[0]}}"
STUB
# rofi prints $FZF_PICK and exits $ROFI_RC (10-12 select custom actions).
cat >"$stubs/rofi" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$FZF_PICK"
exit "${ROFI_RC:-0}"
STUB
for tool in xdotool wtype; do
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$LOG"\n' "$tool" >"$stubs/$tool"
done
# xdotool reports $WIN_NAME and $WIN_CLASS as the active window.
cat >>"$stubs/xdotool" <<'STUB'
[[ "$*" == "getactivewindow getwindowname" ]] && printf '%s\n' "${WIN_NAME:-}"
[[ "$*" == "getactivewindow getwindowclassname" ]] && printf '%s\n' "${WIN_CLASS:-}"
exit 0
STUB
# wtype -s 1 probes the protocol; `wtype -` reads text from stdin.
cat >>"$stubs/wtype" <<'STUB'
[[ "$*" == - ]] && { printf 'stdin:'; cat; printf '|\n'; } >>"$LOG"
exit 0
STUB
cat >"$stubs/xsel" <<'STUB'
#!/usr/bin/env bash
{ printf 'clip:'; cat; printf '|\n'; } >>"$LOG"
STUB
chmod +x "$stubs"/*

printf 'Looks good to me!\n' >"$snippets/LGTM"
printf '\xef\xbb\xbf---\r\ntitle: x\r\n---\r\n\r\n\r\nline 1\r\n\r\n  line 2\r\n\r\n\r\n' >"$snippets/sub/fm.md"
printf -- '---\nnot closed\n' >"$snippets/open.txt"
printf 'no newline' >"$snippets/nonl.txt"
printf 'x\n' >"$snippets/.git/config"
touch -d '2001-01-01' "$snippets/LGTM"

pass=0 fail=0
check() { # NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n--- expected\n%s\n--- actual\n%s\n' "$1" "$2" "$3"
  fi
}
run() { # ENV... -- ARGS...
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  : >"$log"
  env -u WAYLAND_DISPLAY DISPLAY=:99 PATH="$stubs:$PATH" "${envs[@]}" \
    bash "$script" --menu fzf --dir "$snippets" "$@"
}

run FZF_PICK=sub/fm.md -- --clip
check "front matter, CRLF, BOM, outer blank lines" "clip:line 1

  line 2|" "$(cat "$log")"

run FZF_PICK=open.txt -- --clip
check "unterminated front matter is kept" "clip:---
not closed|" "$(cat "$log")"

run FZF_PICK=LGTM -- --clip
check "plain snippet" "clip:Looks good to me!|" "$(cat "$log")"
check "mtime sort, .git skipped" "LGTM" "$(tail -n1 "$log.entries")"
check ".git skipped" "" "$(grep -F .git "$log.entries" || :)"

run FZF_PICK=LGTM -- --alpha --text-only --clip 2>/dev/null || :
check "--text-only filters" "nonl.txt
open.txt
sub/fm.md" "$(cat "$log.entries")"

run FZF_PICK=sub/fm.md -- --type
check "xdotool typing" "xdotool sleep 0.1 type --clearmodifiers --delay 10 -- line 1
xdotool key Return
xdotool type --clearmodifiers --delay 1 -- 
xdotool key Return
xdotool type --clearmodifiers --delay 1 --   line 2" "$(grep -v keyup "$log")"

run FZF_PICK=nonl.txt -- --type
check "last line without newline is typed" "xdotool sleep 0.1 type --clearmodifiers --delay 10 -- no newline" "$(grep -v keyup "$log")"

run FZF_PICK=LGTM FZF_KEY=ctrl-p SNIPPY_VIM_PASTE=never -- --type
check "ctrl-p pastes" "clip:Looks good to me!|
xdotool type --clearmodifiers --delay 0 -- o
xdotool key --clearmodifiers BackSpace
xdotool key --clearmodifiers shift+Insert" "$(cat "$log")"

run FZF_PICK=LGTM SNIPPY_VIM_PASTE=always SNIPPY_VIM_PASTE_KEY=Ctrl+V -- --paste
check "vim paste" "clip:Looks good to me!|
xdotool key --clearmodifiers Escape
xdotool type --clearmodifiers --delay 0 -- o
xdotool key --clearmodifiers BackSpace
xdotool key --clearmodifiers ctrl+v" "$(cat "$log")"

out="$(run FZF_PICK=LGTM SNIPPY_PASTE_KEY=bogus SNIPPY_VIM_PASTE=never -- --paste 2>&1)" && rc=0 || rc=$?
check "bad paste key fails" "1 Error: Paste keystroke failed" "$rc $out"

out="$(run FZF_RC=130 -- 2>&1)" && rc=0 || rc=$?
check "cancel exits quietly" "0 " "$rc $out"

out="$(run FZF_PICK=../outside -- 2>&1)" && rc=0 || rc=$?
check "unlisted selection is refused" "1 Error: Not a snippet: ../outside" "$rc $out"

run FZF_PICK=LGTM ROFI_RC=10 -- --menu rofi --type
check "rofi Ctrl+Y copies" "clip:Looks good to me!|" "$(cat "$log")"

out="$(run FZF_PICK=LGTM ROFI_RC=1 -- --menu rofi 2>&1)" && rc=0 || rc=$?
check "rofi cancel exits quietly" "0 " "$rc $out"

: >"$log"
env WAYLAND_DISPLAY=w PATH="$stubs:$PATH" FZF_PICK=sub/fm.md \
  bash "$script" --menu fzf --dir "$snippets" --type
check "wtype typing" "wtype -s 1
wtype -
stdin:line 1

  line 2|" "$(cat "$log")"

vim_paste_for() { # WINDOW_NAME WINDOW_CLASS -> "vim" or "plain"
  run FZF_PICK=LGTM WIN_NAME="$1" WIN_CLASS="$2" -- --paste
  if grep -q Escape "$log"; then echo vim; else echo plain; fi
}
check "Vim title detected" vim "$(vim_paste_for 'notes.txt (~/doc) - VIM' XTerm)"
check "GVim server title detected" vim "$(vim_paste_for 'notes.txt (~/doc) - GVIM1' Gvim)"
check "Neovim title detected" vim "$(vim_paste_for 'notes.txt - Nvim' kitty)"
check "shell-set title detected" vim "$(vim_paste_for 'nvim notes.txt' Alacritty)"
check "Vim GUI class detected" vim "$(vim_paste_for 'untitled' neovide)"
check "browser tab on a Vim plugin is not Vim" plain \
  "$(vim_paste_for 'Konfekt/vim-CtrlXA: increment - Mozilla Firefox' firefox)"
check "editor named like Vim is not Vim" plain "$(vim_paste_for 'evim-notes - Kate' kate)"

out="$(run FZF_RC=2 -- 2>&1)" && rc=0 || rc=$?
check "fzf error is reported once" "1 Error: fzf failed (it needs a terminal; install rofi or wofi for a key binding)" "$rc $out"

out="$(run -- --menu bogus 2>&1)" && rc=0 || rc=$?
check "missing menu tool is reported once" "1 Error: Menu tool not found: bogus" "$rc $out"

# A failing command without `pr` on PATH still reports the error.
nopr="$work/nopr"
mkdir -p "$nopr"
for tool in bash env cat find sort awk sed head tail mktemp stat rm; do
  ln -s "$(command -v "$tool")" "$nopr/$tool"
done
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[[ $1 == -s ]] || exit 3\n' >"$nopr/wtype"
cp "$stubs/fzf" "$nopr/fzf"
chmod +x "$nopr/wtype"
out="$(env -i HOME="$work" WAYLAND_DISPLAY=w PATH="$nopr" FZF_PICK=LGTM LOG="$log" \
  "$nopr/bash" "$script" --menu fzf --dir "$snippets" --type 2>&1)" && rc=0 || rc=$?
check "error without pr is reported" "3 yes" "$rc $(grep -q '^Error: In .*exited with Status 3' <<<"$out" && echo yes)"

out="$(env -u WAYLAND_DISPLAY -u DISPLAY bash "$script" --dir "$snippets" 2>&1)" && rc=0 || rc=$?
check "no display" "1 Error: No Wayland or X11 display detected" "$rc $out"

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
