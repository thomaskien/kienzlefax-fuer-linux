#!/usr/bin/env bash
# IMMER verwenden wenn WireGuard fuer entfernte KienzleFax-Telefonie-Nebenstellen eingerichtet oder erneuert wird.
set -Eeuo pipefail
umask 077

# WireGuard-Telefonie-Installer für Debian/Asterisk
#
# Version 2:
# - berücksichtigt das gemeinsame WireGuard-Schlüsselpaar einer FRITZ!Box
# - fragt je Gegenstelle ab, ob dort bereits WireGuard-Verbindungen existieren
# - verwendet dann den vorhandenen privaten Schlüssel der FRITZ!Box
# - erzeugt pro FRITZ!Box eine direkt importierbare Konfigurationsdatei
# - richtet KEIN Routing, NAT oder Masquerading ein
# - kann den internen Asterisk-Transport auf die WireGuard-IP binden
# - verändert /etc/asterisk/pjsip.conf und Provider-Transporte nicht

KFX_ENVFILE="${KFX_INSTALLER_ENVFILE:-/etc/kienzlefax-installer.env}"
if [[ -f "$KFX_ENVFILE" ]]; then
    # shellcheck disable=SC1090
    source "$KFX_ENVFILE"
fi

WG_IF="${KFX_WIREGUARD_INTERFACE:-wg0}"
DEFAULT_WG_NET="${KFX_WIREGUARD_NET:-10.88.0.0/24}"
DEFAULT_WG_SERVER_IP="${KFX_WIREGUARD_SERVER_IP:-10.88.0.1}"
DEFAULT_WG_PORT="${KFX_WIREGUARD_PORT:-51820}"
DEFAULT_FIRST_PEER_HOST="11"
DEFAULT_SIP_PORT="${KFX_PHONE_INTERNAL_PORT:-5060}"
DEFAULT_RTP_RANGE="${KFX_RTP_START:-12000}-${KFX_RTP_END:-12049}"
DEFAULT_ASTERISK_FILE="/etc/asterisk/pjsip-kfx-telefonie.conf"
OUTPUT_DIR="/root/wireguard-fritzbox"

SERVER_CONF="/etc/wireguard/${WG_IF}.conf"
PRESERVED_SERVER_PRIVATE=""
WG_WAS_ACTIVE=0

die() {
    echo "FEHLER: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    if [[ "$default" == "j" ]]; then
        read -r -p "$prompt [J/n]: " answer
        answer="${answer:-j}"
    else
        read -r -p "$prompt [j/N]: " answer
        answer="${answer:-n}"
    fi

    [[ "$answer" =~ ^[JjYy]$ ]]
}

ask_value() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Bitte als root ausführen."
}

safe_name() {
    local raw="$1"
    local result

    result="$(printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"

    [[ -n "$result" ]] || result="fritzbox"
    printf '%s' "$result"
}

install_wireguard() {
    if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
        info "WireGuard ist bereits installiert."
        return
    fi

    if ask_yes_no "WireGuard ist nicht vollständig installiert. Jetzt installieren?" "j"; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y wireguard wireguard-tools
    else
        die "WireGuard wird für die Einrichtung benötigt."
    fi
}

validate_network() {
    local network="$1"
    local server_ip="$2"

    python3 - "$network" "$server_ip" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
    server = ipaddress.ip_address(sys.argv[2])
except ValueError as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)

if network.version != 4 or server.version != 4:
    print("Nur IPv4 wird unterstützt.", file=sys.stderr)
    raise SystemExit(1)

if network.prefixlen != 24:
    print("Diese Installerversion unterstützt bewusst nur ein /24-WireGuard-Netz.", file=sys.stderr)
    raise SystemExit(1)

if server not in network:
    print("Die Server-IP liegt nicht im angegebenen WireGuard-Netz.", file=sys.stderr)
    raise SystemExit(1)

if server == network.network_address or server == network.broadcast_address:
    print("Die Server-IP darf weder Netz- noch Broadcastadresse sein.", file=sys.stderr)
    raise SystemExit(1)
PY
}

peer_ip_for_host() {
    local network="$1"
    local host="$2"

    python3 - "$network" "$host" <<'PY'
import ipaddress
import sys

network = ipaddress.ip_network(sys.argv[1], strict=False)
host = int(sys.argv[2])
candidate = network.network_address + host

if candidate not in network or candidate == network.broadcast_address:
    raise SystemExit("Peer-Adresse liegt außerhalb des Netzes.")

print(candidate)
PY
}

prefix_from_network() {
    local network="$1"
    python3 - "$network" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_network(sys.argv[1], strict=False).prefixlen)
PY
}

wg_public_from_private() {
    local private_key="$1"
    printf '%s' "$private_key" | wg pubkey 2>/dev/null
}

validate_private_key() {
    local private_key="$1"
    [[ -n "$private_key" ]] || return 1
    wg_public_from_private "$private_key" >/dev/null 2>&1
}

read_fritz_private_key() {
    local key

    echo >&2
    echo "Diese FRITZ!Box besitzt bereits ein WireGuard-Schlüsselpaar." >&2
    echo "Bitte in FRITZ!OS öffnen:" >&2
    echo "  Internet -> Freigaben -> VPN (WireGuard)" >&2
    echo "  -> WireGuard-Einstellungen anzeigen" >&2
    echo "Dort den privaten Schlüssel der FRITZ!Box kopieren." >&2
    echo >&2

    while true; do
        read -r -s -p "Privaten Schlüssel der FRITZ!Box einfügen: " key
        echo >&2

        if validate_private_key "$key"; then
            printf '%s' "$key"
            return
        fi

        echo "Der eingegebene Schlüssel ist kein gültiger WireGuard-PrivateKey." >&2
    done
}

prepare_existing_installation() {
    if systemctl is-active --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
        WG_WAS_ACTIVE=1
    fi

    if [[ ! -f "$SERVER_CONF" ]]; then
        return
    fi

    echo
    echo "Es existiert bereits: $SERVER_CONF"
    echo
    echo "1) Abbrechen"
    echo "2) Sichern und neu erzeugen; bisherigen VPS-Schlüssel beibehalten"
    echo "3) Sichern und vollständig mit neuem VPS-Schlüssel erzeugen"
    read -r -p "Auswahl [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        2)
            PRESERVED_SERVER_PRIVATE="$(
                sed -n -E 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$/\1/p' \
                    "$SERVER_CONF" | head -n1
            )"
            validate_private_key "$PRESERVED_SERVER_PRIVATE" \
                || die "Der bisherige VPS-PrivateKey konnte nicht gelesen werden."
            ;;
        3)
            PRESERVED_SERVER_PRIVATE=""
            ;;
        *)
            die "Abgebrochen. Bestehende Konfiguration wurde nicht verändert."
            ;;
    esac

    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"

    cp -a "$SERVER_CONF" "${SERVER_CONF}.backup-${stamp}"
    echo "Serverkonfiguration gesichert:"
    echo "  ${SERVER_CONF}.backup-${stamp}"

    if [[ -d "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
        cp -a "$OUTPUT_DIR" "${OUTPUT_DIR}.backup-${stamp}"
        echo "FRITZ!Box-Dateien gesichert:"
        echo "  ${OUTPUT_DIR}.backup-${stamp}"
    fi

    if [[ "$WG_WAS_ACTIVE" -eq 1 ]]; then
        info "Vorhandenes WireGuard-Interface wird für den Neuaufbau gestoppt."
        systemctl stop "wg-quick@${WG_IF}"
    fi
}

configure_sysctl() {
    cat > /etc/sysctl.d/99-wireguard-telefonie-no-routing.conf <<'EOF'
# WireGuard-Telefonie: dieser VPS dient nicht als Router
net.ipv4.ip_forward = 0
EOF

    sysctl -q -p /etc/sysctl.d/99-wireguard-telefonie-no-routing.conf || true
}

upsert_env_value() {
    local key="$1"
    local value="$2"

    if grep -qE "^${key}=" "$KFX_ENVFILE" 2>/dev/null; then
        sed -i -E "s|^${key}=.*|${key}=${value}|" "$KFX_ENVFILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$KFX_ENVFILE"
    fi
}

persist_kienzlefax_phone_transport() {
    local wg_ip="$1"
    local wg_net="$2"
    local sip_port="$3"
    local wg_port="$4"

    if [[ ! -f "$KFX_ENVFILE" ]]; then
        echo "WARNUNG: KienzleFax-ENV fehlt; WireGuard-Bindung kann nicht dauerhaft gespeichert werden: $KFX_ENVFILE" >&2
        return
    fi

    upsert_env_value KFX_PHONE_BIND_IFACE "$WG_IF"
    upsert_env_value KFX_PHONE_BIND_IP "$wg_ip"
    upsert_env_value KFX_PHONE_LOCAL_CIDR "$wg_net"
    upsert_env_value KFX_PHONE_REMOTE_ACCESS_ENABLED "n"
    upsert_env_value KFX_PHONE_ALLOWED_CIDR "$wg_net"
    upsert_env_value KFX_PHONE_INTERNAL_PORT "$sip_port"
    upsert_env_value KFX_WIREGUARD_PHONE_ENABLED "y"
    upsert_env_value KFX_WIREGUARD_INTERFACE "$WG_IF"
    upsert_env_value KFX_WIREGUARD_NET "$wg_net"
    upsert_env_value KFX_WIREGUARD_SERVER_IP "$wg_ip"
    upsert_env_value KFX_WIREGUARD_PORT "$wg_port"
    chmod 0600 "$KFX_ENVFILE"

    echo "KienzleFax-Telefoniewerte dauerhaft gespeichert: $KFX_ENVFILE"
}

active_channel_count() {
    local out count

    command -v asterisk >/dev/null 2>&1 || die "Asterisk-Befehl nicht gefunden."
    out="$(asterisk -rx "core show channels concise" 2>/dev/null)" \
        || die "Aktive Asterisk-Kanaele konnten nicht sicher ermittelt werden."
    count="$(awk 'NF {count++} END {print count+0}' <<< "$out")"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s' "$count"
}

wait_for_asterisk_cli() {
    local timeout="${1:-90}"
    local waited=0

    while (( waited < timeout )); do
        if asterisk -rx "core show version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

wireguard_ip_is_active() {
    local wg_ip="$1"

    command -v ip >/dev/null 2>&1 || return 1
    ip -o -4 addr show dev "$WG_IF" 2>/dev/null \
        | awk -v wanted="$wg_ip" '{split($4, address, "/"); if (address[1] == wanted) found=1} END {exit(found ? 0 : 1)}'
}

asterisk_transport_listening() {
    local wg_ip="$1"
    local sip_port="$2"
    local target="${wg_ip}:${sip_port}"

    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lunp 2>/dev/null \
        | awk -v target="$target" '
            index($0, target) && index($0, "asterisk") {found=1}
            END {exit(found ? 0 : 1)}
        '
}

restart_asterisk_for_wireguard() {
    local wg_ip="$1"
    local sip_port="$2"

    info "Asterisk wird fuer die neue WireGuard-Bindung kontrolliert neu gestartet."
    systemctl restart asterisk
    wait_for_asterisk_cli 90 || die "Asterisk CLI ist nach dem Neustart nicht bereit."
    asterisk -rx "pjsip show transport transport-kfx-phone" >/dev/null 2>&1 \
        || die "Asterisk hat transport-kfx-phone nicht geladen."
    asterisk_transport_listening "$wg_ip" "$sip_port" \
        || die "Asterisk lauscht nicht auf ${wg_ip}:${sip_port}/UDP."
    systemctl --no-pager --full status asterisk || true
    asterisk -rx "pjsip show transports" || true
}

replace_asterisk_transport() {
    local file="$1"
    local wg_ip="$2"
    local wg_net="$3"
    local sip_port="$4"

    [[ -f "$file" ]] || die "Asterisk-Datei nicht gefunden: $file"

    if ! grep -q '^\[transport-kfx-phone\][[:space:]]*$' "$file"; then
        die "Abschnitt [transport-kfx-phone] wurde in $file nicht gefunden."
    fi

    local backup="${file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$file" "$backup"

    python3 - "$file" "$wg_ip" "$wg_net" "$sip_port" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
wg_ip = sys.argv[2]
wg_net = sys.argv[3]
sip_port = sys.argv[4]

text = path.read_text(encoding="utf-8")

pattern = re.compile(
    r"(?ms)^\[transport-kfx-phone\]\s*$.*?(?=^\[|\Z)"
)

replacement = (
    "[transport-kfx-phone]\n"
    "type=transport\n"
    "protocol=udp\n"
    f"bind={wg_ip}:{sip_port}\n"
    f"local_net={wg_net}\n\n"
)

new_text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit("Transportabschnitt konnte nicht eindeutig ersetzt werden.")

path.write_text(new_text, encoding="utf-8")
PY

    echo "Asterisk-Transport angepasst."
    echo "Sicherung: $backup"
}

main() {
    require_root

    echo "============================================================"
    echo " WireGuard-Telefonie-Installer v2"
    echo " FRITZ!Box <-> Debian/Asterisk"
    echo "============================================================"
    echo
    echo "Kein NAT, kein Masquerading und kein Routing über den VPS."
    echo "Provider-Transporte in pjsip.conf bleiben unverändert."

    install_wireguard
    prepare_existing_installation

    local endpoint
    local wg_port
    local wg_net
    local wg_server_ip
    local wg_prefix
    local sip_port
    local rtp_range
    local peer_count
    local active_channels
    local asterisk_transport_switched=0

    read -r -p "Öffentliche IPv4-Adresse oder DNS-Name des VPS: " endpoint
    [[ -n "$endpoint" ]] \
        || die "Eine öffentliche Adresse oder ein DNS-Name ist erforderlich."

    wg_port="$(ask_value "WireGuard-Port" "$DEFAULT_WG_PORT")"
    wg_net="$(ask_value "WireGuard-Netz" "$DEFAULT_WG_NET")"
    wg_server_ip="$(ask_value "WireGuard-IP des VPS" "$DEFAULT_WG_SERVER_IP")"
    sip_port="$(ask_value "SIP-Port für interne Telefone" "$DEFAULT_SIP_PORT")"
    rtp_range="$(ask_value "RTP-Portbereich" "$DEFAULT_RTP_RANGE")"

    [[ "$wg_port" =~ ^[0-9]+$ ]] \
        && (( wg_port >= 1 && wg_port <= 65535 )) \
        || die "Ungültiger WireGuard-Port."

    [[ "$sip_port" =~ ^[0-9]+$ ]] \
        && (( sip_port >= 1 && sip_port <= 65535 )) \
        || die "Ungültiger SIP-Port."

    validate_network "$wg_net" "$wg_server_ip" \
        || die "WireGuard-Netz oder Server-IP ist ungültig."

    wg_prefix="$(prefix_from_network "$wg_net")"

    read -r -p "Anzahl der FRITZ!Box-Gegenstellen: " peer_count
    [[ "$peer_count" =~ ^[1-9][0-9]*$ ]] \
        || die "Bitte eine Anzahl größer 0 eingeben."
    (( peer_count <= 200 )) \
        || die "Maximal 200 Gegenstellen werden unterstützt."

    mkdir -p /etc/wireguard
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    chmod 700 /etc/wireguard "$OUTPUT_DIR"

    local server_private
    local server_public

    if [[ -n "$PRESERVED_SERVER_PRIVATE" ]]; then
        server_private="$PRESERVED_SERVER_PRIVATE"
        info "Der bisherige private VPS-Schlüssel wird weiterverwendet."
    else
        server_private="$(wg genkey)"
    fi

    server_public="$(wg_public_from_private "$server_private")"

    cat > "$SERVER_CONF" <<EOF
[Interface]
Address = ${wg_server_ip}/${wg_prefix}
ListenPort = ${wg_port}
PrivateKey = ${server_private}
EOF

    declare -a peer_names=()
    declare -a peer_files=()
    declare -a peer_ips=()
    declare -a peer_key_modes=()

    local i
    local host_octet
    local peer_name
    local file_name
    local peer_ip
    local peer_private
    local peer_public
    local psk
    local peer_file
    local key_choice
    local key_mode

    for ((i = 1; i <= peer_count; i++)); do
        echo
        read -r -p "Name der Gegenstelle ${i}: " peer_name
        [[ -n "$peer_name" ]] || die "Der Name darf nicht leer sein."

        file_name="$(safe_name "$peer_name")"
        peer_file="${OUTPUT_DIR}/${file_name}.conf"

        [[ ! -e "$peer_file" ]] \
            || die "Name doppelt oder Datei bereits vorhanden: $peer_file"

        host_octet=$((DEFAULT_FIRST_PEER_HOST + i - 1))
        (( host_octet <= 254 )) \
            || die "Zu viele Gegenstellen für das /24-Netz."

        peer_ip="$(peer_ip_for_host "$wg_net" "$host_octet")"

        echo
        echo "Verwendet diese FRITZ!Box bereits WireGuard?"
        echo "1) Ja – vorhandenen FRITZ!Box-Schlüssel übernehmen"
        echo "2) Nein – neues Schlüsselpaar erzeugen"
        read -r -p "Auswahl [1]: " key_choice
        key_choice="${key_choice:-1}"

        case "$key_choice" in
            1)
                peer_private="$(read_fritz_private_key)"
                key_mode="vorhandener FRITZ!Box-Schlüssel"
                ;;
            2)
                peer_private="$(wg genkey)"
                key_mode="neu erzeugter Schlüssel"
                ;;
            *)
                die "Ungültige Auswahl."
                ;;
        esac

        peer_public="$(wg_public_from_private "$peer_private")"
        psk="$(wg genpsk)"

        cat >> "$SERVER_CONF" <<EOF

[Peer]
# ${peer_name}
PublicKey = ${peer_public}
PresharedKey = ${psk}
AllowedIPs = ${peer_ip}/32
EOF

        cat > "$peer_file" <<EOF
[Interface]
PrivateKey = ${peer_private}
Address = ${peer_ip}/32

[Peer]
PublicKey = ${server_public}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${wg_port}
AllowedIPs = ${wg_server_ip}/32
PersistentKeepalive = 25
EOF

        chmod 600 "$peer_file"

        cat > "${OUTPUT_DIR}/${file_name}.txt" <<EOF
Gegenstelle: ${peer_name}
Schlüsselmodus: ${key_mode}
WireGuard-IP der FRITZ!Box: ${peer_ip}
WireGuard-IP des VPS: ${wg_server_ip}
SIP-Registrar: ${wg_server_ip}
SIP-Port: ${sip_port}/UDP
RTP-Portbereich: ${rtp_range}/UDP
Importdatei: ${peer_file}
EOF
        chmod 600 "${OUTPUT_DIR}/${file_name}.txt"

        peer_names+=("$peer_name")
        peer_files+=("$peer_file")
        peer_ips+=("$peer_ip")
        peer_key_modes+=("$key_mode")
    done

    chmod 600 "$SERVER_CONF"

    configure_sysctl

    if ask_yes_no "WireGuard ${WG_IF} jetzt aktivieren und beim Systemstart starten?" "j"; then
        systemctl enable "wg-quick@${WG_IF}"
        systemctl restart "wg-quick@${WG_IF}"
        systemctl --no-pager --full status "wg-quick@${WG_IF}" || true
    fi

    echo
    echo "Asterisk-interner Transport:"
    echo "  Datei: $DEFAULT_ASTERISK_FILE"
    echo "  Ziel:  ${wg_server_ip}:${sip_port}"
    echo

    if ask_yes_no "Abschnitt [transport-kfx-phone] auf WireGuard umstellen?" "j"; then
        local asterisk_file
        asterisk_file="$(ask_value "Asterisk-Datei" "$DEFAULT_ASTERISK_FILE")"
        if ! wireguard_ip_is_active "$wg_server_ip"; then
            echo "WARNUNG: ${WG_IF} hat die Adresse ${wg_server_ip} nicht aktiv; Asterisk bleibt unverändert." >&2
        else
            active_channels="$(active_channel_count)"
            if (( active_channels > 0 )); then
                echo "WARNUNG: ${active_channels} aktive Asterisk-Kanaele; WireGuard-Bindung von Asterisk wird sicher uebersprungen." >&2
            else
                replace_asterisk_transport \
                    "$asterisk_file" "$wg_server_ip" "$wg_net" "$sip_port"
                persist_kienzlefax_phone_transport \
                    "$wg_server_ip" "$wg_net" "$sip_port" "$wg_port"
                restart_asterisk_for_wireguard "$wg_server_ip" "$sip_port"
                asterisk_transport_switched=1
                echo
                echo "Die Provider-Transporte in /etc/asterisk/pjsip.conf wurden nicht verändert."
            fi
        fi
    fi

    echo
    echo "============================================================"
    echo " EINRICHTUNG ABGESCHLOSSEN"
    echo "============================================================"
    echo
    echo "WireGuard-Server:"
    echo "  Interface:         ${WG_IF}"
    echo "  VPN-IP:            ${wg_server_ip}"
    echo "  Öffentlicher Port: UDP ${wg_port}"
    echo
    if [[ "$asterisk_transport_switched" -eq 1 ]]; then
        echo "Asterisk über WireGuard:"
        echo "  Registrar:         ${wg_server_ip}"
        echo "  SIP-Port:          ${sip_port}/UDP"
        echo "  RTP:               ${rtp_range}/UDP"
    else
        echo "Asterisk über WireGuard: nicht umgestellt"
    fi
    echo
    echo "WICHTIG:"
    echo "  Öffentlich muss UDP ${wg_port} zum VPS erlaubt sein."
    echo "  Auf ${WG_IF} müssen SIP ${sip_port}/UDP und RTP ${rtp_range}/UDP erlaubt sein."
    echo "  Es wurden keine Firewallregeln, kein NAT und kein Routing angelegt."

    for ((i = 0; i < peer_count; i++)); do
        echo
        echo "============================================================"
        echo " FRITZ!BOX-GEGENSTELLE: ${peer_names[$i]}"
        echo " WireGuard-IP: ${peer_ips[$i]}"
        echo " Schlüssel: ${peer_key_modes[$i]}"
        echo " Datei: ${peer_files[$i]}"
        echo "============================================================"
        echo
        cat "${peer_files[$i]}"
        echo
    done

    echo "Die .conf-Dateien können in FRITZ!OS als"
    echo "WireGuard-Konfigurationsdateien importiert werden."
}

main "$@"
