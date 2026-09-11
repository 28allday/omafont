#!/bin/sh
# Register the double-click handler. Optional -- the panel works without it.
set -eu

# Pin PATH before running anything: a login PATH can carry user-writable
# directories ahead of /usr/bin, which would make every bare command name below
# substitutable.
PATH=/usr/local/bin:/usr/bin:/bin
export PATH

bindir="${XDG_BIN_HOME:-$HOME/.local/bin}"
appdir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mkdir -p -- "$bindir" "$appdir"
install -m 755 -- "$here/omafont-open" "$bindir/omafont-open"
install -m 644 -- "$here/omafont.desktop" "$appdir/omafont.desktop"

update-desktop-database "$appdir" >/dev/null 2>&1 || true
for m in font/ttf font/otf font/collection font/sfnt \
         application/x-font-ttf application/x-font-otf; do
  xdg-mime default omafont.desktop "$m" >/dev/null 2>&1 || true
done

echo "Handler installed."
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "Warning: $bindir is not on PATH -- the handler will not run." >&2 ;;
esac
