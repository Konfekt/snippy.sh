In the quest for an analogue on Linux of [Autohotkey](https://autohotkey.com) that exclusively runs on Microsoft Windows, neither [autokey](https://github.com/autokey/autokey) nor [espanso](https://github.com/federico-terzi/espanso/) proved as reliable.

# Use

Instead, this little shell script `snippy.sh` that depends on

- [xdotool](https://github.com/jordansissel/xdotool), and
- [rofi](https://github.com/davatorium/rofi) (or `dmenu`)

expands (by typing it out via `xdotool`) a fuzzily selected string from a popup menu (provided by `rofi`).

Each such string, say `LGTM`, is stored as the name of a file `~/.snippy/LGTM` inside `~/.snippy` that expands to the content of the file.
For example, if `~/.snippy/LGTM` reads `Looks good to me!`, then fuzzily selecting `LGTM` writes out `Looks good to me!`.

This works quite universally, that is, in every text box, editor, ... because `xdotool` simulates key presses.

To call it by a global key binding, a daemon such as [xbindkeys](https://wiki.archlinux.org/index.php/Xbindkeys) (or [sxhkd](https://wiki.archlinux.org/index.php/Sxhkd)) is needed.

# Installation

1. Save this script, say to `~/bin/snippy.sh` by

    ```sh
    mkdir --parents ~/bin &&
    curl -fLo https://raw.githubusercontent.com/Konfekt/snippy.sh/master/snippy.sh ~/bin/snippy.sh
    ```
  
1. mark it executable by `chmod a+x ~/bin/snippy.sh`,

To launch `snippy.sh` by a global keyboard shortcut, say by pressing, at the same time, the `Microsoft Windows` key and `S`:

1. install `xdotool`, `rofi` and, say, `Xbindkeys` (or `Sxhkd`), (for example, on `openSUSE` by `sudo zypper install xbindkeys` respectively `sudo zypper install xdotool rofi sxhkd`)
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

# Credits

This script is based on [snippy](https://github.com/BarbUk/dotfiles/blob/master/bin/snippy) and [passmenu](https://git.zx2c4.com/password-store/tree/contrib/dmenu/passmenu);
all credit shall be theirs and their licenses apply.
