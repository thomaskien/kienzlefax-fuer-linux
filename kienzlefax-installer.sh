#!/usr/bin/env bash
set -euo pipefail

installer_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
modules_dir="${installer_path%/*}/installer-modular"
if [[ -e "$modules_dir" || -L "$modules_dir" ]]; then
  main="$modules_dir/kienzlefax-install-modular.sh"
  if [[ ! -f "$main" || ! -r "$main" || ! -s "$main" || -L "$main" || -L "$modules_dir" ]]; then
    echo "Fehler: Lokaler Hauptinstaller fehlt, ist unlesbar oder verlinkt: $main" >&2
    exit 1
  fi
  exec bash "$main" "$@"
fi
if (( $# )); then
  echo "Fehler: Der Start mit Installationsoptionen benötigt das lokale Paket: $modules_dir/kienzlefax-install-modular.sh" >&2
  exit 1
fi

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
