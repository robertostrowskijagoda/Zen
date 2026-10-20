#!/bin/sh
# Adds Zen from this unpacked folder (Zen-Linux-*.tar.gz) to the applications
# menu of the current user and lets it open zen:// links. Not needed with the
# .deb, which installs the same files for everyone.
#
#   ./install-desktop-entry.sh            add (again after moving the folder)
#   ./install-desktop-entry.sh --remove   take it away
set -eu

here=$(cd "$(dirname "$0")" && pwd)
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
apps="$data_home/applications"
icons="$data_home/icons/hicolor"
desktop="$apps/com.roj.zen.desktop"
icon="$icons/256x256/apps/com.roj.zen.png"

refresh() {
  if command -v update-desktop-database > /dev/null 2>&1; then
    update-desktop-database "$apps" > /dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache > /dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$icons" > /dev/null 2>&1 || true
  fi
}

if [ "${1:-}" = "--remove" ]; then
  rm -f "$desktop" "$icon"
  refresh
  echo "Zen removed from the applications menu."
  exit 0
fi

if [ ! -x "$here/zen" ] || [ ! -f "$here/data/com.roj.zen.desktop" ]; then
  echo "error: run this script from the unpacked Zen folder (next to zen)." >&2
  exit 1
fi

mkdir -p "$apps" "$(dirname "$icon")"
cp "$here/data/app_icon.png" "$icon"

# Exec= with the absolute path in double quotes. Inside the quotes " ` $ and
# \ get a backslash, and every backslash is then doubled once more for the
# desktop file's string escaping (Desktop Entry Specification, "Exec key").
quoted=$(printf '%s' "$here/zen" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g')
tmp="$desktop.tmp"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    Exec=*) printf 'Exec="%s" %%u\n' "$quoted" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < "$here/data/com.roj.zen.desktop" > "$tmp"
mv "$tmp" "$desktop"
refresh

# zen:// links open Zen (the browser asks first).
if command -v xdg-mime > /dev/null 2>&1; then
  xdg-mime default com.roj.zen.desktop x-scheme-handler/zen || true
fi
echo "Zen added to the applications menu; zen:// links now open it."
