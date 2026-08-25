#!/usr/bin/env bash
# Installs pihole-tui to ~/.local/bin/pihole-tui.
#
# Uses the system python3 and the distro's python3-rich. No venv: Ubuntu's
# python3.14 ships without ensurepip, so `python3 -m venv` fails unless
# python3.14-venv is installed, and that needs sudo for no benefit here.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/pihole-tui"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pihole-tui.py"

if ! python3 -c "import rich" 2>/dev/null; then
    echo "error: python3 cannot import rich." >&2
    echo "       install it with:  sudo apt install python3-rich" >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${PIHOLE_CONTAINER:-pihole}"; then
    echo "warning: container '${PIHOLE_CONTAINER:-pihole}' is not running." >&2
fi

mkdir -p "$BIN_DIR" "$APP_DIR"
install -m 0644 "$SRC" "$APP_DIR/pihole-tui.py"

cat > "$BIN_DIR/pihole-tui" <<LAUNCHER
#!/usr/bin/env bash
exec python3 "$APP_DIR/pihole-tui.py" "\$@"
LAUNCHER
chmod +x "$BIN_DIR/pihole-tui"

echo "installed: $BIN_DIR/pihole-tui"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on PATH - the menu calls it by full path anyway" ;;
esac
