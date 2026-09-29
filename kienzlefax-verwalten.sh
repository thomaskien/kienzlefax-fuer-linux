#!/usr/bin/env bash
# IMMER verwenden wenn KienzleFax-Funktionen reversibel pausiert oder wieder freigegeben werden sollen.
# Version 0.1.1 (2026-09-29)
# Changelog:
# 0.1.1: Wiederholte Samba-[global]-Abschnitte zulassen und unveraendert erhalten.
# 0.1.0: Separater Verwaltungsassistent mit Vorschau, Einzelschaltern und Ruecknahme.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 wird benoetigt.' >&2; exit 1; }
exec python3 -c "$(cat <<'KFX_PYTHON'
import argparse
import base64
import contextlib
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

VERSION = '0.1.1'
STATE_DIR = '/var/lib/kienzlefax-verwalten'
STATE_FILE = STATE_DIR + '/state.json'
PENDING = STATE_DIR + '/pending.json'
LAST = STATE_DIR + '/last.json'
SMB = '/etc/samba/smb.conf'
EXT = '/etc/asterisk/extensions.conf'
PJSIP = '/etc/asterisk/pjsip.conf'
PHONE_EXT = '/etc/asterisk/extensions-kfx-telefonie.conf'
PHONE_PJSIP = '/etc/asterisk/pjsip-kfx-telefonie.conf'
WEB = '/etc/apache2/conf-enabled/zz-kienzlefax-verwalten.conf'
SERVICES = {'fax_send': 'kienzlefax-worker.service',
            'scan_ocr': 'scan-ocr.service', 'fax_ocr': 'scan-ocr-fax.service'}
LABELS = {'fax_send': 'Faxversand (Worker)', 'fax_receive': 'Faxempfang',
          'phone': 'Telefonie und Warteschlange', 'web': 'KienzleFax-Webinterface',
          'scan_ocr': 'Scanner-OCR-Verarbeitung', 'fax_ocr': 'Fax-OCR-Verarbeitung'}
SHARES = re.compile(r'(?:hierhin-scannen-fuer-ocr|scan-eingang|fax-eingang|sendeberichte|'
                    r'sendefehler-eingang|sendefehler-berichte|pdf-zu-fax[0-9]*)\Z', re.I)
PHONE_CONTEXTS = {'kfx-phone-in', 'kfx-phone-overflow-provider', 'kfx-phone-overflow-in',
                  'kfx-phone-queue', 'kfx-phone-local'}
SAFE_NAME = re.compile(r'[A-Za-z0-9_.-]+\Z')


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def label(key):
    if key.startswith('share:'):
        return 'Netzwerkfreigabe ' + key.split(':', 1)[1]
    if key.startswith('printer:'):
        return 'Faxdrucker ' + key.split(':', 1)[1]
    return LABELS.get(key, key)


def encode(data):
    return base64.b64encode(data).decode('ascii')


def decode(value):
    return base64.b64decode(value, validate=True)


def new_state():
    return {'schema': 1, 'version': VERSION, 'disabled': [], 'files': {},
            'services': {}, 'printers': {}, 'revision': None}


def text_snapshot(text, previous=None, mode=0o644):
    result = dict(previous) if previous else {'mode': mode, 'uid': 0, 'gid': 0}
    result['data'] = encode(text.encode('utf-8'))
    return result


def snapshot_text(snapshot):
    require(snapshot is not None, 'Erforderliche Konfigurationsdatei fehlt.')
    try:
        return decode(snapshot['data']).decode('utf-8')
    except (ValueError, UnicodeError) as exc:
        raise Error('Konfiguration ist nicht als UTF-8 lesbar.') from exc


def sections(text, asterisk=False):
    """Keep every byte outside the selected section, including include directives."""
    lines = text.splitlines(keepends=True)
    found = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith('['):
            continue
        match = re.fullmatch(r'\[([^\]]+)\]\s*(?:[;#].*)?', stripped)
        require(match is not None, 'Komplexe/individuelle INI-Sektion: automatische Aenderung verweigert.')
        name = match.group(1).strip()
        require(not asterisk or SAFE_NAME.fullmatch(name) is not None,
                'Ungewoehnlicher Asterisk-Sektionsname: bitte manuell pruefen.')
        found.append((name, index))
    result = []
    for i, (name, start) in enumerate(found):
        end = found[i + 1][1] if i + 1 < len(found) else len(lines)
        result.append((name, start, end))
    if not asterisk:
        # Samba can re-enter [global], e.g. for another application's settings.
        # Preserve every block; only repeated share definitions remain ambiguous.
        names = [name.lower() for name, _, _ in result if name.lower() != 'global']
        require(len(names) == len(set(names)), 'Doppelte Samba-Freigaben: bitte zuerst bereinigen.')
    return lines, result


def validate_includes(text, allowed=()):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith('#'):
            require(s in allowed, 'Unbekannte Asterisk-Include-/Exec-Anweisung: automatische Aenderung verweigert.')


def samba_render(text, disabled):
    # Registry/includes/copy can override options; decline rather than claim a false block.
    require(not re.search(r'^\s*(include|copy|config backend|registry shares)\s*=', text, re.M | re.I),
            'Samba nutzt include/copy/Registry-Konfiguration; diese Form wird nicht automatisch veraendert.')
    require(not any(line.rstrip().endswith('\\') for line in text.splitlines()
                    if line.strip() and not line.lstrip().startswith(('#', ';'))),
            'Samba nutzt Zeilenfortsetzungen; bitte die Konfiguration zuerst pruefen.')
    lines, parts = sections(text)
    selected = {key.split(':', 1)[1].lower() for key in disabled if key.startswith('share:')}
    for name, start, end in reversed(parts):
        if name.lower() not in selected:
            continue
        kept = [line for line in lines[start + 1:end]
                if not re.match(r'^\s*available\s*=', line, re.I)]
        lines[start:end] = [lines[start], '   available = no\n'] + kept
    require(selected <= {name.lower() for name, _, _ in parts}, 'Eine ausgewaehlte Freigabe fehlt.')
    return ''.join(lines)


def block_entries(text, contexts):
    """Replace only priority 1: channels already past entry keep all subsequent priorities."""
    lines, parts = sections(text, asterisk=True)
    names = [name for name, _, _ in parts]
    require(len(names) == len(set(names)), 'Doppelte Dialplan-Kontexte: bitte manuell pruefen.')
    require(contexts <= set(names), 'Erwarteter KienzleFax-Dialplan-Kontext fehlt.')
    for name, start, end in parts:
        if name not in contexts:
            continue
        changed = 0
        for index in range(start + 1, end):
            s = lines[index].strip()
            if s.startswith(('include', 'switch', 'eswitch', 'lswitch', '#')):
                raise Error('Individueller Dialplan im betroffenen Kontext: automatische Sperre verweigert.')
            match = re.match(r'^(\s*exten\s*=>\s*([^,]+),\s*1(?:\([^)]*\))?\s*,).*(\n?)$', lines[index])
            if match and match.group(2).strip() != 'h':
                lines[index] = match.group(1) + 'Hangup(17) ; KienzleFax Verwaltung\n'
                changed += 1
        require(changed > 0, 'Dialplan besitzt keine eindeutig sperrbaren Einstiegspunkte.')
    return ''.join(lines)


def pjsip_render(text, phone=False):
    marker = '; generated by kienzlefax telefonie-queue.sh' if phone else '; generated by kienzlefax provider template:'
    require(marker in text, 'Manuelle/aeltere PJSIP-Konfiguration: SIP-Abschaltung wird nicht geraten.')
    allowed = ('#tryinclude "/etc/asterisk/pjsip-kfx-telefonie.conf"',) if not phone else ()
    validate_includes(text, allowed)
    lines, parts = sections(text, asterisk=True)
    registrations = []
    endpoints = []
    for name, start, end in reversed(parts):
        body = ''.join(lines[start:end])
        types = re.findall(r'^\s*type\s*=\s*([a-z_]+)\s*$', body, re.M | re.I)
        require(len(types) == 1, 'PJSIP-Sektion ohne eindeutigen Typ: automatische Aenderung verweigert.')
        kind = types[0].lower()
        if kind == 'registration':
            registrations.append(name)
        if kind == 'endpoint':
            endpoints.append(name)
        remove = kind != 'transport' if phone else kind == 'registration'
        if remove:
            directives = [line for line in lines[start:end] if line.lstrip().startswith('#')]
            lines[start:end] = ['; KienzleFax Verwaltung: Sektion pausiert\n'] + directives
    require(registrations, 'Keine bekannte SIP-Registrierung gefunden; bitte Provider-Konfiguration pruefen.')
    if not phone:
        require(len(registrations) == 1, 'Mehrere Registrierungen in pjsip.conf: automatische Zuordnung unsicher.')
    return ''.join(lines), registrations, endpoints


def pjsip_objects(snapshot, kind):
    if snapshot is None:
        return set()
    lines, parts = sections(snapshot_text(snapshot), asterisk=True)
    return {name for name, start, end in parts
            if re.search(r'^\s*type\s*=\s*' + kind + r'\s*$', ''.join(lines[start:end]), re.M)}


def web_block():
    return '''# KienzleFax Verwaltung: nur KienzleFax sperren, Apache weiterbetreiben.
<Directory "/var/www/html">
    <Files "kienzlefax.php">
        Require all denied
    </Files>
</Directory>
<LocationMatch "^/kienzlefax[.]php(?:/|$)">
    Require all denied
</LocationMatch>
'''


def dropin(unit):
    return '/etc/systemd/system/' + unit + '.d/90-kienzlefax-verwalten.conf'


def service_block(unit):
    return '# KienzleFax Verwaltung: persistent pausiert\n[Unit]\nConditionPathExists=!' + dropin(unit) + '\n'


class Host:
    """Only this class touches the host. Tests replace it; there is no production --root mode."""
    def path(self, path):
        return Path(path)

    def run(self, *args, check=True, timeout=30):
        env = dict(os.environ, LC_ALL='C', LANG='C')
        # Do not let root commands use a caller's PATH, CUPS server or Python path.
        env['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
        for key in ('CUPS_SERVER', 'CUPS_USER', 'LPDEST', 'PRINTER', 'PYTHONPATH', 'PYTHONHOME'):
            env.pop(key, None)
        try:
            result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    env=env, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Error('Systemwerkzeug nicht verfuegbar/Timeout: ' + args[0]) from exc
        if check and result.returncode:
            # Outputs can contain SIP credentials or document names. Never echo them.
            raise Error('Systempruefung fehlgeschlagen: ' + args[0] + ' (Details lokal pruefen).')
        return result.stdout, result.returncode

    def snapshot(self, path):
        target = self.path(path)
        if not target.exists() and not target.is_symlink():
            return None
        info = target.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                'Keine regulaere, eigenstaendige Konfigurationsdatei: ' + path)
        require(info.st_size < 8 * 1024 * 1024, 'Konfigurationsdatei unerwartet gross: ' + path)
        return {'data': encode(target.read_bytes()), 'mode': stat.S_IMODE(info.st_mode),
                'uid': info.st_uid, 'gid': info.st_gid}

    def write(self, path, snapshot):
        target = self.path(path)
        # Reject symlink ancestors instead of following a redirected backup/config path.
        for ancestor in (target, *target.parents):
            require(not ancestor.is_symlink(), 'Symlink im Schreibpfad: ' + path)
        if snapshot is None:
            if target.exists():
                require(target.is_file(), 'Unerwarteter Dateityp: ' + path)
                target.unlink()
            return
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        fd, temporary = tempfile.mkstemp(prefix='.kfx-verwalten-', dir=target.parent)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(decode(snapshot['data']))
                handle.flush()
                os.fchown(handle.fileno(), snapshot['uid'], snapshot['gid'])
                os.fchmod(handle.fileno(), snapshot['mode'])
                os.fsync(handle.fileno())
            os.replace(temporary, target)
            directory = os.open(target.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def service(self, unit):
        out, rc = self.run('systemctl', 'show', unit, '--no-pager',
                           '--property=LoadState,ActiveState,SubState,UnitFileState,FreezerState', check=False)
        values = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
        require('LoadState' in values, 'systemd-Dienststatus konnte nicht gelesen werden.')
        if values['LoadState'] == 'not-found':
            return None
        require(rc == 0, 'systemd-Dienststatus konnte nicht gelesen werden: ' + unit)
        require(values['LoadState'] in ('loaded', 'masked'), 'systemd-Dienst ist nicht korrekt geladen: ' + unit)
        require(values.get('ActiveState') in ('active', 'inactive', 'failed'),
                'Dienst befindet sich im Uebergang: ' + unit)
        require(values.get('UnitFileState'), 'Autostartstatus nicht ermittelbar: ' + unit)
        return {'active': values['ActiveState'] == 'active', 'enabled': values['UnitFileState'],
                'frozen': values.get('FreezerState', 'running') not in ('running', '')}

    def ast(self, command):
        out, _ = self.run('asterisk', '-rx', command)
        require(not re.search(r'No such command|Unable to connect|No such module|Error|Failed', out, re.I),
                'Asterisk-CLI-Pruefung fehlgeschlagen (keine Konfigurationsdetails im Log).')
        return out

    def idle_calls(self):
        svc = self.service('asterisk.service')
        if svc and svc['active']:
            out = self.ast('core show channels count')
            match = re.search(r'^\s*(\d+) active channels\s*$', out, re.M)
            require(match is not None, 'Aktive Asterisk-Kanaele nicht sicher ermittelbar.')
            require(int(match.group(1)) == 0, 'Telefonat oder Fax aktiv. Bitte spaeter erneut starten.')

    def printer(self, name):
        require(SAFE_NAME.fullmatch(name), 'Ungueltiger Druckername.')
        status, _ = self.run('lpstat', '-p', name)
        accepting, _ = self.run('lpstat', '-a', name)
        match = re.search(r'^printer ' + re.escape(name) + r' (?:is (idle|printing)|(?:is )?(disabled))\b', status, re.M)
        require(match is not None, 'Druckerstatus nicht ermittelbar: ' + name)
        require(re.search(r'^' + re.escape(name) + r' (?:not )?accepting requests\b', accepting, re.M),
                'Drucker-Annahmestatus nicht ermittelbar: ' + name)
        return {'enabled': match.group(2) is None, 'accepting': ' not accepting requests' not in accepting}

    def printers(self):
        if not self.path('/etc/cups/printers.conf').exists():
            return []
        out = snapshot_text(self.snapshot('/etc/cups/printers.conf'))
        names = []
        for name, body in re.findall(r'<(?:Default)?Printer ([A-Za-z0-9_.-]+)>\s*\n(.*?)</(?:Default)?Printer>', out, re.S):
            if re.search(r'^DeviceURI kienzlefaxpdf:/[^\s]+\s*$', body, re.M):
                names.append(name)
        return sorted(names)

    def printer_set(self, name, flags):
        # Reject first, then stop. Never use -c (which would delete jobs).
        self.run('cupsaccept' if flags['accepting'] else 'cupsreject', name)
        self.run('cupsenable' if flags['enabled'] else 'cupsdisable', name)
        require(self.printer(name) == flags, 'Druckerzustand wurde nicht uebernommen: ' + name)

    def idle_printer(self, name):
        out, _ = self.run('lpstat', '-W', 'not-completed', '-o', name)
        require(not out.strip(), 'Druckauftraege vorhanden: ' + name + '. Bitte erst verarbeiten oder manuell zurueckstellen.')

    def idle_share(self, name):
        svc = self.service('smbd.service')
        if not svc or not svc['active']:
            return
        out, _ = self.run('smbstatus', '-S')
        require('Service' in out and 'pid' in out.lower(), 'Samba-Verbindungen nicht sicher ermittelbar.')
        require(not any(line.split() and line.split()[0].lower() == name.lower() for line in out.splitlines()),
                'Noch eine Verbindung zur Freigabe ' + name + ' offen. Bitte am Client trennen.')

    def idle_processing(self, key):
        directories = {'fax_send': ('/srv/kienzlefax/processing',),
                       'scan_ocr': ('/srv/scan/eingang', '/var/tmp/scan-ocr'),
                       'fax_ocr': ('/srv/scan/fax-eingang', '/var/tmp/scan-ocr-fax')}
        for directory in directories[key]:
            path = self.path(directory)
            require(not path.is_dir() or not any(path.iterdir()),
                    label(key) + ': Eingang/Arbeitsverzeichnis nicht leer. Verarbeitung erst abschliessen lassen.')

    def can_freeze(self, unit):
        current = self.service(unit)
        if current and current['active']:
            require(self.path('/sys/fs/cgroup/cgroup.controllers').exists(),
                    'Sicheres Pausieren benoetigt systemd mit cgroup v2. Dienst vorher kontrolliert anhalten: ' + unit)

    def freeze(self, unit):
        svc = self.service(unit)
        require(svc and not svc['frozen'], 'Dienst fehlt oder ist bereits eingefroren: ' + unit)
        if svc['active']:
            try:
                self.run('systemctl', 'freeze', unit)
                require(self.service(unit)['frozen'], 'Dienst konnte nicht sicher angehalten werden: ' + unit)
            except BaseException:
                self.thaw(unit)
                raise
            return True
        return False

    def thaw(self, unit):
        svc = self.service(unit)
        if svc and svc['active'] and svc['frozen']:
            self.run('systemctl', 'thaw', unit)

    def service_active(self, unit, active):
        if not active:
            current = self.service(unit)
            if current and current['active'] and current['frozen']:
                # Queue SIGTERM while frozen, before systemd thaws the unit for StopUnit.
                # This prevents an idle worker from claiming another job on thaw.
                self.run('systemctl', 'kill', '--signal=SIGTERM', '--kill-who=all', unit)
        self.run('systemctl', 'start' if active else 'stop', unit)
        current = self.service(unit)
        require(current is not None and current['active'] == active, 'Dienstzustand nicht erreicht: ' + unit)

    def queue_count(self):
        return sum(sum(1 for _ in self.path(path).iterdir()) if self.path(path).is_dir() else 0
                   for path in ('/srv/kienzlefax/queue', '/srv/kienzlefax/processing', '/srv/kienzlefax/staging'))

    def validate_samba(self, text):
        with tempfile.TemporaryDirectory(prefix='kfx-verwalten-check-') as directory:
            path = Path(directory) / 'smb.conf'
            path.write_text(text, encoding='utf-8')
            path.chmod(0o600)
            self.run('testparm', '-s', str(path))

    def reload(self, paths, disabled, verify=True):
        paths = set(paths)
        if any(path.startswith('/etc/systemd/system/') for path in paths):
            self.run('systemctl', 'daemon-reload')
        if WEB in paths:
            self.run('apache2ctl', 'configtest')
            svc = self.service('apache2.service')
            if svc and svc['active']:
                self.run('systemctl', 'reload', 'apache2.service')
                if verify and 'web' in disabled:
                    for url in ('http://127.0.0.1/kienzlefax.php?ajax=status',
                                'https://127.0.0.1/kienzlefax.php/verwaltung-test'):
                        code, rc = self.run('curl', '--noproxy', '*', '-k', '-s', '-L',
                                            '--max-time', '10', '-o', '/dev/null', '-w', '%{http_code}', url, check=False)
                        require(rc == 0 and code == '403',
                                'Websperre auf HTTP/HTTPS nicht bestaetigt. Eigene VirtualHosts bitte manuell pruefen.')
        if SMB in paths:
            self.run('testparm', '-s')
            svc = self.service('smbd.service')
            if svc and svc['active']:
                self.run('smbcontrol', 'all', 'reload-config')
                for key in disabled:
                    if key.startswith('share:'):
                        name = key.split(':', 1)[1]
                        self.run('smbcontrol', 'smbd', 'close-share', name)
                        value, _ = self.run('testparm', '-s', '--section-name=' + name, '--parameter-name=available')
                        require(value.strip().lower() in ('no', 'false', '0'), 'Samba-Sperre nicht geladen: ' + name)
                        # An authentication failure alone does not prove that the share is unavailable.
                        result, rc = self.run('smbclient', '//127.0.0.1/' + name, '-N', '-U', '%',
                                              '-t', '5', '-c', 'quit', check=False)
                        require(rc != 0 and 'NT_STATUS_BAD_NETWORK_NAME' in result,
                                'Samba-Sperre im lokalen Zugriff nicht bestaetigt: ' + name)
        if paths & {EXT, PHONE_EXT, PJSIP, PHONE_PJSIP}:
            svc = self.service('asterisk.service')
            if svc and svc['active']:
                if paths & {EXT, PHONE_EXT}:
                    self.ast('dialplan reload')
                if paths & {PJSIP, PHONE_PJSIP}:
                    self.ast('pjsip reload')


class Manager:
    def __init__(self, host):
        self.host = host
        self.state = self.load(STATE_FILE) or new_state()
        require(self.state.get('schema') == 1, 'Unbekanntes Zustandsformat. Keine Aenderung.')

    def load(self, path):
        snap = self.host.snapshot(path)
        if snap is None:
            return None
        require(snap['uid'] == 0 and not snap['mode'] & 0o077, 'Zustandsdatei muss root gehoeren und 0600 haben: ' + path)
        try:
            return json.loads(snapshot_text(snap))
        except (ValueError, TypeError) as exc:
            raise Error('Zustandsdatei unlesbar: ' + path + '. Geschuetzte Sicherungen bitte pruefen.') from exc

    def save(self, path, value):
        self.host.write(path, text_snapshot(json.dumps(value, indent=2, sort_keys=True) + '\n', mode=0o600))

    def base(self, path):
        saved = self.state['files'].get(path)
        return saved['original'] if saved else self.host.snapshot(path)

    def base_text(self, path):
        return snapshot_text(self.base(path))

    def inventory(self):
        keys = []
        for key, unit in SERVICES.items():
            if self.host.service(unit):
                keys.append(key)
        ext = self.base(EXT)
        if ext and '[fax-in]' in snapshot_text(ext):
            keys.append('fax_receive')
        if self.base(PHONE_PJSIP) and 'type=endpoint' in self.base_text(PHONE_PJSIP):
            keys.append('phone')
        if self.host.path('/var/www/html/kienzlefax.php').is_file():
            keys.append('web')
        smb = self.base(SMB)
        if smb:
            _, parts = sections(snapshot_text(smb))
            keys.extend('share:' + name.lower() for name, _, _ in parts if SHARES.fullmatch(name))
        keys.extend('printer:' + name for name in self.host.printers())
        keys.extend(key for key in self.state['disabled'] if key not in keys)
        order = ['fax_send', 'fax_receive', 'phone', 'web', 'scan_ocr', 'fax_ocr']
        return sorted(keys, key=lambda key: (order.index(key) if key in order else len(order), key))

    def drift(self):
        problems = []
        for path, saved in self.state['files'].items():
            if self.host.snapshot(path) != saved['applied']:
                problems.append('Konfiguration extern geaendert: ' + path)
        for key, original in self.state['services'].items():
            current = self.host.service(SERVICES[key])
            if not current or current['enabled'] != original['enabled'] or current['active'] or current['frozen']:
                problems.append('Pausierter Dienst extern geaendert/gestartet: ' + SERVICES[key])
        for name in self.state['printers']:
            if self.host.printer(name) != {'accepting': False, 'enabled': False}:
                problems.append('Pausierter Drucker extern geaendert: ' + name)
        return problems

    def assert_clean(self):
        require(self.load(PENDING) is None, 'Unvollstaendige Transaktion vorhanden. Zuerst --restore ausfuehren.')
        problems = self.drift()
        require(not problems, '\n'.join(problems) + '\nKeine Aenderung. Sicherungen: ' + STATE_DIR + '/history')

    def plan(self, desired):
        self.assert_clean()
        desired = set(desired)
        previous = set(self.state['disabled'])
        known = set(self.inventory())
        require(desired <= known, 'Unbekannte oder fehlende Komponente ausgewaehlt.')
        changed = desired ^ previous
        if not changed:
            return None
        require(not ('fax_ocr' in desired and 'fax_receive' in known and 'fax_receive' not in desired),
                'Fax-OCR darf bei aktivem Faxempfang nicht pausiert werden. Faxempfang ebenfalls deaktivieren.')
        if 'fax_receive' in previous - desired and 'fax_ocr' in known:
            svc = self.host.service(SERVICES['fax_ocr'])
            will_run = (self.state['services'].get('fax_ocr', {}).get('active')
                        if 'fax_ocr' in previous else svc and svc['active'])
            require(will_run and 'fax_ocr' not in desired,
                    'Vor Faxempfang muss Fax-OCR laufen; sonst bleiben empfangene PDFs im Roh-Eingang.')
        after = copy.deepcopy(self.state)
        after['disabled'] = sorted(desired)
        after['files'] = {}
        files = {}
        registration_off = []
        endpoints_off = []

        def render(path, text, mode=0o644):
            original = self.base(path)
            applied = text_snapshot(text, original, mode)
            after['files'][path] = {'original': original, 'applied': applied}
            files[path] = applied

        if any(key.startswith('share:') for key in desired):
            render(SMB, samba_render(self.base_text(SMB), desired))
        if 'web' in desired:
            require(self.base(WEB) is None, 'Eigene Apache-Sperrdatei existiert bereits ohne passende Sicherung.')
            render(WEB, web_block())
        if 'fax_receive' in desired:
            text = self.base_text(EXT)
            validate_includes(text, ('#tryinclude "/etc/asterisk/extensions-kfx-telefonie.conf"',))
            require('ReceiveFAX(' in text, 'Kein bekannter ReceiveFAX-Dialplan vorhanden.')
            render(EXT, block_entries(text, {'fax-in'}))
        if {'fax_send', 'fax_receive'} <= desired:
            text, registrations, _ = pjsip_render(self.base_text(PJSIP))
            render(PJSIP, text)
            if not {'fax_send', 'fax_receive'} <= previous:
                registration_off.extend(registrations)
        if 'phone' in desired:
            text, registrations, endpoints = pjsip_render(self.base_text(PHONE_PJSIP), phone=True)
            render(PHONE_PJSIP, text)
            ext = self.base_text(PHONE_EXT)
            validate_includes(ext)
            present = {name for name, _, _ in sections(ext, asterisk=True)[1]}
            require({'kfx-phone-in', 'kfx-phone-local'} <= present, 'Unbekannter Telefonie-Dialplan.')
            render(PHONE_EXT, block_entries(ext, PHONE_CONTEXTS & present))
            if 'phone' not in previous:
                registration_off.extend(registrations)
                endpoints_off.extend(endpoints)
        for key, unit in SERVICES.items():
            if key in desired:
                require(self.base(dropin(unit)) is None, 'Eigener systemd-Drop-in existiert ohne passende Sicherung.')
                render(dropin(unit), service_block(unit))
                if key not in previous:
                    current = self.host.service(unit)
                    require(current and not current['frozen'], 'Dienst fehlt oder ist eingefroren: ' + unit)
                    after['services'][key] = current
            else:
                after['services'].pop(key, None)
        for key in changed:
            if key.startswith('printer:'):
                name = key.split(':', 1)[1]
                if key in desired:
                    after['printers'][name] = self.host.printer(name)
                else:
                    after['printers'].pop(name, None)
        # Releasing one feature re-renders shared files with the remaining switches.
        for path, saved in self.state['files'].items():
            if path not in files:
                files[path] = saved['original']
        files = {path: value for path, value in files.items() if self.host.snapshot(path) != value}
        printers = {}
        services = {}
        for key in changed:
            if key in SERVICES:
                services[key] = False if key in desired else self.state['services'][key]['active']
            elif key.startswith('printer:'):
                name = key.split(':', 1)[1]
                printers[name] = ({'accepting': False, 'enabled': False} if key in desired
                                  else self.state['printers'][name])
        plan = {'before_state': copy.deepcopy(self.state), 'after_state': after,
                'before_files': {path: self.host.snapshot(path) for path in files}, 'after_files': files,
                'before_services': {key: self.host.service(SERVICES[key]) for key in services},
                'after_services': services,
                'before_printers': {name: self.host.printer(name) for name in printers},
                'after_printers': printers, 'changed': sorted(changed),
                'registration_off': registration_off, 'endpoints_off': endpoints_off,
                'id': time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8], 'status': 'prepared'}
        after['revision'] = plan['id']
        self.preflight(plan)
        return plan

    def preflight(self, plan):
        changed = set(plan['changed'])
        if changed & {'fax_send', 'fax_receive', 'fax_ocr', 'phone'}:
            self.host.idle_calls()
        for key in changed & SERVICES.keys():
            if plan['before_services'][key]['active']:
                self.host.idle_processing(key)
            if not plan['after_services'][key] and plan['before_services'][key]['active']:
                self.host.can_freeze(SERVICES[key])
        for name in plan['after_printers']:
            self.host.idle_printer(name)
        for key in changed:
            if key.startswith('share:'):
                self.host.idle_share(key.split(':', 1)[1])
        if SMB in plan['after_files']:
            self.host.validate_samba(snapshot_text(plan['after_files'][SMB]))
        if WEB in plan['after_files']:
            self.host.run('apache2ctl', 'configtest')

    def verify_asterisk(self, plan):
        paths = set(plan['after_files'])
        if not paths & {EXT, PHONE_EXT, PJSIP, PHONE_PJSIP}:
            return
        svc = self.host.service('asterisk.service')
        if not svc or not svc['active']:
            return
        disabled = set(plan['after_state']['disabled'])
        blocked_contexts = ({'fax-in'} if 'fax_receive' in disabled else set())
        if 'phone' in disabled:
            blocked_contexts |= PHONE_CONTEXTS
        for path in paths & {EXT, PHONE_EXT}:
            text = snapshot_text(plan['after_files'][path])
            lines, parts = sections(text, asterisk=True)
            for context, start, end in parts:
                if context not in ({'fax-in'} if path == EXT else PHONE_CONTEXTS):
                    continue
                out = self.host.ast('dialplan show ' + context)
                entries = re.findall(r'^\s*exten\s*=>\s*([^,]+),\s*1(?:\([^)]*\))?\s*,\s*([A-Za-z_]+)\(',
                                     ''.join(lines[start:end]), re.M)
                require(entries, 'Keine Dialplaneinstiege gefunden: ' + context)
                for extension, application in entries:
                    arguments = r'\('
                    if context in blocked_contexts and extension.strip() != 'h':
                        require(application == 'Hangup', 'Dialplan-Sperre ist unvollstaendig: ' + context)
                        arguments = r'\(17\)'
                    pattern = r"'" + re.escape(extension.strip()) + r"'\s*=>\s*1\.\s*" + application + arguments
                    require(re.search(pattern, out, re.I), 'Dialplan-Einstieg nicht wie vorgesehen geladen: ' + context)
        for path in paths & {PJSIP, PHONE_PJSIP}:
            wanted = pjsip_objects(plan['after_files'][path], 'registration')
            removed = pjsip_objects(plan['before_files'][path], 'registration') - wanted
            for attempt in range(15):
                out = self.host.ast('pjsip show registrations')
                active = {line.strip().split('/', 1)[0] for line in out.splitlines()
                          if '/' in line and not re.search(r'\b(Unregistered|Stopped)\b', line)}
                present = {line.strip().split('/', 1)[0] for line in out.splitlines()
                           if '/' in line and not re.search(r'\bStopped\b', line)}
                if wanted <= present and not removed & active:
                    break
                time.sleep(1)
            else:
                raise Error('SIP-Registrierung nach Reload nicht im vorgesehenen Zustand.')
            if path == PHONE_PJSIP:
                out = self.host.ast('pjsip show endpoints')
                present = set(re.findall(r'^\s*Endpoint:\s+([^/\s]+)', out, re.M))
                wanted = pjsip_objects(plan['after_files'][path], 'endpoint')
                removed = pjsip_objects(plan['before_files'][path], 'endpoint') - wanted
                require(wanted <= present and not removed & present, 'Telefonie-Endpunkte nach Reload nicht im vorgesehenen Zustand.')

    def apply(self, plan):
        self.assert_clean()
        require(self.state == plan['before_state'], 'Zustand seit Vorschau geaendert.')
        self.check_files(plan['before_files'])
        for key, original in plan['before_services'].items():
            require(self.host.service(SERVICES[key]) == original, 'Dienstzustand seit Vorschau geaendert: ' + SERVICES[key])
        for name, original in plan['before_printers'].items():
            require(self.host.printer(name) == original, 'Druckerzustand seit Vorschau geaendert: ' + name)
        self.preflight(plan)
        self.save(PENDING, plan)
        frozen = []
        try:
            # Freeze known workers to close the check/stop race. A busy worker is thawed unchanged.
            for key, active in plan['after_services'].items():
                if not active and self.host.freeze(SERVICES[key]):
                    frozen.append(SERVICES[key])
                    self.host.idle_processing(key)
            for path, value in plan['after_files'].items():
                self.host.write(path, value)
            if plan['after_services'].get('fax_ocr'):
                self.host.run('systemctl', 'daemon-reload')
                self.host.service_active(SERVICES['fax_ocr'], True)
            if plan['registration_off']:
                svc = self.host.service('asterisk.service')
                if svc and svc['active']:
                    for name in plan['registration_off']:
                        self.host.ast('pjsip send unregister ' + name)
            self.host.reload(plan['after_files'], plan['after_state']['disabled'])
            self.verify_asterisk(plan)
            # Entry gates are now in place. Check again before stopping processing.
            if (set(plan['changed']) & {'fax_send', 'fax_receive', 'fax_ocr', 'phone'} and
                    any(not active for active in plan['after_services'].values())):
                self.host.idle_calls()
            for key, active in plan['after_services'].items():
                self.host.service_active(SERVICES[key], active)
            for name, flags in plan['after_printers'].items():
                # Reject first to prevent new jobs during the final idle check.
                self.host.run('cupsreject', name)
                self.host.idle_printer(name)
                self.host.printer_set(name, flags)
            self.save(STATE_FILE, plan['after_state'])
            plan['status'] = 'applied'
            self.save(STATE_DIR + '/history/' + plan['id'] + '.json', plan)
            self.save(LAST, plan)
            self.host.write(PENDING, None)
            self.state = plan['after_state']
        except BaseException as exc:
            try:
                self.rollback(plan, pending=True)
            except BaseException:
                raise Error('Aenderung fehlgeschlagen; Ruecknahme unvollstaendig. '
                            'Nicht neu installieren. Erneut --restore ausfuehren; Sicherung: ' + PENDING) from exc
            raise Error('Aenderung abgebrochen und vorheriger Zustand wiederhergestellt: ' + str(exc)) from exc
        finally:
            for unit in frozen:
                self.host.thaw(unit)

    def check_files(self, expected, alternatives=None):
        for path, value in expected.items():
            current = self.host.snapshot(path)
            require(current == value or (alternatives is not None and current == alternatives[path]),
                    'Datei seit Vorschau/Transaktion extern geaendert: ' + path + '. Keine Ueberschreibung.')

    def rollback(self, transaction, pending=False):
        frozen = []
        try:
            self.check_files(transaction['after_files'], transaction['before_files'] if pending else None)
            self._rollback(transaction, pending, frozen)
        finally:
            # A crash can leave a previously running processor frozen. Never strand it
            # when recovery must wait for an active call or external correction.
            for key, original in transaction['before_services'].items():
                unit = SERVICES[key]
                if unit in frozen or (pending and original['active']):
                    self.host.thaw(unit)

    def _rollback(self, transaction, pending, frozen):
        # Runtime safety is required for manual recovery too, including a crash after start.
        if set(transaction['changed']) & {'fax_send', 'fax_receive', 'fax_ocr', 'phone'}:
            self.host.idle_calls()
        for name in transaction['before_printers']:
            self.host.idle_printer(name)
        for key in transaction['changed']:
            if key.startswith('share:'):
                self.host.idle_share(key.split(':', 1)[1])
        for key, original in transaction['before_services'].items():
            current = self.host.service(SERVICES[key])
            require(current and current['enabled'] == original['enabled'],
                    'Autostartstatus extern veraendert: ' + SERVICES[key])
            if current['active'] and not original['active']:
                self.host.idle_processing(key)
                self.host.can_freeze(SERVICES[key])
        # Journal the restore too, so power loss during restore can be recovered.
        recovering = copy.deepcopy(transaction)
        recovering['status'] = 'restoring'
        self.save(PENDING, recovering)
        for key, original in transaction['before_services'].items():
            unit = SERVICES[key]
            if not original['active'] and self.host.freeze(unit):
                frozen.append(unit)
                self.host.idle_processing(key)
        for path, value in transaction['before_files'].items():
            self.host.write(path, value)
        if transaction['before_services'].get('fax_ocr', {}).get('active'):
            self.host.run('systemctl', 'daemon-reload')
            self.host.service_active(SERVICES['fax_ocr'], True)
        self.host.reload(transaction['before_files'], transaction['before_state']['disabled'])
        self.verify_asterisk({'after_files': transaction['before_files'],
                              'before_files': transaction['after_files'],
                              'after_state': transaction['before_state']})
        for key, original in transaction['before_services'].items():
            if original['active']:
                self.host.thaw(SERVICES[key])
            self.host.service_active(SERVICES[key], original['active'])
        for name, flags in transaction['before_printers'].items():
            self.host.run('cupsreject', name)
            self.host.idle_printer(name)
            self.host.printer_set(name, flags)
        self.save(STATE_FILE, transaction['before_state'])
        transaction = copy.deepcopy(transaction)
        transaction['status'] = 'restored'
        self.save(STATE_DIR + '/history/' + transaction['id'] + '.json', transaction)
        self.save(LAST, transaction)
        self.host.write(PENDING, None)
        self.state = transaction['before_state']


def answer(prompt, allowed, default):
    try:
        while True:
            value = input(prompt).strip().lower()
            if not value:
                return default
            if value in allowed:
                return value
            print('Bitte eine der angezeigten Antworten eingeben.')
    except EOFError as exc:
        raise Error('Eingabe beendet. Keine neue Aenderung bestaetigt.') from exc


def confirm_queue(host):
    count = host.queue_count()
    if count:
        print(str(count) + ' Eintraege in Fax-Warteschlange/Verarbeitung/Staging. Beim Start kann Versand erfolgen.')
        require(answer('Versand dieser wartenden Auftraege ausdruecklich zulassen? [ja/NEIN] ',
                       {'ja', 'nein'}, 'nein') == 'ja', 'Versandfreigabe abgebrochen.')


@contextlib.contextmanager
def locked(host):
    directory = host.path(STATE_DIR)
    for ancestor in (directory, *directory.parents):
        require(not ancestor.is_symlink(), 'Symlink im Zustandspfad. Abbruch.')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.stat()
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700,
            STATE_DIR + ' muss root gehoeren und Modus 0700 haben.')
    lock_path = directory / 'lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        require(os.fstat(fd).st_uid == 0, 'Lock gehoert nicht root.')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Error('Ein anderer Verwaltungsassistent ist bereits aktiv.') from exc
        yield
    finally:
        os.close(fd)


def show_status(manager):
    print('KienzleFax Verwaltung ' + VERSION)
    pending = manager.load(PENDING)
    if pending:
        print('ACHTUNG: Unvollstaendige Transaktion; zuerst --restore ausfuehren.')
    problems = manager.drift()
    for problem in problems:
        print('ABWEICHUNG: ' + problem)
    for key in manager.inventory():
        status = 'durch Assistent pausiert' if key in manager.state['disabled'] else 'keine Assistentensperre'
        if key in SERVICES:
            svc = manager.host.service(SERVICES[key])
            status += '; Dienst ' + ('laeuft' if svc and svc['active'] else 'laeuft nicht')
        print('  ' + label(key) + ': ' + status)
    print('Installerlaeufe koennen Konfigurationen/Dienste erneut aktivieren. Danach Status pruefen.')
    return bool(problems or pending)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='kienzlefax-verwalten.sh', description='IMMER verwenden wenn KienzleFax reversibel pausiert oder wieder freigegeben werden soll.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--status', action='store_true', help='Zustand und externe Aenderungen anzeigen (nur lesen)')
    mode.add_argument('--restore', action='store_true', help='letzte/unvollstaendige Transaktion nach Bestaetigung zuruecknehmen')
    mode.add_argument('--dry-run', action='store_true', help='Dialog und gepruefte Vorschau, keine Aenderungen')
    parser.add_argument('--version', action='version', version=VERSION)
    args = parser.parse_args(argv)
    require(sys.platform.startswith('linux'), 'Zielsystem ist Debian/Raspberry Pi OS Linux; hier werden keine Dienste geaendert.')
    require(os.geteuid() == 0, 'Bitte mit sudo/root starten (auch Status braucht geschuetzte Konfigurationen).')
    os.umask(0o077)
    host = Host()
    if args.status:
        return 2 if show_status(Manager(host)) else 0
    # Lock only after approval: cancelling a dialog and dry-run create no state files.
    with contextlib.nullcontext():
        manager = Manager(host)
        if args.restore:
            pending = manager.load(PENDING)
            transaction = pending or manager.load(LAST)
            require(transaction is not None and transaction['status'] != 'restored', 'Keine offene Ruecknahme vorhanden.')
            if not pending:
                manager.assert_clean()
                require(manager.state['revision'] == transaction['id'], 'Letzte Sicherung passt nicht zum aktuellen Zustand.')
            print('Letzte ' + ('unvollstaendige ' if pending else '') + 'Aenderung zuruecknehmen:')
            for key in transaction['changed']:
                print('  ' + label(key))
            if transaction['before_services'].get('fax_send', {}).get('active'):
                confirm_queue(host)
            require(answer('Vorherigen Zustand wiederherstellen? [ja/NEIN] ', {'ja', 'nein'}, 'nein') == 'ja', 'Abgebrochen.')
            with locked(host):
                current = Manager(host)
                latest_pending = current.load(PENDING)
                latest = latest_pending or current.load(LAST)
                require(latest == transaction, 'Ruecknahme seit Vorschau geaendert. Bitte erneut starten.')
                if not latest_pending:
                    current.assert_clean()
                current.rollback(transaction, pending=bool(pending))
            print('Vorheriger Zustand wiederhergestellt. Dokumente und Warteschlangen bleiben erhalten.')
            return 0
        manager.assert_clean()
        show_status(manager)
        print('\nJede Auswahl gilt dauerhaft, auch nach Neustart. [u] unveraendert, [a] Sperre aufheben, [d] deaktivieren.')
        print('Aktivieren stellt den Zustand vor der Pause wieder her; vorher gestoppte Dienste bleiben gestoppt.')
        print('Freigaben sperren nur den Netzwerkzugriff. Dateien bleiben lokal und ggf. im Web erreichbar.')
        print('Web aus stoppt keinen Versand. Versand aus verhindert nicht das Anlegen weiterer Web-Auftraege.')
        print('Fax-OCR kann nur zusammen mit deaktiviertem Faxempfang pausieren.')
        desired = set(manager.state['disabled'])
        for key in manager.inventory():
            value = answer(label(key) + ' [U/a/d]: ', {'u', 'a', 'd'}, 'u')
            if value == 'a':
                desired.discard(key)
            elif value == 'd':
                desired.add(key)
        plan = manager.plan(desired)
        if plan is None:
            print('Keine Aenderungen ausgewaehlt.')
            return 0
        print('\nVorschau:')
        for key in plan['changed']:
            print('  ' + label(key) + ': ' + ('DEAKTIVIEREN' if key in desired else 'VORHERIGEN ZUSTAND FREIGEBEN'))
        if plan['registration_off']:
            print('  Zugehoerige SIP-Registrierungen werden dauerhaft entfernt und abgemeldet.')
        print('  Konfigurationen werden geschuetzt gesichert; keine Dokumente, Queues oder Pakete werden geloescht.')
        if args.dry_run:
            print('Vorschau beendet. Keine Aenderungen vorgenommen.')
            return 0
        if plan['after_services'].get('fax_send'):
            confirm_queue(host)
        require(answer('Diese Aenderungen jetzt anwenden? [ja/NEIN] ', {'ja', 'nein'}, 'nein') == 'ja', 'Abgebrochen.')
        with locked(host):
            Manager(host).apply(plan)
        print('Aenderungen angewendet. Ruecknahme: sudo bash kienzlefax-verwalten.sh --restore')
        return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Error, KeyboardInterrupt) as exc:
        print('ABBRUCH: ' + (str(exc) or 'Benutzerabbruch.'), file=sys.stderr)
        sys.exit(1)
KFX_PYTHON
)" "$@"
