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

The right pane shows a specimen at four sizes plus the full alphabet and
figures, rendered from the font file itself. That matters for a font you have
just dropped in: it has not been installed yet, and it still previews.

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

## Requirements

`fontconfig` (already present on any Omarchy install). `zenity` is optional —
if it is installed you get an **Install from file...** button; if not, use
drag-and-drop or the double-click handler.

## Licence

MIT.
