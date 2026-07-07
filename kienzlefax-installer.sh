#!/usr/bin/env bash
set -euo pipefail

REAL_INSTALLER_URL="https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/installer-modular/kienzlefax-install-modular.sh"
REAL_INSTALLER_FILE="kienzlefax-install-modular.sh"

echo "KienzleFax Installer"
echo "Quelle: $REAL_INSTALLER_URL"
echo
echo "Lade Installationsskript…"
echo

rm -f "$REAL_INSTALLER_FILE"
wget "$REAL_INSTALLER_URL" -O "$REAL_INSTALLER_FILE"
chmod +x "$REAL_INSTALLER_FILE"
./"$REAL_INSTALLER_FILE"
