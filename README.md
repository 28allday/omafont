# Fonts

A font manager for the Omarchy shell. Browse what is installed, preview
anything before you commit to it, install with a drop or a double-click, and
remove the ones you added.

![kind](https://img.shields.io/badge/kind-panel%20%2B%20bar--widget-blue)

## Install

```bash
omarchy plugin add <repo-url> --enable
```

Then, optionally, register the double-click handler so opening a font file in
your file manager brings up the panel:

```bash
~/.config/omarchy/plugins/nosignal.omafont/handler/install-handler.sh
```

## Opening it

| How | What happens |
|---|---|
| The **Aa** icon in the bar | Toggles the panel |
| `omarchy-shell shell toggle nosignal.omafont` | Same, from a script or keybinding |
| Double-click a `.ttf` / `.otf` in your file manager | Opens with that font staged and previewed |
| Drop a font file on the open panel | Same |

## Using it

The left rail lists your font families, split into **Yours** — the ones in
`~/.local/share/fonts`, which you can remove — and **System**, which belong to
packages and are preview-only. The filter takes focus as soon as the panel
opens, so you can just start typing. An `M` marks a monospace family.

**Language fonts are hidden by default.** A typical Arch install carries around
300 Noto families — one per writing system, several widths each — which buries
the forty or so fonts you would ever deliberately choose. They stay installed
(your browser and terminal need them for Arabic, CJK, Hebrew and emoji); they
are just folded out of the way. A line under the filter tells you how many are
hidden and unfolds them with a click, and typing a filter searches all of them
regardless — so `tamil` still finds the Tamil fonts.

Each family is set **in its own face**, so the list shows you fonts rather than
a list of names. Families that cannot set Latin — icon fonts, emoji, and the
Noto script faces — fall back to the interface font instead of rendering their
own name as unrelated symbols.

The right pane is a type specimen: the name at display size, provenance and
style count as chips, an **editable sample line**, then five size-labelled
lines, the glyph block, and every style in the family. Everything is rendered
from the font file itself, which is what lets a font you just dropped in —
not yet installed — preview exactly like one already on disk.

Buttons along the bottom, shown when they apply:

- **Install** — copies a staged font into `~/.local/share/fonts/<Family>/` and
  refreshes the font cache. No password needed.
- **Set as terminal font** — monospace families only. Hands off to the stock
  `omarchy-font-set`, which updates your terminal configs and the system
  monospace alias.
- **Remove** — deletes a family you installed, then prunes the empty folder.
  Only ever touches `~/.local/share/fonts`; system fonts cannot be removed
  from here.

Keys: `Esc` clears the filter, then closes. `Enter` installs a staged font.
`r` rescans and `/` jumps to the filter when the filter is not focused.

## One thing to know

**Applications that are already running will not see a newly installed font
until they restart.** That is fontconfig, not this plugin — every font
manager on Linux behaves this way. New windows pick it up immediately.

## Removing it

```bash
omarchy plugin remove nosignal.omafont
```

If you registered the double-click handler, undo it with:

```bash
rm -f ~/.local/bin/omafont-open ~/.local/share/applications/omafont.desktop
update-desktop-database ~/.local/share/applications
```

Fonts you installed through the panel stay in `~/.local/share/fonts` — removing
the plugin does not touch them. Delete the folders there if you want them gone.

## Requirements

| | |
|---|---|
| `fontconfig` | `fc-list`, `fc-scan`, `fc-cache` — present on any Omarchy install |
| `jq` | one-time registration in `shell.json` — an Omarchy dependency already |
| `unzip` | only to install from a `.zip`; everything else works without it |
| `zenity` | **optional.** Adds the *Install from file…* button. Without it, use drag-and-drop or the double-click handler |

No network access, no elevated privileges — everything runs as you, and writes
only to `~/.local/share/fonts`.

## Licence

MIT — see [LICENSE](LICENSE).
