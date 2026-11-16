In the quest for an analogue on Linux of [Autohotkey](https://autohotkey.com) that exclusively runs on Microsoft Windows, neither [autokey](https://github.com/autokey/autokey) nor [espanso](https://github.com/federico-terzi/espanso/) proved as reliable.

# Use

Instead, this little shell script `snippy.sh` lets you fuzzily select a snippet from a popup menu and then types it out, copies it to the clipboard, or pastes it into the focused window.

Each snippet, say `LGTM`, is a file `LGTM` in the snippet directory `~/.config/snippets` (or `$XDG_CONFIG_HOME/snippets`; override with `--dir DIR` or `$SNIPPY_DIR`), and subdirectories work too.
For example, if `~/.config/snippets/LGTM` reads `Looks good to me!`, then fuzzily selecting `LGTM` writes out `Looks good to me!`.
Snippets are listed by most recently modified first (`--alpha` sorts by name), and `--text-only` lists only `*.txt` and `*.md` files.

Before use, a snippet's YAML front matter (a leading block between `---` lines), a byte order mark, carriage returns and leading and trailing blank lines are removed, so the final line is not followed by Enter.

This works quite universally, that is, in every text box, editor, ... because the snippet is typed by simulated key presses.

## Actions

| Option            | Key in rofi or fzf | Action                                                         |
|-------------------|--------------------|----------------------------------------------------------------|
| `--type` (default)| `Ctrl+T`           | Type the snippet into the focused window.                       |
| `--clip`          | `Ctrl+Y`           | Copy the snippet to the clipboard.                              |
| `--paste`         | `Ctrl+P`           | Copy to the clipboard, then press a paste key (falls back to typing). |

`Enter` performs the action given on the command line.
Pasting presses `Shift+Insert` by default; set `SNIPPY_PASTE_KEY` to `ctrl+v`, `ctrl+shift+v` or `insert` to change it.
In (G)Vim or Neovim windows it first leaves to Normal mode. On X11 such a window is recognized by a Vim GUI's window class, by Vim's default title (ending in `- VIM`, `- GVIM` or `- Nvim`), or by a title that the shell sets to the running command (such as `vim notes.txt`); a title that merely contains "vim" does not count. Set `SNIPPY_VIM_PASTE` to `always` or `never` to override the detection.
See `snippy.sh --help` for all options and environment variables.

## Dependencies

- `bash` 4.3 or newer, and `awk`, `find` and `sort`.
- A menu: [rofi](https://github.com/davatorium/rofi) (`rofi-wayland` on Wayland), [wofi](https://hg.sr.ht/~scoopta/wofi), or [fzf](https://github.com/junegunn/fzf) (which needs a terminal); force one with `--menu`.
- For typing and pasting:
  - on X11, [xdotool](https://github.com/jordansissel/xdotool);
  - on Wayland, [wtype](https://github.com/atx/wtype) if the compositor supports the virtual keyboard protocol (not GNOME or KDE), else [ydotool](https://github.com/ReimuNotMoe/ydotool) with `ydotoold` running, else `wdotool`.
- For the clipboard: `wl-copy` (Wayland), `xsel` or `xclip` (X11), or `pbcopy`.

# Installation

1. Save this script, say to `~/bin/snippy.sh`, by

    ```sh
    mkdir -p ~/bin &&
    curl -fLo ~/bin/snippy.sh https://raw.githubusercontent.com/Konfekt/snippy.sh/master/snippy.sh
    ```

1. mark it executable by `chmod a+x ~/bin/snippy.sh`, and
1. put your snippets into `~/.config/snippets`.

To launch `snippy.sh` by a global keyboard shortcut, say by pressing, at the same time, the `Microsoft Windows` key and `S`, use the keyboard shortcut settings of your desktop environment or, on X11, a daemon such as [xbindkeys](https://wiki.archlinux.org/index.php/Xbindkeys) (or [sxhkd](https://wiki.archlinux.org/index.php/Sxhkd)):

1. install `xdotool`, `rofi` and, say, `xbindkeys` (for example, on `openSUSE` by `sudo zypper install xdotool rofi xbindkeys`),
1. add to `~/.xbindkeysrc` a key binding that launches `snippy.sh`, say

    ```sh
    "$HOME/bin/snippy.sh"
        Mod4 + s
    ```

1. start `xbindkeys`.

To start `xbindkeys` automatically at login, say on a `KDE` desktop environment, put a file `xbindkeys.sh` reading

```sh
#! /bin/sh
xbindkeys
```

into `~/.config/autostart-scripts/`.

# Tests

`tests/test.sh` runs `snippy.sh` against stub menu, typing and clipboard tools, so it needs no display.

# Credits

This script is based on [snippy](https://github.com/BarbUk/dotfiles/blob/master/bin/snippy) and [passmenu](https://git.zx2c4.com/password-store/tree/contrib/dmenu/passmenu);
all credit shall be theirs and their licenses apply.
