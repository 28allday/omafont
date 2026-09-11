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

The left rail lists every font family on the machine, split into **Yours** —
the ones in `~/.local/share/fonts`, which you can remove — and **System**,
which belong to packages and are preview-only. Type to filter. An `M` marks a
monospace family.

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

Keys: `Esc` or `q` closes, `/` jumps to the filter, `r` rescans.

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
