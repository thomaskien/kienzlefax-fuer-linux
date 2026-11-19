#!/usr/bin/env bash
# IMMER verwenden wenn der lokale Kienzlefax-Paketstand für den Kombi-Installer gepackt wird.
set -euo pipefail

die(){ echo "Fehler: $*" >&2; exit 1; }
[[ $# == 2 && "$1" == --output && "$2" == /* ]] || die "Aufruf: bash scripts/pack.sh --output /absoluter/pfad/kienzlefax.tar.gz"
output="$2"
[[ ! -d "$output" ]] || die "Ausgabe ist ein Verzeichnis: $output"
root="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$root/installer-modular/package-files.txt"
[[ -f "$manifest" && -s "$manifest" && ! -L "$manifest" && ! -L "$root/installer-modular" ]] || die "Paketliste fehlt oder ist ungültig: $manifest"

stage="$(mktemp -d)"
archive=""
cleanup(){
  rm -rf -- "$stage"
  if [[ -n "$archive" ]]; then rm -f -- "$archive"; fi
}
trap cleanup EXIT

while IFS= read -r file || [[ -n "$file" ]]; do
  case "/$file/" in
    *//*|*/../*|*/./*) die "Ungültiger relativer Pfad in $manifest: $file" ;;
  esac
  src="$root/$file"
  [[ -f "$src" && -r "$src" && -s "$src" && ! -L "$src" ]] || die "Paketdatei fehlt oder ist nicht lesbar: $src"
  parent="${src%/*}"
  [[ "$(CDPATH= cd -P -- "$parent" && pwd -P)" == "$parent" ]] || die "Paketverzeichnis ist verlinkt: $parent"
  [[ ! "$src" -ef "$output" ]] || die "Ausgabe ist eine Paketquelle: $src"
  dest="$stage/kienzlefax/$file"
  mkdir -p -- "${dest%/*}"
  mode=0644
  if [[ -x "$src" ]]; then mode=0755; fi
  install -m "$mode" "$src" "$dest"
done <"$manifest"

mkdir -p -- "$(dirname -- "$output")"
archive="$(mktemp "$output.tmp.XXXXXXXX")"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$stage" kienzlefax
mv -f -- "$archive" "$output"
archive=""
printf 'Paket erstellt: %s\n' "$output"
