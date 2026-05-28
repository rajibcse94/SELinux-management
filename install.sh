#!/usr/bin/env bash
#===============================================================================
# install.sh — install selinux-toolkit.sh system-wide
#===============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/selinux-toolkit.sh"
DEST="${PREFIX:-/usr/local/bin}/selinux-toolkit"

if [[ $EUID -ne 0 ]]; then
    echo "This installer needs root. Re-run with: sudo ./install.sh" >&2
    exit 1
fi

[[ -f "$SRC" ]] || { echo "Source not found: $SRC" >&2; exit 1; }

install -m 0755 "$SRC" "$DEST"
echo "Installed: $DEST"
echo "Try: selinux-toolkit status"
