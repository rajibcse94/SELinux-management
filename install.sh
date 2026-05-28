#!/usr/bin/env bash
#===============================================================================
# install.sh — install the SELinux management scripts system-wide
#===============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"

if [[ $EUID -ne 0 ]]; then
    echo "This installer needs root. Re-run with: sudo ./install.sh" >&2
    exit 1
fi

install_one() {
    local src="$SRC_DIR/$1" dest="$PREFIX/$2"
    [[ -f "$src" ]] || { echo "Source not found: $src" >&2; return 1; }
    install -m 0755 "$src" "$dest"
    echo "Installed: $dest"
}

install_one selinux-toolkit.sh selinux-toolkit
install_one selinux-config.sh  selinux-config

echo
echo "Done. Try:"
echo "  selinux-toolkit status"
echo "  selinux-config customizations"
