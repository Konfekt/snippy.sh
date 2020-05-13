#!/usr/bin/env sh

# Based on:
# https://github.com/BarbUk/dotfiles/blob/master/bin/snippy
# https://git.zx2c4.com/password-store/tree/contrib/dmenu/passmenu

SNIPPET_DIR="$HOME/.snippy"
IGNORE_REGEX='\.git\(/\|config\|keep\|ignore\)' 

PROMPT='❯ '
MENU_ENGINE="rofi"
MENU_ARGS='-dmenu -i -sort'

(
cd "${SNIPPET_DIR}" || exit 1
# Use the filenames in the snippy directory as menu entries.
# Get the menu selection from the user.
FILE="$(find -L . -type f -printf "%T+\t%p\n" | sort -r | awk '{print $2}' |
    sed 's!\.\/!!' |
    grep -v "$IGNORE_REGEX" |
    ${MENU_ENGINE} ${MENU_ARGS} -p "$PROMPT")"

# just return if nothing was selected
[ -r "${FILE}" ] || exit

cat "$FILE" |
    {
        IFS= read -r LINE;
        xdotool type --delay 50 -- "$LINE";
        while IFS= read -r LINE; do
            xdotool key Return;
            xdotool type --delay 50 -- "$LINE";
        done;
    } |
    xdotool type --delay 50 --clearmodifiers --file -
)
