<?php
/**
 * kienzlefax.php
 * Producer Web-UI (sendet NICHT selbst).
 *
 * Version: 1.4.6
 * Author: Dr. Thomas Kienzle
 * Stand: 2026-06-23
 *
 * Changelog (komplett):
 * - 1.4.6 (2026-06-23):
 *   - UI: Eingangszaehler in der Sidebar kompakter dargestellt, damit der Eingaenge-Tab nicht zu breit wird.
 *
 * - 1.4.5 (2026-06-23):
 *   - UI: Eingaenge-Tab zeigt prominent getrennte Live-Zaehler fuer Fax-Eingang und Scan-Eingang.
 *   - Audio: Bei neu eingegangenen Fax-/Scan-Dateien wird eine dezente Glocke abgespielt.
 *
 * - 1.4.4 (2026-06-23):
 *   - UI: Neue Ansicht Eingaenge mit Fax-Eingang und Scan-Eingang; Faxdateien zeigen Datum/Uhrzeit,
 *     Absendernummer und gespeicherten Telefonbuchnamen.
 *
 * - 1.4.3 (2026-06-23):
 *   - UI: Beim erneuten Senden aus der Quelle Sendefehler wird der zugehoerige Fehlerbericht
 *     automatisch sofort ins Sendeprotokoll uebernommen.
 *
 * - 1.4.2 (2026-06-23):
 *   - UI: Aktive Jobs zeigen die Fax-Datenrate nur noch im Tooltip, nicht mehr in der kompakten Statuszeile.
 *
 * - 1.4.1 (2026-06-23):
 *   - UI: Aktive Jobs zeigen bei bekannter Gesamtseitenzahl ab Sendebeginn 1/gesamt statt ?/gesamt.
 *   - UI: Sendeprotokoll liest Asterisk-Faxseiten aus result.faxpages_sent/result.faxpages_total/result.faxpages_raw.
 *   - UI: Sendeprotokoll zeigt Ende in deutscher Zeit.
 *   - UI: Sendeprotokoll zeigt bevorzugt die echte Asterisk-Uebertragungsdauer aus live.asterisk_fax.elapsed_sec.
 *
 * - 1.4 (2026-06-22):
 *   - Quellen: fax-Drucker und PDF-zu-Fax-Ordner werden aus /srv/kienzlefax/config/sources.json geladen;
 *     bei fehlender/ungueltiger Datei bleibt der alte Standard fax1..fax5 + pdf-zu-fax + sendefehler aktiv.
 *   - Beauftragen: Mehrere Empfaenger pro Absenden moeglich; pro PDF x Empfaenger wird ein eigener Job erzeugt.
 *   - Beauftragen: Jeder Job erhaelt eigene Kopien doc.pdf und source.pdf; Originale werden erst nach erfolgreicher Job-Anlage entfernt.
 *   - Beauftragen: Bei Fehlern waehrend der Job-Anlage werden Teil-Jobs bestmoeglich entfernt und Originale bleiben liegen.
 *   - UI: PDF-Liste der aktuellen Quelle aktualisiert automatisch per AJAX, ohne Empfaenger-Eingaben zu ersetzen.
 *   - UI: Aktive Jobs zeigen Asterisk-Live-Details: aktuelle/gesamte Seiten, Call-Dauer und Datenrate.
 *   - UI: Sendeprotokoll zeigt Ende in deutscher Zeit und bevorzugt die echte Asterisk-Uebertragungsdauer.
 *   - UI: Footer verlinkt kienzlefax auf kienzlefax.de.
 *
 * - 1.3 (2026-02-15):
 *   - UI: 🔔 Glocke (Sound an/aus) in Kopfzeile; AUS-Zustand mit dickem rotem, schrägem Durchstreich-Strich.
 *   - Audio: faxton.mp3 (liegt neben kienzlefax.php) wird nur bei NEUEM Sendefehler abgespielt (fail_count steigt, via AJAX-Status).
 *   - Persistenz: Sound-Status + letzter fail_count via localStorage.
 *
 * - 1.2.4 (2026-02-15):
 *   - UI (Aktive Jobs, weniger technisch): Job-ID ist nicht mehr sichtbar. Zeile 1 zeigt Empfängername (…),
 *     Tooltip enthält Faxnummer + Originaldatei + Job-ID.
 *   - UI (Aktive Jobs, Statuszeile): Zeile 2 zeigt kompakt Live-Infos:
 *       processing: "Sende: x/y · 5:23 · processing · submitted · Versuch a/b"
 *       queue:       "queued · erstellt HH:MM" (ohne "Sende:", da noch nicht gestartet)
 *     Tooltip zeigt die vollständige (ungekürzte) Statuszeile + live.faxstat_status/state (falls vorhanden).
 *   - Live-Update ohne Browser-Refresh: Soft-Refresh per AJAX (polling), aktualisiert:
 *       • KPI-Zähler (queue/processing)
 *       • Sidebar "Aktive Jobs"
 *       • Pulsieren Fehlerberichte (an/aus) + Fehleranzahl im Tooltip
 *     Formulare/Tabellen werden nicht angefasst (kein Kollateralschaden).
 *
 * - 1.2.3 (2026-02-14):
 *   - BUGFIX: Seitenanzeige im Sendeprotokoll wieder robust (result.pages -> npages/totpages -> pages).
 *
 * - 1.2.2 (2026-02-14):
 *   - UI: Linke Sidebar ca. 30% schmaler (360px -> 260px) für bessere Nutzbarkeit bei ~1000px Fensterbreite.
 *   - UI: Aktive Jobs: Status (queue/processing) platzsparend als Text integriert; Chip entfernt.
 *   - UI: Lange PDF-Dateinamen werden überall in der UI einzeilig gekürzt ("…") + Tooltip mit vollem Namen.
 *
 * - 1.2.1 (2026-02-14):
 *   - FIX: Robustere Erkennung "⛔ Abgebrochen" in Fehlerberichte UND Sendeprotokoll (cancel/aborted/statuscode 345).
 *   - FIX: Formfelder nutzen box-sizing:border-box (Faxnummer läuft nicht mehr über Begrenzung).
 *   - UI: Abbruch-Button bei aktiven Jobs dezenter Icon-Button (kein großes rotes Feld).
 *
 * - 1.2 (2026-02-14):
 *   - UI: Version + Autor als Footer unten mittig.
 *   - UI: Empfänger-Layout korrigiert: mehr Abstand Name↔Fax, Gesamtbreite reduziert, Empfängernamefeld kürzer.
 *   - UI: "Fax beauftragen" wieder auf Höhe des Auflösungs-Dropdowns (bündig).
 *   - UI: PDF-Button: Text nur "löschen" (Funktion unverändert).
 *   - UI: PDF-Dateiliste zeigt Dateigröße.
 *   - UI: Aktive Jobs können abgebrochen werden (⛔-Button je Job, mit Rückfrage).
 *   - JSON: Abbruch setzt cancel.requested=true + cancel.requested_at=ISO8601 (Worker übernimmt).
 *   - UI: Status-Anzeige "⛔ Abgebrochen" in Fehlerberichte UND Sendeprotokoll, wenn JSON abort erkennen lässt.
 *   - UI: Fehlerberichte-Tab pulsiert deutlich bei Fehlern.
 *
 * - 1.1 (2026-02-14):
 *   - UI: Subtitle ersetzt durch "Der ideale Faxserver für Arztpraxen".
 *   - UI: "Bitte wählen:" über der Ordnerauswahl.
 *   - UI: Refresh-Button in der Kopfzeile.
 *   - UI: PDF-Auswahl: Button zum Löschen ausgewählter PDFs (Quelle).
 *   - UI: Sendeprotokoll: Option "alle anzeigen" (capped).
 *   - UI: Fehlerberichte: Checkboxen + Aktionen "Ausgewählte löschen" und "Fehler in Sendeprotokoll übernehmen".
 *   - UI: Tab "Fehlerberichte" pulsiert deutlich, wenn Fehler vorhanden sind.
 *
 * - 1.0 (2026-02-13):
 *   - Bugfix: "Speichern im Telefonbuch" verursachte 500 (kaputter Restcode entfernt).
 *   - Telefonbuch: Speichern im Editor funktioniert (sofern DB/Dir-Rechte korrekt).
 *   - UI: mehr Abstand zwischen Empfängername/Faxnummer.
 *   - Beauftragen: Original-PDF wird in queue/<jobid>/source.pdf verschoben (Quelle ist danach leer).
 *   - Fehlerfälle erneut senden: weiterhin über Quelle "sendefehler" möglich; Fehlerberichte-View enthält Shortcut.
 */

declare(strict_types=1);
error_reporting(E_ALL);
ini_set('display_errors', '0');
mb_internal_encoding('UTF-8');

function source_id_is_valid(string $id): bool {
  return (bool)preg_match('/\A[a-z0-9][a-z0-9_-]{0,63}\z/', $id);
}

function normalize_source_definitions(array $rawSources): array {
  $out = [];
  $seen = [];

  foreach ($rawSources as $item) {
    if (!is_array($item)) continue;

    $id = trim((string)($item['id'] ?? ''));
    $path = trim((string)($item['path'] ?? ''));
    if (!source_id_is_valid($id)) continue;
    if ($path === '' || !str_starts_with($path, '/')) continue;
    if (strpos($path, "\0") !== false) continue;
    if (isset($seen[$id])) continue;

    $enabled = (bool)($item['enabled'] ?? true);
    $sendable = (bool)($item['sendable'] ?? true);
    if (!$enabled || !$sendable) continue;

    $label = trim((string)($item['label'] ?? ''));
    if ($label === '') $label = $id;

    $kind = trim((string)($item['kind'] ?? 'source'));
    if ($kind === '') $kind = 'source';

    $order = (int)($item['order'] ?? ((count($out) + 1) * 10));

    $out[] = [
      'id' => $id,
      'label' => $label,
      'kind' => $kind,
      'path' => rtrim($path, '/'),
      'order' => $order,
    ];
    $seen[$id] = true;
  }

  usort($out, static function(array $a, array $b): int {
    $cmp = ((int)$a['order']) <=> ((int)$b['order']);
    return $cmp !== 0 ? $cmp : strcmp((string)$a['id'], (string)$b['id']);
  });

  return $out;
}

function load_source_config(string $configPath, array $fallbackSources, string $fallbackDefault): array {
  $sources = [];
  $default = '';

  if (is_file($configPath) && is_readable($configPath)) {
    $raw = @file_get_contents($configPath);
    if ($raw !== false) {
      $j = json_decode($raw, true);
      if (is_array($j)) {
        $sources = normalize_source_definitions(is_array($j['sources'] ?? null) ? $j['sources'] : []);
        $default = trim((string)($j['default_source'] ?? ''));
      }
    }
  }

  if (count($sources) === 0) {
    $sources = normalize_source_definitions($fallbackSources);
    $default = $fallbackDefault;
  }

  $ids = [];
  foreach ($sources as $s) $ids[(string)$s['id']] = true;

  if ($default === '' || !isset($ids[$default])) {
    $default = isset($ids[$fallbackDefault]) ? $fallbackDefault : (string)($sources[0]['id'] ?? '');
  }

  return ['sources' => $sources, 'default_source' => $default];
}

// -------------------- Konfiguration --------------------
$BASE = '/srv/kienzlefax';

$DIR_INCOMING = $BASE . '/incoming';
$DIR_DROPIN   = $BASE . '/pdf-zu-fax';
$DIR_STAGING  = $BASE . '/staging';
$DIR_QUEUE    = $BASE . '/queue';
$DIR_PROC     = $BASE . '/processing';

$DIR_ARCHIVE  = $BASE . '/sendeberichte';
$DIR_FAIL_IN  = $BASE . '/sendefehler/eingang';
$DIR_FAIL_REP = $BASE . '/sendefehler/berichte';
$DIR_FAX_INBOX  = '/var/spool/asterisk/fax';
$DIR_SCAN_INBOX = '/srv/scan/ocr';

$DB_PATH      = $BASE . '/phonebook.sqlite';

$SOURCE_CONFIG_PATH = $BASE . '/config/sources.json';

$FALLBACK_SOURCES = [
  ['id' => 'fax1', 'label' => 'Faxdrucker 1', 'kind' => 'fax_printer', 'path' => $DIR_INCOMING . '/fax1', 'enabled' => true, 'sendable' => true, 'order' => 10],
  ['id' => 'fax2', 'label' => 'Faxdrucker 2', 'kind' => 'fax_printer', 'path' => $DIR_INCOMING . '/fax2', 'enabled' => true, 'sendable' => true, 'order' => 20],
  ['id' => 'fax3', 'label' => 'Faxdrucker 3', 'kind' => 'fax_printer', 'path' => $DIR_INCOMING . '/fax3', 'enabled' => true, 'sendable' => true, 'order' => 30],
  ['id' => 'fax4', 'label' => 'Faxdrucker 4', 'kind' => 'fax_printer', 'path' => $DIR_INCOMING . '/fax4', 'enabled' => true, 'sendable' => true, 'order' => 40],
  ['id' => 'fax5', 'label' => 'Faxdrucker 5', 'kind' => 'fax_printer', 'path' => $DIR_INCOMING . '/fax5', 'enabled' => true, 'sendable' => true, 'order' => 50],
  ['id' => 'pdf-zu-fax', 'label' => 'PDF zu Fax', 'kind' => 'dropin', 'path' => $DIR_DROPIN, 'enabled' => true, 'sendable' => true, 'order' => 100],
  ['id' => 'sendefehler', 'label' => 'Sendefehler', 'kind' => 'failed_inbox', 'path' => $DIR_FAIL_IN, 'enabled' => true, 'sendable' => true, 'order' => 900],
];

$SOURCE_CONFIG = load_source_config($SOURCE_CONFIG_PATH, $FALLBACK_SOURCES, 'fax1');
$SOURCE_DEFS = $SOURCE_CONFIG['sources'];
$DEFAULT_SOURCE = (string)$SOURCE_CONFIG['default_source'];

$ALLOW_SOURCES = [];
$SOURCE_LABELS = [];
$SOURCE_KINDS = [];
foreach ($SOURCE_DEFS as $sourceDef) {
  $sid = (string)$sourceDef['id'];
  $ALLOW_SOURCES[$sid] = (string)$sourceDef['path'];
  $SOURCE_LABELS[$sid] = (string)$sourceDef['label'];
  $SOURCE_KINDS[$sid] = (string)$sourceDef['kind'];
}
if ($DEFAULT_SOURCE === '' || !isset($ALLOW_SOURCES[$DEFAULT_SOURCE])) {
  $DEFAULT_SOURCE = (string)(array_key_first($ALLOW_SOURCES) ?? 'fax1');
}

$EXCLUDE_SUFFIXES = ['__OK.pdf', '__FAILED.pdf'];
$EXCLUDE_CONTAINS = ['__REPORT__'];

$MAX_LIST_FILES   = 500;
$MAX_ACTIVE_JOBS  = 12;
$MAX_FAIL_LIST    = 200;
$MAX_ARCHIVE_LIST = 25;
$MAX_INBOX_LIST   = 200;

$APP_TITLE   = 'kienzlefax';
$APP_VERSION = '1.4.6';
$APP_AUTHOR  = 'Dr. Thomas Kienzle';

// Audio-Datei (liegt neben dieser PHP)
$ALERT_MP3 = 'faxton.mp3';

// -------------------- Helpers --------------------
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

function ensure_dir(string $path): void {
  if (!is_dir($path)) throw new RuntimeException("Verzeichnis fehlt: $path");
}

function safe_realpath(string $path): ?string {
  $rp = realpath($path);
  return ($rp === false) ? null : $rp;
}

function within_dir(string $candidate, string $baseDir): bool {
  $rpC = safe_realpath($candidate);
  $rpB = safe_realpath($baseDir);
  if ($rpC === null || $rpB === null) return false;
  return str_starts_with($rpC, $rpB . DIRECTORY_SEPARATOR) || $rpC === $rpB;
}

function filename_is_sendable_pdf(string $fn, array $excludeSuffixes, array $excludeContains): bool {
  if ($fn === '' || $fn[0] === '.') return false;
  if (!preg_match('/\.pdf\z/i', $fn)) return false;
  foreach ($excludeSuffixes as $suf) {
    if (str_ends_with($fn, $suf)) return false;
  }
  foreach ($excludeContains as $needle) {
    if (strpos($fn, $needle) !== false) return false;
  }
  return true;
}

function list_source_pdfs(string $dir, array $excludeSuffixes, array $excludeContains, int $limit): array {
  $files = [];
  if (!is_dir($dir)) return $files;
  $dh = opendir($dir);
  if ($dh === false) return $files;

  while (($e = readdir($dh)) !== false) {
    if (!filename_is_sendable_pdf($e, $excludeSuffixes, $excludeContains)) continue;
    $p = $dir . '/' . $e;
    if (is_file($p)) $files[] = $e;
  }
  closedir($dh);

  sort($files, SORT_NATURAL | SORT_FLAG_CASE);
  if (count($files) > $limit) $files = array_slice($files, 0, $limit);
  return $files;
}

function source_label(string $src): string {
  return (string)($GLOBALS['SOURCE_LABELS'][$src] ?? $src);
}

function build_source_files_payload(string $src, string $dir, array $excludeSuffixes, array $excludeContains, int $limit): array {
  $files = [];
  foreach (list_source_pdfs($dir, $excludeSuffixes, $excludeContains, $limit) as $fn) {
    $p = $dir . '/' . $fn;
    $sz = is_file($p) ? filesize($p) : null;
    $files[] = [
      'filename' => $fn,
      'size' => is_int($sz) ? $sz : null,
      'size_label' => format_size(is_int($sz) ? $sz : null),
    ];
  }

  return [
    'src' => $src,
    'label' => source_label($src),
    'files' => $files,
  ];
}

function list_job_dirs(string $dir): array {
  $out = [];
  if (!is_dir($dir)) return $out;
  $dh = opendir($dir);
  if ($dh === false) return $out;
  while (($e = readdir($dh)) !== false) {
    if ($e === '.' || $e === '..') continue;
    $p = $dir . '/' . $e;
    if (is_dir($p)) $out[] = $e;
  }
  closedir($dh);
  sort($out);
  return $out;
}

function normalize_fax_number(string $input): string {
  $n = preg_replace('/\D+/', '', $input ?? '');
  $n = $n ?? '';
  if ($n === '') return '';
  if (str_starts_with($n, '00')) $n = substr($n, 2);
  if (str_starts_with($n, '0') && !str_starts_with($n, '00')) {
    $n = '49' . substr($n, 1);
  }
  return $n;
}

function random_suffix(int $len = 6): string {
  $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  $bytes = random_bytes($len);
  $out = '';
  for ($i = 0; $i < $len; $i++) {
    $out .= $alphabet[ord($bytes[$i]) % strlen($alphabet)];
  }
  return $out;
}

function make_job_id(): string {
  return 'JOB-' . date('Ymd-His') . '-' . random_suffix(6);
}

function json_write_atomic(string $path, array $data): void {
  $tmp = $path . '.tmp.' . random_suffix(6);
  $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
  if ($json === false) throw new RuntimeException('JSON encode failed');
  if (file_put_contents($tmp, $json . "\n", LOCK_EX) === false) throw new RuntimeException("Write failed: $tmp");
  if (!rename($tmp, $path)) {
    @unlink($tmp);
    throw new RuntimeException("Atomic rename failed: $path");
  }
}

function remove_job_dir_safe(string $dir, string $baseDir): void {
  $name = basename($dir);
  if (!validate_job_id($name)) return;
  if (!within_dir($dir, $baseDir) || !is_dir($dir)) return;

  $items = scandir($dir);
  if ($items === false) return;
  foreach ($items as $item) {
    if ($item === '.' || $item === '..') continue;
    $path = $dir . '/' . $item;
    if (is_dir($path)) {
      remove_job_dir_safe($path, $dir);
    } elseif (within_dir($path, $dir)) {
      @unlink($path);
    }
  }
  @rmdir($dir);
}

function open_db(string $dbPath): PDO {
  $pdo = new PDO('sqlite:' . $dbPath, null, null, [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
  ]);
  $pdo->exec("
    CREATE TABLE IF NOT EXISTS contacts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      number TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ");
  $pdo->exec("CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts(name);");
  return $pdo;
}

function get_contacts(PDO $pdo): array {
  return $pdo->query("SELECT * FROM contacts ORDER BY name COLLATE NOCASE ASC")->fetchAll();
}

function get_contact(PDO $pdo, int $id): ?array {
  $st = $pdo->prepare("SELECT * FROM contacts WHERE id = :id");
  $st->execute([':id' => $id]);
  $row = $st->fetch();
  return $row ?: null;
}

function upsert_contact(PDO $pdo, ?int $id, string $name, string $number, string $note = ''): void {
  $now = date('c');
  if ($id && $id > 0) {
    $st = $pdo->prepare("UPDATE contacts SET name=:n, number=:num, note=:note, updated_at=:u WHERE id=:id");
    $st->execute([':n' => $name, ':num' => $number, ':note' => $note, ':u' => $now, ':id' => $id]);
  } else {
    $st = $pdo->prepare("INSERT INTO contacts(name, number, note, created_at, updated_at) VALUES(:n,:num,:note,:c,:u)");
    $st->execute([':n' => $name, ':num' => $number, ':note' => $note, ':c' => $now, ':u' => $now]);
  }
}

function collect_recipients_from_post(PDO $pdo): array {
  $raw = $_POST['recipients'] ?? null;
  if (!is_array($raw)) {
    $raw = [[
      'contact_id' => $_POST['contact_id'] ?? '',
      'name' => $_POST['recipient_name'] ?? '',
      'number' => $_POST['recipient_number'] ?? '',
      'save_to_phonebook' => isset($_POST['save_to_phonebook']) ? '1' : '',
    ]];
  }

  $recipients = [];
  $errors = [];
  $blockNo = 0;

  foreach ($raw as $item) {
    if (!is_array($item)) continue;
    $blockNo++;

    $contactIdRaw = trim((string)($item['contact_id'] ?? ''));
    $name = trim((string)($item['name'] ?? ''));
    $numberRaw = trim((string)($item['number'] ?? ''));
    $saveToPhonebook = isset($item['save_to_phonebook']) && (string)$item['save_to_phonebook'] !== '';

    if ($contactIdRaw === '' && $name === '' && $numberRaw === '' && !$saveToPhonebook) {
      continue;
    }

    $contactId = null;
    if ($contactIdRaw !== '') {
      $contactId = (int)$contactIdRaw;
      $c = $contactId > 0 ? get_contact($pdo, $contactId) : null;
      if ($c) {
        if ($name === '') $name = (string)$c['name'];
        if ($numberRaw === '') $numberRaw = (string)$c['number'];
      } else {
        $errors[] = "Empfänger $blockNo: Telefonbuch-Eintrag nicht gefunden.";
      }
    }

    $norm = normalize_fax_number($numberRaw);
    if ($name === '') $errors[] = "Empfänger $blockNo: Empfängername fehlt.";
    if ($norm === '') $errors[] = "Empfänger $blockNo: Faxnummer fehlt/ungültig.";

    if ($name !== '' && $norm !== '') {
      $recipients[] = [
        'label_no' => $blockNo,
        'contact_id' => $contactId,
        'name' => $name,
        'number' => $norm,
        'save_to_phonebook' => $saveToPhonebook,
      ];
    }
  }

  if (count($recipients) === 0 && count($errors) === 0) {
    $errors[] = "Mindestens ein Empfänger fehlt.";
  }

  return ['recipients' => $recipients, 'errors' => $errors];
}

function send_file_pdf(string $path, string $downloadName): void {
  if (!is_file($path)) { http_response_code(404); echo "Not found"; exit; }
  header('Content-Type: application/pdf');
  header('Content-Disposition: inline; filename="' . str_replace('"', '', $downloadName) . '"');
  header('Content-Length: ' . (string)filesize($path));
  readfile($path);
  exit;
}

function send_file_text(string $path, string $downloadName, string $contentType = 'application/json'): void {
  if (!is_file($path)) { http_response_code(404); echo "Not found"; exit; }
  header('Content-Type: ' . $contentType . '; charset=utf-8');
  header('Content-Disposition: inline; filename="' . str_replace('"', '', $downloadName) . '"');
  readfile($path);
  exit;
}

function parse_iso_time(?string $s): ?int {
  if (!$s) return null;
  $t = strtotime($s);
  return $t === false ? null : $t;
}

function format_local_datetime(?string $s): string {
  $s = trim((string)$s);
  if ($s === '') return '';
  try {
    $dt = new DateTimeImmutable($s);
    $dt = $dt->setTimezone(new DateTimeZone('Europe/Berlin'));
    return $dt->format('d.m.Y H:i:s');
  } catch (Throwable $e) {
    return $s;
  }
}

function format_unix_local_datetime(?int $ts): string {
  if ($ts === null || $ts <= 0) return '';
  try {
    $dt = (new DateTimeImmutable('@' . $ts))->setTimezone(new DateTimeZone('Europe/Berlin'));
    return $dt->format('d.m.Y H:i:s');
  } catch (Throwable $e) {
    return '';
  }
}

function format_duration(?int $sec): string {
  if ($sec === null || $sec < 0) return '';
  $m = intdiv($sec, 60);
  $s = $sec % 60;
  if ($m <= 0) return $s . ' s';
  return $m . ' min ' . $s . ' s';
}

function extract_transmission_duration_sec(array $j): ?int {
  if (isset($j['live']) && is_array($j['live']) && isset($j['live']['asterisk_fax']) && is_array($j['live']['asterisk_fax'])) {
    $af = $j['live']['asterisk_fax'];
    if (isset($af['elapsed_sec']) && is_numeric($af['elapsed_sec'])) {
      return max(0, (int)$af['elapsed_sec']);
    }
    if (!empty($af['connected_at']) && !empty($af['updated_at'])) {
      $t1 = parse_iso_time((string)$af['connected_at']);
      $t2 = parse_iso_time((string)$af['updated_at']);
      if ($t1 !== null && $t2 !== null && $t2 >= $t1) return $t2 - $t1;
    }
  }

  if (isset($j['result']) && is_array($j['result'])) {
    foreach (['elapsed_sec', 'duration_sec', 'tx_time_sec'] as $k) {
      if (isset($j['result'][$k]) && is_numeric($j['result'][$k])) return max(0, (int)$j['result'][$k]);
    }
  }

  return null;
}

function format_hms_compact(?int $sec): string {
  if ($sec === null || $sec < 0) return '';
  $sec = (int)$sec;
  $h = intdiv($sec, 3600);
  $m = intdiv($sec % 3600, 60);
  $s = $sec % 60;
  if ($h > 0) return $h . ':' . str_pad((string)$m, 2, '0', STR_PAD_LEFT) . ':' . str_pad((string)$s, 2, '0', STR_PAD_LEFT);
  return $m . ':' . str_pad((string)$s, 2, '0', STR_PAD_LEFT);
}

function count_json_files(string $dir, int $cap = 999): int {
  $n = 0;
  if (!is_dir($dir)) return 0;
  $dh = opendir($dir);
  if ($dh === false) return 0;
  while (($e = readdir($dh)) !== false) {
    if (!preg_match('/\.json\z/i', $e)) continue;
    $p = $dir . '/' . $e;
    if (!is_file($p)) continue;
    $n++;
    if ($n >= $cap) break;
  }
  closedir($dh);
  return $n;
}

function validate_job_id(string $id): bool {
  return (bool)preg_match('/\AJOB-\d{8}-\d{6}-[a-z0-9]{6}\z/', $id);
}

function read_json_file(string $path): ?array {
  if (!is_file($path)) return null;
  $raw = @file_get_contents($path);
  if ($raw === false) return null;
  $j = json_decode($raw, true);
  return is_array($j) ? $j : null;
}

function is_aborted_job(array $j): bool {
  if (isset($j['cancel']) && is_array($j['cancel'])) {
    $req = (bool)($j['cancel']['requested'] ?? false);
    $handledAt = (string)($j['cancel']['handled_at'] ?? '');
    if ($req && $handledAt !== '') return true;
  }

  $reason = '';
  $text = '';
  if (isset($j['result']) && is_array($j['result'])) {
    $reason = (string)($j['result']['reason'] ?? '');
    $text   = (string)($j['result']['status_text'] ?? '');
  }
  if (stripos($reason, 'aborted') !== false) return true;
  if (stripos($text, 'aborted') !== false) return true;

  $code = null;
  if (isset($j['result']) && is_array($j['result']) && isset($j['result']['statuscode'])) {
    $code = (int)$j['result']['statuscode'];
  }
  $req2 = (bool)($j['cancel']['requested'] ?? false);
  if ($req2 && $code === 345) return true;

  return false;
}

function extract_pages(array $j): string {
  if (isset($j['result']) && is_array($j['result'])) {
    if (array_key_exists('faxpages_sent', $j['result']) || array_key_exists('faxpages_total', $j['result'])) {
      $sentS = array_key_exists('faxpages_sent', $j['result']) ? trim((string)$j['result']['faxpages_sent']) : '';
      $totalS = array_key_exists('faxpages_total', $j['result']) ? trim((string)$j['result']['faxpages_total']) : '';
      if ($sentS !== '' && $totalS !== '') return $sentS . '/' . $totalS;
      if ($sentS !== '') return $sentS;
      if ($totalS !== '') return $totalS;
    }

    $fr = isset($j['result']['faxpages_raw']) ? trim((string)$j['result']['faxpages_raw']) : '';
    if ($fr !== '') return $fr;

    $rp = isset($j['result']['pages']) ? (string)$j['result']['pages'] : '';
    if ($rp !== '') return $rp;

    if (array_key_exists('npages', $j['result']) && array_key_exists('totpages', $j['result'])) {
      $npS = (string)$j['result']['npages'];
      $tpS = (string)$j['result']['totpages'];
      if ($npS !== '' && $tpS !== '') return $npS . '/' . $tpS;
    }
  }

  if (isset($j['pages'])) {
    $p = (string)$j['pages'];
    if ($p !== '') return $p;
  }

  return '';
}

function failed_pdf_for_json(string $jsonFn): string {
  if (!preg_match('/\A(.+)\.json\z/i', $jsonFn, $m)) return '';
  return $m[1] . '__FAILED.pdf';
}

function move_failure_report_to_archive(string $jsonFn): bool {
  if ($jsonFn === '' || !preg_match('/\.json\z/i', $jsonFn)) return false;

  $jsonPath = $GLOBALS['DIR_FAIL_REP'] . '/' . $jsonFn;
  if (!within_dir($jsonPath, $GLOBALS['DIR_FAIL_REP']) || !is_file($jsonPath)) return false;

  $destJson = $GLOBALS['DIR_ARCHIVE'] . '/' . $jsonFn;
  if (is_file($destJson)) {
    $destJson = $GLOBALS['DIR_ARCHIVE'] . '/' . preg_replace('/\.json\z/i', '', $jsonFn) . '.moved.' . random_suffix(6) . '.json';
  }

  if (!@rename($jsonPath, $destJson)) return false;

  $pdfFn = failed_pdf_for_json($jsonFn);
  if ($pdfFn !== '') {
    $srcPdf = $GLOBALS['DIR_FAIL_REP'] . '/' . $pdfFn;
    if (within_dir($srcPdf, $GLOBALS['DIR_FAIL_REP']) && is_file($srcPdf)) {
      $destPdf = $GLOBALS['DIR_ARCHIVE'] . '/' . $pdfFn;
      if (is_file($destPdf)) {
        $destPdf = $GLOBALS['DIR_ARCHIVE'] . '/' . preg_replace('/\.pdf\z/i', '', $pdfFn) . '.moved.' . random_suffix(6) . '.pdf';
      }
      @rename($srcPdf, $destPdf);
    }
  }

  return true;
}

function find_failure_report_for_resend_pdf(string $pdfFn): ?string {
  if (!preg_match('/\A(.+)\.pdf\z/i', $pdfFn, $m)) return null;
  $stem = $m[1];

  $exact = $stem . '.json';
  $exactPath = $GLOBALS['DIR_FAIL_REP'] . '/' . $exact;
  if (within_dir($exactPath, $GLOBALS['DIR_FAIL_REP']) && is_file($exactPath)) return $exact;

  $candidates = [];
  if (!is_dir($GLOBALS['DIR_FAIL_REP'])) return null;
  $dh = opendir($GLOBALS['DIR_FAIL_REP']);
  if ($dh === false) return null;

  while (($e = readdir($dh)) !== false) {
    if (!preg_match('/\.json\z/i', $e)) continue;
    $p = $GLOBALS['DIR_FAIL_REP'] . '/' . $e;
    if (!within_dir($p, $GLOBALS['DIR_FAIL_REP']) || !is_file($p)) continue;

    $match = false;
    if (preg_match('/\A(.+)\.json\z/i', $e, $jm)) {
      $jsonStem = $jm[1];
      if ($jsonStem === $stem || str_starts_with($jsonStem, $stem . '__JOB-')) $match = true;
    }

    if (!$match) {
      $j = read_json_file($p);
      if (is_array($j)) {
        $srcFn = basename((string)($j['source']['filename_original'] ?? ''));
        if ($srcFn === $pdfFn) $match = true;
      }
    }

    if ($match) {
      $candidates[] = ['file' => $e, 'mtime' => @filemtime($p) ?: 0];
    }
  }
  closedir($dh);

  if (count($candidates) === 0) return null;
  usort($candidates, static fn($a, $b) => ($a['mtime'] <=> $b['mtime']) ?: strcmp((string)$a['file'], (string)$b['file']));
  return (string)$candidates[0]['file'];
}

function format_size(?int $bytes): string {
  if ($bytes === null || $bytes < 0) return '—';
  if ($bytes < 1024) return $bytes . ' B';
  $kb = $bytes / 1024;
  if ($kb < 1024) return (string)round($kb) . ' KB';
  $mb = $kb / 1024;
  return number_format($mb, 1, '.', '') . ' MB';
}

function list_inbox_pdfs(string $dir, int $limit): array {
  $files = [];
  if (!is_dir($dir)) return $files;
  $dh = opendir($dir);
  if ($dh === false) return $files;

  while (($e = readdir($dh)) !== false) {
    if ($e === '' || $e[0] === '.') continue;
    if (!preg_match('/\.pdf\z/i', $e)) continue;
    $p = $dir . '/' . $e;
    if (!is_file($p)) continue;

    $mtime = @filemtime($p);
    $size = @filesize($p);
    $files[] = [
      'filename' => $e,
      'mtime' => is_int($mtime) ? $mtime : 0,
      'mtime_local' => is_int($mtime) ? format_unix_local_datetime($mtime) : '',
      'size' => is_int($size) ? $size : null,
    ];
  }
  closedir($dh);

  usort($files, static function(array $a, array $b): int {
    $cmp = ((int)$b['mtime']) <=> ((int)$a['mtime']);
    return $cmp !== 0 ? $cmp : strcmp((string)$b['filename'], (string)$a['filename']);
  });
  if (count($files) > $limit) $files = array_slice($files, 0, $limit);
  return $files;
}

function summarize_inbox_pdfs(string $dir): array {
  $count = 0;
  $latest = 0;
  if (!is_dir($dir)) return ['count' => 0, 'latest_mtime' => 0];
  $dh = opendir($dir);
  if ($dh === false) return ['count' => 0, 'latest_mtime' => 0];

  while (($e = readdir($dh)) !== false) {
    if ($e === '' || $e[0] === '.') continue;
    if (!preg_match('/\.pdf\z/i', $e)) continue;
    $p = $dir . '/' . $e;
    if (!is_file($p)) continue;
    $count++;
    $mtime = @filemtime($p);
    if (is_int($mtime) && $mtime > $latest) $latest = $mtime;
  }
  closedir($dh);
  return ['count' => $count, 'latest_mtime' => $latest];
}

function inbox_badge_class(int $count): string {
  return $count > 0 ? 'warn' : 'ok';
}

function format_incoming_fax_stamp(string $datePart, string $timePart): string {
  $dt = DateTimeImmutable::createFromFormat('!Ymd His', $datePart . ' ' . $timePart, new DateTimeZone('Europe/Berlin'));
  if (!$dt) return '';
  return $dt->format('d.m.Y H:i:s');
}

function parse_incoming_fax_filename(string $filename): array {
  $out = [
    'datetime_local' => '',
    'number_raw' => '',
    'number_norm' => '',
    'counter' => '',
  ];

  if (!preg_match('/\A(\d{8})-(\d{6})_([0-9+]+)_([^\/]+)\.pdf\z/i', $filename, $m)) {
    return $out;
  }

  $out['datetime_local'] = format_incoming_fax_stamp($m[1], $m[2]);
  $out['number_raw'] = (string)$m[3];
  $out['number_norm'] = normalize_fax_number((string)$m[3]);
  $out['counter'] = (string)$m[4];
  return $out;
}

function build_contact_lookup_by_number(array $contacts): array {
  $out = [];
  foreach ($contacts as $c) {
    if (!is_array($c)) continue;
    $norm = normalize_fax_number((string)($c['number'] ?? ''));
    if ($norm === '' || isset($out[$norm])) continue;
    $out[$norm] = $c;
  }
  return $out;
}

function inbox_dir_for_box(string $box): string {
  if ($box === 'fax') return (string)$GLOBALS['DIR_FAX_INBOX'];
  if ($box === 'scan') return (string)$GLOBALS['DIR_SCAN_INBOX'];
  return '';
}

function hhmm_from_iso(?string $iso): string {
  $t = parse_iso_time($iso);
  if ($t === null) return '';
  return date('H:i', $t);
}

function build_active_jobs_payload(array $activePreview): array {
  $out = [];
  foreach ($activePreview as $a) {
    $meta = $a['meta'] ?? null;
    $jid = (string)($a['id'] ?? '');
    $where = (string)($a['where'] ?? '');
    if (!is_array($meta)) $meta = [];

    $recipientName = (string)($meta['recipient']['name'] ?? '');
    $recipientNum  = (string)($meta['recipient']['number'] ?? '');
    $fileOrig      = (string)($meta['source']['filename_original'] ?? '');
    $srcOrig       = (string)($meta['source']['src'] ?? '');
    $status        = (string)($meta['status'] ?? '');

    $startedAt     = (string)($meta['started_at'] ?? '');
    $submittedAt   = (string)($meta['submitted_at'] ?? '');
    $createdAt     = (string)($meta['created_at'] ?? '');

    $live = (isset($meta['live']) && is_array($meta['live'])) ? $meta['live'] : null;

    $progressSent = null;
    $progressTotal = null;
    $progressRaw = '';
    $dialsDone = null;
    $dialsMax = null;
    $dialsRaw = '';
    $state = '';
    $faxstat = '';
    $liveUpdatedAt = '';
    $asteriskFax = null;

    if (is_array($live)) {
      $liveUpdatedAt = (string)($live['updated_at'] ?? '');
      if (isset($live['progress']) && is_array($live['progress'])) {
        if (isset($live['progress']['sent']))  $progressSent  = (int)$live['progress']['sent'];
        if (isset($live['progress']['total'])) $progressTotal = (int)$live['progress']['total'];
        $progressRaw = (string)($live['progress']['raw'] ?? '');
      }
      if (isset($live['dials']) && is_array($live['dials'])) {
        if (isset($live['dials']['done'])) $dialsDone = (int)$live['dials']['done'];
        if (isset($live['dials']['max']))  $dialsMax  = (int)$live['dials']['max'];
        $dialsRaw = (string)($live['dials']['raw'] ?? '');
      }
      $state = (string)($live['state'] ?? '');
      $faxstat = (string)($live['faxstat_status'] ?? '');
      if (isset($live['asterisk_fax']) && is_array($live['asterisk_fax'])) {
        $af = $live['asterisk_fax'];
        $asteriskFax = [
          'active' => (bool)($af['active'] ?? false),
          'updated_at' => (string)($af['updated_at'] ?? ''),
          'connected_at' => (string)($af['connected_at'] ?? ''),
          'elapsed_sec' => isset($af['elapsed_sec']) ? (int)$af['elapsed_sec'] : null,
          'channel' => (string)($af['channel'] ?? ''),
          'session' => isset($af['session']) ? (int)$af['session'] : null,
          'operation' => (string)($af['operation'] ?? ''),
          'state' => (string)($af['state'] ?? ''),
          'last_status' => (string)($af['last_status'] ?? ''),
          'ecm_mode' => (string)($af['ecm_mode'] ?? ''),
          'data_rate' => isset($af['data_rate']) ? (int)$af['data_rate'] : null,
          'image_resolution' => (string)($af['image_resolution'] ?? ''),
          'page_number' => isset($af['page_number']) ? (int)$af['page_number'] : null,
          'total_pages' => isset($af['total_pages']) ? (int)$af['total_pages'] : null,
          'tx_pages' => isset($af['tx_pages']) ? (int)$af['tx_pages'] : null,
          'rx_pages' => isset($af['rx_pages']) ? (int)$af['rx_pages'] : null,
          'file_name' => (string)($af['file_name'] ?? ''),
        ];
      }
    }

    $out[] = [
      'job_id' => $jid,
      'where' => $where,
      'status' => $status,
      'recipient' => ['name' => $recipientName, 'number' => $recipientNum],
      'source' => ['src' => $srcOrig, 'filename_original' => $fileOrig],
      'created_at' => $createdAt,
      'submitted_at' => $submittedAt,
      'started_at' => $startedAt,
      'live' => $live ? [
        'updated_at' => $liveUpdatedAt,
        'progress' => ['sent' => $progressSent, 'total' => $progressTotal, 'raw' => $progressRaw],
        'dials' => ['done' => $dialsDone, 'max' => $dialsMax, 'raw' => $dialsRaw],
        'state' => $state,
        'faxstat_status' => $faxstat,
        'asterisk_fax' => $asteriskFax,
      ] : null,
    ];
  }
  return $out;
}

// -------------------- Grundvalidierung --------------------
try {
  ensure_dir($BASE);
  ensure_dir($DIR_STAGING);
  ensure_dir($DIR_QUEUE);
  ensure_dir($DIR_PROC);
  ensure_dir($DIR_ARCHIVE);
  ensure_dir($DIR_FAIL_IN);
  ensure_dir($DIR_FAIL_REP);
} catch (Throwable $e) {
  http_response_code(500);
  echo "kienzlefax: Verzeichnisse unvollständig: " . h($e->getMessage());
  exit;
}

// -------------------- Downloads --------------------
$download = $_GET['download'] ?? '';
if ($download !== '') {
  $type = $download;
  $src = (string)($_GET['src'] ?? '');
  $file = (string)($_GET['file'] ?? '');

  if ($type === 'srcpdf') {
    if (!isset($GLOBALS['ALLOW_SOURCES'][$src])) { http_response_code(400); echo "Bad src"; exit; }
    if (!filename_is_sendable_pdf($file, $GLOBALS['EXCLUDE_SUFFIXES'], $GLOBALS['EXCLUDE_CONTAINS'])) { http_response_code(400); echo "Bad file"; exit; }
    $path = $GLOBALS['ALLOW_SOURCES'][$src] . '/' . $file;
    if (!within_dir($path, $GLOBALS['ALLOW_SOURCES'][$src])) { http_response_code(400); echo "Bad path"; exit; }
    send_file_pdf($path, $file);
  }

  if ($type === 'inboxpdf') {
    $box = (string)($_GET['box'] ?? '');
    $dir = inbox_dir_for_box($box);
    if ($dir === '') { http_response_code(400); echo "Bad box"; exit; }
    if ($file === '' || $file !== basename($file) || !preg_match('/\.pdf\z/i', $file)) { http_response_code(400); echo "Bad file"; exit; }
    $path = $dir . '/' . $file;
    if (!within_dir($path, $dir)) { http_response_code(400); echo "Bad path"; exit; }
    send_file_pdf($path, $file);
  }

  if ($type === 'okpdf') {
    if ($file === '' || !preg_match('/\.pdf\z/i', $file)) { http_response_code(400); echo "Bad file"; exit; }
    $path = $GLOBALS['DIR_ARCHIVE'] . '/' . $file;
    if (!within_dir($path, $GLOBALS['DIR_ARCHIVE'])) { http_response_code(400); echo "Bad path"; exit; }
    send_file_pdf($path, $file);
  }

  if ($type === 'failedpdf') {
    if ($file === '' || !preg_match('/\.pdf\z/i', $file)) { http_response_code(400); echo "Bad file"; exit; }
    $path = $GLOBALS['DIR_FAIL_REP'] . '/' . $file;
    if (!within_dir($path, $GLOBALS['DIR_FAIL_REP'])) { http_response_code(400); echo "Bad path"; exit; }
    send_file_pdf($path, $file);
  }

  if ($type === 'jsonok') {
    if ($file === '' || !preg_match('/\.json\z/i', $file)) { http_response_code(400); echo "Bad file"; exit; }
    $path = $GLOBALS['DIR_ARCHIVE'] . '/' . $file;
    if (!within_dir($path, $GLOBALS['DIR_ARCHIVE'])) { http_response_code(400); echo "Bad path"; exit; }
    send_file_text($path, $file, 'application/json');
  }

  if ($type === 'jsonfail') {
    if ($file === '' || !preg_match('/\.json\z/i', $file)) { http_response_code(400); echo "Bad file"; exit; }
    $path = $GLOBALS['DIR_FAIL_REP'] . '/' . $file;
    if (!within_dir($path, $GLOBALS['DIR_FAIL_REP'])) { http_response_code(400); echo "Bad path"; exit; }
    send_file_text($path, $file, 'application/json');
  }

  http_response_code(400);
  echo "Bad download type";
  exit;
}

// -------------------- DB --------------------
$pdo = open_db($DB_PATH);
$contacts = get_contacts($pdo);

// -------------------- Flash --------------------
$flash = ['ok' => [], 'err' => []];
function add_ok(string $m): void { $GLOBALS['flash']['ok'][] = $m; }
function add_err(string $m): void { $GLOBALS['flash']['err'][] = $m; }

// -------------------- POST Actions --------------------
$action = (string)($_POST['action'] ?? '');

if ($action === 'create_jobs') {
  $src = (string)($_POST['src'] ?? '');
  $selected = $_POST['files'] ?? [];
  if (!is_array($selected)) $selected = [];

  if (!isset($ALLOW_SOURCES[$src])) {
    add_err("Ungültige Quelle.");
  } else {
    $recipientData = collect_recipients_from_post($pdo);
    $recipients = is_array($recipientData['recipients'] ?? null) ? $recipientData['recipients'] : [];
    foreach (($recipientData['errors'] ?? []) as $err) add_err((string)$err);

    $ecm = isset($_POST['ecm']);
    $res = (string)($_POST['resolution'] ?? 'fine');
    if (!in_array($res, ['fine', 'standard'], true)) $res = 'fine';

    $srcDir = $ALLOW_SOURCES[$src];
    $valid = [];
    foreach ($selected as $fn) {
      $fn = (string)$fn;
      if (!filename_is_sendable_pdf($fn, $EXCLUDE_SUFFIXES, $EXCLUDE_CONTAINS)) continue;
      $path = $srcDir . '/' . $fn;
      if (!within_dir($path, $srcDir)) continue;
      if (is_file($path)) $valid[] = $fn;
    }
    $valid = array_values(array_unique($valid));
    if (count($valid) === 0) add_err("Keine gültigen PDFs ausgewählt.");

    if (count($flash['err']) === 0) {
      $pendingJobs = [];
      $queuedDirs = [];
      $created = 0;
      $removedSources = 0;
      $removeFailed = 0;

      try {
        foreach ($valid as $fn) {
          $srcPath = $srcDir . '/' . $fn;
          if (!within_dir($srcPath, $srcDir) || !is_file($srcPath)) {
            throw new RuntimeException("Quelle nicht gefunden: $fn");
          }

          foreach ($recipients as $recipient) {
            $jobid = make_job_id();
            $jobStagingDir = $DIR_STAGING . '/' . $jobid;
            $jobQueueDir   = $DIR_QUEUE . '/' . $jobid;

            if (is_dir($jobStagingDir) || is_dir($jobQueueDir)) {
              throw new RuntimeException("Jobordner existiert bereits: $jobid");
            }
            if (!mkdir($jobStagingDir, 0775, true) && !is_dir($jobStagingDir)) {
              throw new RuntimeException("Konnte staging-Jobordner nicht anlegen: $jobid");
            }

            $pendingJobs[] = ['staging' => $jobStagingDir, 'queue' => $jobQueueDir];

            $docPath = $jobStagingDir . '/doc.pdf';
            $sourcePath = $jobStagingDir . '/source.pdf';
            if (!copy($srcPath, $docPath)) {
              throw new RuntimeException("Konnte doc.pdf nicht kopieren: $fn");
            }
            if (!copy($srcPath, $sourcePath)) {
              throw new RuntimeException("Konnte source.pdf nicht kopieren: $fn");
            }

            $job = [
              "job_id" => $jobid,
              "created_at" => date('c'),
              "source" => [
                "src" => $src,
                "filename_original" => $fn,
              ],
              "recipient" => [
                "name" => (string)$recipient['name'],
                "number" => (string)$recipient['number'],
              ],
              "options" => [
                "ecm" => $ecm,
                "resolution" => $res,
              ],
              "status" => "queued",
            ];

            json_write_atomic($jobStagingDir . '/job.json', $job);
          }
        }

        foreach ($pendingJobs as $jobDirs) {
          $stagingDir = (string)$jobDirs['staging'];
          $queueDir = (string)$jobDirs['queue'];
          if (!rename($stagingDir, $queueDir)) {
            throw new RuntimeException("Konnte Job nicht in queue verschieben: " . basename($queueDir));
          }
          $queuedDirs[] = $queueDir;
          $created++;
        }

        foreach ($valid as $fn) {
          $srcPath = $srcDir . '/' . $fn;
          if (within_dir($srcPath, $srcDir) && is_file($srcPath) && @unlink($srcPath)) {
            $removedSources++;
          } else {
            $removeFailed++;
          }
        }

        $savedContacts = 0;
        foreach ($recipients as $recipient) {
          if (empty($recipient['save_to_phonebook'])) continue;
          try {
            $cid = isset($recipient['contact_id']) && $recipient['contact_id'] ? (int)$recipient['contact_id'] : null;
            upsert_contact($pdo, $cid, (string)$recipient['name'], (string)$recipient['number'], '');
            $savedContacts++;
          } catch (Throwable $e) {
            add_err("Telefonbuch-Fehler bei Empfänger " . (string)$recipient['label_no'] . ": " . $e->getMessage());
          }
        }
        if ($savedContacts > 0) {
          add_ok("Empfänger im Telefonbuch gespeichert: $savedContacts.");
          $contacts = get_contacts($pdo);
        }

        if ($created > 0) {
          add_ok("✅ Beauftragt: $created Job(s).");
          if ($removedSources > 0) {
            add_ok("📦 Quellen-Datei(en) entfernt: $removedSources. Jeder Job enthält eine eigene source.pdf.");
          }
          if ($removeFailed > 0) {
            add_err("Hinweis: $removeFailed Quellen-Datei(en) konnten nach der Job-Anlage nicht entfernt werden.");
          }

          if ($src === 'sendefehler') {
            $adoptedReports = 0;
            foreach ($valid as $fn) {
              $jsonFn = find_failure_report_for_resend_pdf($fn);
              if ($jsonFn !== null && move_failure_report_to_archive($jsonFn)) $adoptedReports++;
            }
            if ($adoptedReports > 0) {
              add_ok("✅ Fehlerbericht(e) automatisch ins Sendeprotokoll übernommen: $adoptedReports.");
            }
          }
        }
      } catch (Throwable $e) {
        foreach ($pendingJobs as $jobDirs) {
          remove_job_dir_safe((string)$jobDirs['staging'], $DIR_STAGING);
          remove_job_dir_safe((string)$jobDirs['queue'], $DIR_QUEUE);
        }
        foreach ($queuedDirs as $queueDir) {
          remove_job_dir_safe((string)$queueDir, $DIR_QUEUE);
        }
        add_err("Job-Anlage abgebrochen: " . $e->getMessage() . " Originaldateien wurden nicht entfernt.");
      }
    }
  }
}

if ($action === 'pb_save') {
  $id = (int)($_POST['id'] ?? 0);
  $name = trim((string)($_POST['name'] ?? ''));
  $number = trim((string)($_POST['number'] ?? ''));
  $note = trim((string)($_POST['note'] ?? ''));

  $norm = normalize_fax_number($number);

  if ($name === '') add_err("Name fehlt.");
  if ($norm === '') add_err("Nummer fehlt/ungültig.");

  if (count($flash['err']) === 0) {
    try {
      upsert_contact($pdo, $id > 0 ? $id : null, $name, $norm, $note);
      add_ok($id > 0 ? "Kontakt aktualisiert." : "Kontakt angelegt.");
      $contacts = get_contacts($pdo);
    } catch (Throwable $e) {
      add_err("Telefonbuch-Fehler: " . $e->getMessage());
    }
  }
}

if ($action === 'pb_delete') {
  $id = (int)($_POST['id'] ?? 0);
  if ($id > 0) {
    $st = $pdo->prepare("DELETE FROM contacts WHERE id=:id");
    $st->execute([':id' => $id]);
    add_ok("Kontakt gelöscht.");
    $contacts = get_contacts($pdo);
  } else {
    add_err("Ungültige ID.");
  }
}

if ($action === 'delete_source_files') {
  $src = (string)($_POST['src'] ?? '');
  $selected = $_POST['files'] ?? [];
  if (!is_array($selected)) $selected = [];

  if (!isset($ALLOW_SOURCES[$src])) {
    add_err("Ungültige Quelle.");
  } else {
    $srcDir = $ALLOW_SOURCES[$src];
    $deleted = 0;
    foreach ($selected as $fn) {
      $fn = (string)$fn;
      if (!filename_is_sendable_pdf($fn, $EXCLUDE_SUFFIXES, $EXCLUDE_CONTAINS)) continue;
      $path = $srcDir . '/' . $fn;
      if (!within_dir($path, $srcDir)) continue;
      if (!is_file($path)) continue;
      if (@unlink($path)) $deleted++;
    }
    if ($deleted > 0) add_ok("🗑️ Gelöscht: $deleted Datei(en) aus Quelle " . source_label($src) . ".");
    else add_err("Keine Dateien gelöscht (keine Auswahl / keine Rechte).");
  }
}

if ($action === 'fail_cleanup') {
  $op = (string)($_POST['op'] ?? '');
  $selected = $_POST['failjson'] ?? [];
  if (!is_array($selected)) $selected = [];

  $selected = array_values(array_unique(array_map('strval', $selected)));
  if (count($selected) === 0) {
    add_err("Keine Fehler ausgewählt.");
  } elseif (!in_array($op, ['delete', 'adopt'], true)) {
    add_err("Ungültige Aktion.");
  } else {
    $done = 0;
    $moved = 0;
    $deleted = 0;

    foreach ($selected as $jsonFn) {
      if ($jsonFn === '' || !preg_match('/\.json\z/i', $jsonFn)) continue;

      $jsonPath = $DIR_FAIL_REP . '/' . $jsonFn;
      if (!within_dir($jsonPath, $DIR_FAIL_REP)) continue;
      if (!is_file($jsonPath)) continue;

      $pdfFn = '';
      $cand = failed_pdf_for_json($jsonFn);
      if ($cand !== '' && is_file($DIR_FAIL_REP . '/' . $cand)) $pdfFn = $cand;

      if ($op === 'delete') {
        $ok = true;
        if (!@unlink($jsonPath)) $ok = false;
        if ($pdfFn !== '') {
          $pdfPath = $DIR_FAIL_REP . '/' . $pdfFn;
          if (within_dir($pdfPath, $DIR_FAIL_REP) && is_file($pdfPath)) {
            @unlink($pdfPath);
          }
        }
        if ($ok) { $deleted++; $done++; }
      } else { // adopt
        if (move_failure_report_to_archive($jsonFn)) {
          $moved++;
          $done++;
        }
      }
    }

    if ($done <= 0) {
      add_err("Keine Einträge verarbeitet (keine Rechte / Dateien nicht gefunden).");
    } else {
      if ($op === 'delete') add_ok("🗑️ Fehler entfernt: $deleted Eintrag(e).");
      if ($op === 'adopt') add_ok("✅ Übernommen ins Sendeprotokoll: $moved Eintrag(e).");
    }
  }
}

if ($action === 'cancel_job') {
  $jobId = trim((string)($_POST['job_id'] ?? ''));
  $where = trim((string)($_POST['where'] ?? ''));

  if (!validate_job_id($jobId)) {
    add_err("Ungültige Job-ID.");
  } elseif (!in_array($where, ['queue', 'processing'], true)) {
    add_err("Ungültiger Job-Statusbereich.");
  } else {
    $baseDir = ($where === 'queue') ? $DIR_QUEUE : $DIR_PROC;
    $jobDir = $baseDir . '/' . $jobId;

    if (!within_dir($jobDir, $baseDir) || !is_dir($jobDir)) {
      add_err("Job nicht gefunden.");
    } else {
      $jobJsonPath = $jobDir . '/job.json';
      if (!within_dir($jobJsonPath, $jobDir) || !is_file($jobJsonPath)) {
        add_err("job.json fehlt (kann nicht abbrechen).");
      } else {
        $j = read_json_file($jobJsonPath);
        if (!is_array($j)) {
          add_err("job.json ist nicht lesbar (kann nicht abbrechen).");
        } else {
          $j['cancel'] = [
            'requested' => true,
            'requested_at' => date('c'),
          ];
          try {
            json_write_atomic($jobJsonPath, $j);
            add_ok("⛔ Abbruch angefordert: " . $jobId);
          } catch (Throwable $e) {
            add_err("Konnte Abbruch nicht schreiben: " . $e->getMessage());
          }
        }
      }
    }
  }
}

// -------------------- View / Source --------------------
$view = (string)($_GET['view'] ?? '');
$src  = (string)($_GET['src'] ?? $DEFAULT_SOURCE);
if ($view === '' && !isset($ALLOW_SOURCES[$src])) $src = $DEFAULT_SOURCE;

// -------------------- Sidebar Data --------------------
$queueJobs = list_job_dirs($DIR_QUEUE);
$procJobs  = list_job_dirs($DIR_PROC);

function read_job_meta(string $jobDir): ?array {
  return read_json_file($jobDir . '/job.json');
}

$activePreview = [];
foreach (array_reverse($procJobs) as $jid) {
  if (count($activePreview) >= $GLOBALS['MAX_ACTIVE_JOBS']) break;
  $activePreview[] = ['id' => $jid, 'where' => 'processing', 'meta' => read_job_meta($GLOBALS['DIR_PROC'] . '/' . $jid)];
}
foreach (array_reverse($queueJobs) as $jid) {
  if (count($activePreview) >= $GLOBALS['MAX_ACTIVE_JOBS']) break;
  $activePreview[] = ['id' => $jid, 'where' => 'queue', 'meta' => read_job_meta($GLOBALS['DIR_QUEUE'] . '/' . $jid)];
}

$failCount = count_json_files($DIR_FAIL_REP, 999);
$hasFails = ($failCount > 0);
$inboxFaxSummary = summarize_inbox_pdfs($DIR_FAX_INBOX);
$inboxScanSummary = summarize_inbox_pdfs($DIR_SCAN_INBOX);
$inboxFaxCount = (int)$inboxFaxSummary['count'];
$inboxScanCount = (int)$inboxScanSummary['count'];
$inboxTotalCount = $inboxFaxCount + $inboxScanCount;
$inboxLatestMtime = max((int)$inboxFaxSummary['latest_mtime'], (int)$inboxScanSummary['latest_mtime']);

// -------------------- AJAX (Soft Refresh) --------------------
$ajax = (string)($_GET['ajax'] ?? '');
if ($ajax === 'status') {
  $payload = [
    'now' => date('c'),
    'queue_count' => count($queueJobs),
    'processing_count' => count($procJobs),
    'fail_count' => $failCount,
    'inbox_counts' => [
      'fax' => $inboxFaxCount,
      'scan' => $inboxScanCount,
      'total' => $inboxTotalCount,
      'latest_mtime' => $inboxLatestMtime,
    ],
    'active_jobs' => build_active_jobs_payload($activePreview),
  ];
  if ($view === '' && isset($ALLOW_SOURCES[$src])) {
    $payload['source_files'] = build_source_files_payload($src, $ALLOW_SOURCES[$src], $EXCLUDE_SUFFIXES, $EXCLUDE_CONTAINS, $MAX_LIST_FILES);
  }
  header('Content-Type: application/json; charset=utf-8');
  echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
  exit;
}

// -------------------- Contact Map --------------------
$contacts = get_contacts($pdo);
$contactMap = [];
foreach ($contacts as $c) {
  $contactMap[(string)$c['id']] = ['name' => (string)$c['name'], 'number' => (string)$c['number']];
}

?>
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?=h($APP_TITLE)?></title>
  <style>
    :root{
      --bg:#f7f7ff; --card:#fff; --ink:#131a2a; --mut:#566070; --line:#e6e8f0;
      --primary:#2f6df6; --primary2:#1dd3b0; --danger:#ff4d6d; --ok:#18a957; --warn:#ffb020;
      --shadow: 0 10px 30px rgba(18, 34, 64, .08);
      --r:14px;
    }
    body{ margin:0; font-family: system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;
      background: radial-gradient(1200px 600px at 10% 0%, #eef6ff 0%, transparent 60%),
                  radial-gradient(900px 500px at 90% 0%, #e9fff7 0%, transparent 55%),
                  var(--bg);
      color:var(--ink);
      min-height:100vh;
      display:flex;
      flex-direction:column;
    }
    header{ position:sticky; top:0; z-index:10; background: rgba(255,255,255,.85); backdrop-filter: blur(10px); border-bottom:1px solid var(--line); }
    .head-inner{ max-width:1200px; margin:0 auto; padding:14px 16px; display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; }
    .brand{ display:flex; align-items:center; gap:10px; font-weight:800; letter-spacing:.3px; }
    .logo{ width:34px; height:34px; border-radius:10px; background: linear-gradient(135deg, var(--primary) 0%, var(--primary2) 100%); box-shadow: var(--shadow); }
    .kpis{ display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
    .pill{ display:inline-flex; gap:8px; align-items:center; padding:8px 10px; border:1px solid var(--line); border-radius:999px; background:#fff; box-shadow: 0 6px 14px rgba(18,34,64,.04); font-size:14px; text-decoration:none; color:var(--ink); user-select:none; }
    .pill b{ font-variant-numeric: tabular-nums; }

    /* 1.3 Sound-Glocke */
    .pill.bell{ position:relative; padding:8px 12px; cursor:pointer; }
    .pill.bell.off{ opacity:.65; }
    .pill.bell.off::after{
      content:'';
      position:absolute;
      left:10%;
      top:50%;
      width:80%;
      height:5px;               /* dicker Strich */
      background: var(--danger);
      border-radius: 6px;
      transform: translateY(-50%) rotate(-22deg);  /* schräg */
      box-shadow: 0 0 0 1px rgba(255,77,109,.15);
      pointer-events:none;
    }

    .wrap{ max-width:1200px; margin:0 auto; padding:14px 16px 26px; display:grid; grid-template-columns: 260px 1fr; gap:14px; width:100%; flex:1 0 auto; }
    .card{ background:var(--card); border:1px solid var(--line); border-radius:var(--r); box-shadow: var(--shadow); padding:14px; }
    .tabs{ display:flex; flex-wrap:wrap; gap:10px; margin-bottom:12px; }
    .tab{ text-decoration:none; display:inline-flex; align-items:center; gap:8px; padding:10px 12px; border-radius:999px; border:1px solid var(--line); background:#fff; color:var(--ink); font-weight:700; font-size:14px; }
    .tab.active{ border-color:transparent; background: linear-gradient(135deg, rgba(47,109,246,.15) 0%, rgba(29,211,176,.15) 100%); }
    .flash{ border-radius:12px; padding:10px 12px; margin:10px 0; border:1px solid var(--line); font-weight:700; }
    .flash.ok{ background: rgba(24,169,87,.10); }
    .flash.err{ background: rgba(255,77,109,.10); }
    .mut{ color:var(--mut); }
    .mono{ font-family: ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace; font-size:12px; }
    .section-title{ margin:0 0 10px; font-size:18px; }
    .subtle{ background:#fbfbff; border:1px dashed var(--line); border-radius:12px; padding:12px; }
    .list{ list-style:none; padding:0; margin:10px 0 0; }
    .list li{ padding:10px 0; border-top:1px solid var(--line); display:flex; justify-content:space-between; align-items:center; gap:10px; }
    .list li:first-child{ border-top:0; }
    .btn{ display:inline-flex; align-items:center; justify-content:center; gap:10px; padding:12px 14px; border-radius:14px; border:0; cursor:pointer; font-weight:800; letter-spacing:.2px; text-decoration:none; user-select:none; }
    .btn.primary{ background: linear-gradient(135deg, var(--primary) 0%, #4b8bff 100%); color:#fff; box-shadow: 0 14px 26px rgba(47,109,246,.25); }
    .btn.ghost{ background:#fff; border:1px solid var(--line); color:var(--ink); }
    .btn.danger{ background: linear-gradient(135deg, rgba(255,77,109,.95) 0%, rgba(255,77,109,.80) 100%); color:#fff; box-shadow: 0 14px 26px rgba(255,77,109,.20); }
    .btn.small{ padding:10px 12px; border-radius:12px; font-weight:700; box-shadow:none; }
    .btn:disabled{ opacity:.55; cursor:not-allowed; }

    input[type="text"], textarea, select{ width:100%; padding:12px 12px; border:1px solid var(--line); border-radius:12px; font-size:15px; background:#fff; box-sizing:border-box; }
    textarea{ min-height:80px; }
    label{ font-weight:800; font-size:13px; color:var(--mut); display:block; margin:10px 0 6px; }
    .row{ display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:12px; }
    .tbl{ width:100%; border-collapse:collapse; }
    .tbl th,.tbl td{ border-bottom:1px solid var(--line); padding:10px 8px; vertical-align:top; font-size:14px; }
    .tbl th{ color:var(--mut); text-align:left; font-weight:900; }
    .right{ text-align:right; }
    .nowrap{ white-space:nowrap; }

    .ellipsis{
      display:block;
      white-space:nowrap;
      overflow:hidden;
      text-overflow:ellipsis;
      max-width: 520px;
    }
    .ellipsis.sidebar{ max-width: 190px; }
    .ellipsis.fn{ max-width: 520px; }

    .chip{ display:inline-flex; align-items:center; gap:8px; padding:6px 10px; border-radius:999px; border:1px solid var(--line); background:#fff; font-weight:900; font-size:13px; }
    .chip.ok{ background: rgba(24,169,87,.12); }
    .chip.fail{ background: rgba(255,77,109,.12); }
    .chip.warn{ background: rgba(255,176,32,.18); }
    .chip.abort{ background: rgba(255,77,109,.10); border-color: rgba(255,77,109,.55); }
    .inbox-tab-row{ display:inline-flex; align-items:center; gap:6px; }
    .inbox-tab{ gap:8px; }
    .inbox-badges{ display:inline-flex; gap:5px; align-items:center; }
    .inbox-badge{
      display:inline-flex;
      align-items:center;
      justify-content:center;
      min-width:42px;
      padding:4px 7px;
      border-radius:999px;
      border:1px solid var(--line);
      font-size:12px;
      font-weight:950;
      line-height:1;
      font-variant-numeric: tabular-nums;
    }
    .inbox-badge.ok{ background:rgba(24,169,87,.13); color:#116b3a; border-color:rgba(24,169,87,.25); }
    .inbox-badge.warn{ background:rgba(255,176,32,.24); color:#7b4b00; border-color:rgba(255,176,32,.42); }
    .inbox-tab-row .inbox-badge{
      min-width:22px;
      height:22px;
      padding:0 5px;
      font-size:12px;
      box-shadow:0 3px 8px rgba(18,34,64,.05);
    }
    .section-title.with-badges{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
    .section-title .inbox-badge{ font-size:13px; padding:6px 9px; min-width:52px; }

    .stack{ display:grid; gap:10px; }
    .checkline{ display:flex; align-items:flex-end; gap:14px; margin-top:12px; flex-wrap:wrap; }
    .optstack{ display:grid; gap:8px; align-content:start; }
    .optstack label{ margin:0; font-weight:900; color:var(--ink); display:flex; align-items:center; gap:10px; }
    .recipient-head{ display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap; margin-bottom:10px; }
    .recipient-list{ display:grid; gap:10px; }
    .recipient-block{ border:1px solid var(--line); border-radius:12px; background:#fff; padding:12px; }
    .recipient-title-row{ display:flex; justify-content:space-between; align-items:center; gap:12px; }
    .recipient-title{ font-weight:900; }
    .recipient-row{ display:grid; grid-template-columns: minmax(220px, 1fr) minmax(180px, 280px); gap:14px; align-items:end; }
    .inline-check{ margin:10px 0 0; font-weight:900; color:var(--ink); display:flex; align-items:center; gap:10px; }

    .actionrow{
      display:grid;
      grid-template-columns: 1fr 220px auto;
      gap:14px;
      align-items:end;
      margin-top:12px;
      max-width: 860px;
    }

    @keyframes dangerPulse {
      0%   { box-shadow: 0 0 0 rgba(255,77,109,0.0); border-color: var(--danger); transform: translateY(0); }
      50%  { box-shadow: 0 0 26px rgba(255,77,109,0.55); border-color: rgba(255,77,109,0.95); transform: translateY(-1px); }
      100% { box-shadow: 0 0 0 rgba(255,77,109,0.0); border-color: var(--danger); transform: translateY(0); }
    }
    .tab.pulse-danger{
      border-color: var(--danger) !important;
      background: rgba(255,77,109,.08);
      animation: dangerPulse 1.05s ease-in-out infinite;
    }

    .btn.icon-danger{
      padding:6px 8px;
      border-radius:10px;
      border:1px solid rgba(255,77,109,.5);
      background:rgba(255,77,109,.08);
      color:var(--danger);
      font-weight:800;
      box-shadow:none;
      letter-spacing:0;
    }
    .btn.icon-danger:hover{
      background:rgba(255,77,109,.18);
    }

    footer{
      border-top:1px solid var(--line);
      background: rgba(255,255,255,.65);
      backdrop-filter: blur(10px);
      padding: 10px 16px;
      text-align:center;
      color: var(--mut);
      font-size: 12px;
      margin-top:auto;
    }
    footer a{ color:inherit; font-weight:900; text-decoration:none; }
    footer a:hover{ text-decoration:underline; }

    @media (max-width: 820px){
      .wrap{ grid-template-columns: 1fr; }
      .recipient-row, .actionrow, .row{ grid-template-columns: 1fr; }
      .ellipsis.fn{ max-width: 58vw; }
    }
  </style>
</head>
<body>
<header>
  <div class="head-inner">
    <div class="brand">
      <div class="logo"></div>
      <div>
        <div style="font-size:18px; line-height:1;"><?=h($APP_TITLE)?></div>
        <div class="mut" style="font-size:13px; margin-top:3px;">Der ideale Faxserver für Arztpraxen</div>
      </div>
    </div>
    <div class="kpis">
      <a class="pill" href="<?=h($_SERVER['REQUEST_URI'] ?? '/')?>">🔄 refresh</a>
      <span id="soundBell" class="pill bell" title="Fehlerton: an/aus">🔔</span>
      <span class="pill">⏳ queue <b id="kpiQueue"><?=count($queueJobs)?></b></span>
      <span class="pill">⚙️ processing <b id="kpiProc"><?=count($procJobs)?></b></span>
    </div>
  </div>
</header>

<div class="wrap">
  <!-- Sidebar -->
  <div class="card">
    <div class="mut" style="font-size:13px; font-weight:900; margin-bottom:8px;">Bitte wählen:</div>

    <div class="tabs">
      <?php foreach ($SOURCE_DEFS as $sourceDef): ?>
        <?php $t = (string)$sourceDef['id']; ?>
        <a class="tab <?=($view==='' && $src===$t)?'active':''?>" href="?src=<?=h($t)?>">📄 <?=h(source_label($t))?></a>
      <?php endforeach; ?>
      <span class="inbox-tab-row">
      <a id="inboxTab" class="tab inbox-tab <?=($view==='inbox')?'active':''?>" href="?view=inbox" title="Eingänge: Fax <?=$inboxFaxCount?>, Scan <?=$inboxScanCount?>">
        📥 Eingänge
      </a>
        <span class="inbox-badges" aria-label="Eingangszähler">
          <span class="inbox-badge <?=h(inbox_badge_class($inboxFaxCount))?>" data-inbox-count="fax" data-inbox-compact="1" title="Fax-Eingang"><?=h((string)$inboxFaxCount)?></span>
          <span class="inbox-badge <?=h(inbox_badge_class($inboxScanCount))?>" data-inbox-count="scan" data-inbox-compact="1" title="Scan-Eingang"><?=h((string)$inboxScanCount)?></span>
        </span>
      </span>
      <a class="tab <?=($view==='sendelog')?'active':''?>" href="?view=sendelog">✅ Sendeprotokoll</a>
      <a class="tab <?=($view==='phonebook')?'active':''?>" href="?view=phonebook">📇 Telefonbuch</a>
      <a id="failTab" class="tab <?=($view==='sendefehler-berichte')?'active':''?> <?=($hasFails ? 'pulse-danger' : '')?>" href="?view=sendefehler-berichte" title="Fehlerberichte (<?=$failCount?>)">⚠️ Fehlerberichte</a>
    </div>

    <?php foreach ($flash['ok'] as $m): ?><div class="flash ok"><?=h($m)?></div><?php endforeach; ?>
    <?php foreach ($flash['err'] as $m): ?><div class="flash err"><?=h($m)?></div><?php endforeach; ?>

    <div class="subtle">
      <div style="display:flex; justify-content:space-between; align-items:center; gap:10px;">
        <div>
          <div style="font-weight:900;">Aktive Jobs</div>
          <div class="mut" style="font-size:13px;">Queue & Processing (letzte <?=h((string)$MAX_ACTIVE_JOBS)?>)</div>
        </div>
        <span class="chip warn">live</span>
      </div>

      <ul class="list" id="activeJobsList">
        <?php if (count($activePreview) === 0): ?>
          <li><span class="mut">Keine aktiven Jobs</span></li>
        <?php else: ?>
          <?php foreach ($activePreview as $a): ?>
            <?php
              $meta = $a['meta'] ?? null;
              if (!is_array($meta)) $meta = [];
              $jid = (string)$a['id'];
              $where = (string)$a['where'];

              $rName = (string)($meta['recipient']['name'] ?? '');
              $rNum  = (string)($meta['recipient']['number'] ?? '');
              $file  = (string)($meta['source']['filename_original'] ?? '');

              $createdAt = (string)($meta['created_at'] ?? '');
              $submittedAt = (string)($meta['submitted_at'] ?? '');
              $startedAt = (string)($meta['started_at'] ?? '');

              $live = (isset($meta['live']) && is_array($meta['live'])) ? $meta['live'] : null;

              $sent = null; $total = null; $done = null; $max = null;
              $faxstat = ''; $state = '';
              $af = null;
              if (is_array($live)) {
                if (isset($live['progress']) && is_array($live['progress'])) {
                  if (isset($live['progress']['sent'])) $sent = (int)$live['progress']['sent'];
                  if (isset($live['progress']['total'])) $total = (int)$live['progress']['total'];
                }
                if (isset($live['dials']) && is_array($live['dials'])) {
                  if (isset($live['dials']['done'])) $done = (int)$live['dials']['done'];
                  if (isset($live['dials']['max'])) $max = (int)$live['dials']['max'];
                }
                $faxstat = (string)($live['faxstat_status'] ?? '');
                $state = (string)($live['state'] ?? '');
                $af = (isset($live['asterisk_fax']) && is_array($live['asterisk_fax'])) ? $live['asterisk_fax'] : null;
              }

              $line2 = '';
              if (is_array($af) && !empty($af['active'])) {
                $page = isset($af['page_number']) ? (int)$af['page_number'] : null;
                $totalPages = isset($af['total_pages']) ? (int)$af['total_pages'] : null;
                $elapsed = isset($af['elapsed_sec']) ? (int)$af['elapsed_sec'] : null;
                if ($elapsed === null && !empty($af['connected_at'])) {
                  $t0 = parse_iso_time((string)$af['connected_at']);
                  if ($t0 !== null) $elapsed = max(0, time() - $t0);
                }
                $pageText = ($page !== null && $totalPages !== null) ? ($page . '/' . $totalPages) : (($page !== null) ? (string)$page : (($totalPages !== null) ? ('1/' . $totalPages) : 'läuft'));
                $parts = ['Sende: ' . $pageText];
                $dur = format_hms_compact($elapsed);
                if ($dur !== '') $parts[] = $dur;
                $line2 = implode(' · ', $parts);
              } elseif ($where === 'processing' && $sent !== null && $total !== null) {
                $line2 = 'Sende: ' . $sent . '/' . $total;
              } elseif ($where === 'queue') {
                $hm = hhmm_from_iso($createdAt);
                $line2 = 'queued' . ($hm !== '' ? (' · erstellt ' . $hm) : '');
              } else {
                $line2 = ($where !== '' ? $where : 'aktiv');
              }

              $tooltip1 = trim("Fax: $rNum\nDatei: $file\nJob: $jid");
              $tooltip2 = $line2;
              if (is_array($af) && !empty($af['active'])) {
                $tips = [];
                if (!empty($af['state']) || !empty($af['last_status'])) $tips[] = 'Status: ' . trim((string)($af['state'] ?? '') . ' / ' . (string)($af['last_status'] ?? ''), ' /');
                if (!empty($af['session'])) $tips[] = 'Session: ' . (string)$af['session'];
                if (!empty($af['channel'])) $tips[] = 'Kanal: ' . (string)$af['channel'];
                if (!empty($af['connected_at'])) $tips[] = 'Callzeit: ' . format_hms_compact(isset($af['elapsed_sec']) ? (int)$af['elapsed_sec'] : null);
                if (!empty($af['data_rate'])) $tips[] = 'Datenrate: ' . (string)$af['data_rate'] . ' bit/s';
                if (!empty($af['file_name'])) $tips[] = 'TIFF: ' . (string)$af['file_name'];
                if (!empty($af['updated_at'])) $tips[] = 'Update: ' . (string)$af['updated_at'];
                if (count($tips) > 0) $tooltip2 = $line2 . "\n" . implode("\n", $tips);
              } elseif ($where === 'processing') {
                $parts = [];
                if ($sent !== null && $total !== null) $parts[] = "Sende: $sent/$total";
                if ($submittedAt !== '') $parts[] = "submitted";
                if ($done !== null && $max !== null) $parts[] = "Versuch $done/$max";
                if ($state !== '') $parts[] = "state $state";
                $tooltip2 = implode(' · ', array_merge($parts, [$where]));
                if ($faxstat !== '') $tooltip2 .= "\n" . $faxstat;
              }
            ?>
            <li>
              <div style="min-width:0;">
                <div style="font-weight:900;">
                  <span class="ellipsis sidebar" title="<?=h($tooltip1)?>"><?=h($rName !== '' ? $rName : '—')?></span>
                </div>
                <div class="mut" style="font-size:13px; margin-top:2px;">
                  <span class="ellipsis sidebar"
                        title="<?=h($tooltip2)?>"
                        data-started-at="<?=h($startedAt)?>"
                        data-submitted-at="<?=h($submittedAt)?>"
                        data-where="<?=h($where)?>"><?=h($line2)?></span>
                </div>
              </div>

              <div style="display:flex; align-items:center; gap:8px;">
                <form method="post" style="display:inline;" onsubmit="return confirm('Job wirklich abbrechen?');">
                  <input type="hidden" name="action" value="cancel_job">
                  <input type="hidden" name="job_id" value="<?=h($jid)?>">
                  <input type="hidden" name="where" value="<?=h($where)?>">
                  <button class="btn icon-danger" type="submit" title="Abbruch anfordern">⛔</button>
                </form>
              </div>
            </li>
          <?php endforeach; ?>
        <?php endif; ?>
      </ul>
    </div>

    <div class="mut" style="font-size:13px; margin-top:12px;">
      <b>Hinweis:</b> Fehler erneut senden: Tab <b><?=h(source_label('sendefehler'))?></b> öffnen und dort beauftragen.
    </div>
  </div>

  <!-- Main -->
  <div class="card">
    <?php if ($view === 'phonebook'): ?>
      <?php $edit_id = (int)($_GET['edit'] ?? 0); $edit = $edit_id ? get_contact($pdo, $edit_id) : null; ?>

      <h2 class="section-title">📇 Telefonbuch</h2>

      <div class="row">
        <div class="subtle">
          <div style="font-weight:900; font-size:16px;"><?= $edit ? 'Kontakt bearbeiten' : 'Neuer Kontakt' ?></div>

          <form method="post" class="stack">
            <input type="hidden" name="action" value="pb_save">
            <input type="hidden" name="id" value="<?= $edit ? (int)$edit['id'] : 0 ?>">

            <label>Name</label>
            <input type="text" name="name" value="<?=h($edit['name'] ?? '')?>" placeholder="z.B. Radiologie XY">

            <label>Faxnummer</label>
            <input type="text" name="number" value="<?=h($edit['number'] ?? '')?>" placeholder="z.B. 02331... (wird normalisiert)">

            <label>Notiz</label>
            <textarea name="note" placeholder="optional"><?=h($edit['note'] ?? '')?></textarea>

            <div class="checkline">
              <button class="btn primary" type="submit">💾 Speichern</button>
              <a class="btn ghost" href="?view=phonebook">➕ Neu</a>
            </div>
          </form>
        </div>

        <div>
          <div style="font-weight:900; font-size:16px; margin-bottom:8px;">Kontakte</div>
          <table class="tbl">
            <thead><tr><th>Name</th><th>Nummer</th><th class="right">Aktion</th></tr></thead>
            <tbody>
              <?php if (count($contacts) === 0): ?>
                <tr><td colspan="3" class="mut">Noch keine Kontakte.</td></tr>
              <?php else: ?>
                <?php foreach ($contacts as $c): ?>
                  <tr>
                    <td><?=h($c['name'])?></td>
                    <td class="mono"><?=h($c['number'])?></td>
                    <td class="right nowrap">
                      <a class="btn ghost small" href="?view=phonebook&amp;edit=<?=(int)$c['id']?>">✏️ Bearbeiten</a>
                      <form method="post" style="display:inline;" onsubmit="return confirm('Kontakt wirklich löschen?');">
                        <input type="hidden" name="action" value="pb_delete">
                        <input type="hidden" name="id" value="<?=(int)$c['id']?>">
                        <button class="btn ghost small" type="submit">🗑️ Löschen</button>
                      </form>
                    </td>
                  </tr>
                <?php endforeach; ?>
              <?php endif; ?>
            </tbody>
          </table>
        </div>
      </div>

    <?php elseif ($view === 'inbox'): ?>
      <?php
        $faxItems = list_inbox_pdfs($DIR_FAX_INBOX, $MAX_INBOX_LIST);
        $scanItems = list_inbox_pdfs($DIR_SCAN_INBOX, $MAX_INBOX_LIST);
        $contactByNumber = build_contact_lookup_by_number($contacts);
        $faxCount = $inboxFaxCount;
        $scanCount = $inboxScanCount;
      ?>

      <h2 class="section-title with-badges">
        <span>📥 Eingänge</span>
        <span class="inbox-badges" aria-label="Eingangszähler">
          <span class="inbox-badge <?=h(inbox_badge_class($faxCount))?>" data-inbox-count="fax" title="Fax-Eingang"><?=h('Fax ' . (string)$faxCount)?></span>
          <span class="inbox-badge <?=h(inbox_badge_class($scanCount))?>" data-inbox-count="scan" title="Scan-Eingang"><?=h('Scan ' . (string)$scanCount)?></span>
        </span>
      </h2>

      <div class="stack">
        <div class="subtle">
          <div style="display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap;">
            <div>
              <div style="font-weight:900; font-size:16px;">Fax-Eingang</div>
              <div class="mut mono" style="margin-top:3px;"><?=h($DIR_FAX_INBOX)?></div>
            </div>
            <span class="chip <?=($faxCount > 0) ? 'warn' : 'ok'?>"><?=h((string)$faxCount)?> Datei<?=($faxCount === 1) ? '' : 'en'?></span>
          </div>

          <table class="tbl" style="margin-top:10px;">
            <thead>
              <tr><th>Datei</th><th class="nowrap">Datum/Uhrzeit</th><th>Absender</th><th class="nowrap">Größe</th><th class="right nowrap">Dokument</th></tr>
            </thead>
            <tbody>
            <?php if (!is_dir($DIR_FAX_INBOX)): ?>
              <tr><td colspan="5" class="mut">Verzeichnis nicht vorhanden oder nicht lesbar.</td></tr>
            <?php elseif ($faxCount === 0): ?>
              <tr><td colspan="5" class="mut">Keine nicht weggeräumten Fax-PDFs gefunden.</td></tr>
            <?php else: ?>
              <?php foreach ($faxItems as $it): ?>
                <?php
                  $fn = (string)$it['filename'];
                  $parsed = parse_incoming_fax_filename($fn);
                  $timeDisplay = (string)$parsed['datetime_local'];
                  if ($timeDisplay === '') $timeDisplay = (string)$it['mtime_local'];
                  $numRaw = (string)$parsed['number_raw'];
                  $numNorm = (string)$parsed['number_norm'];
                  $contact = ($numNorm !== '' && isset($contactByNumber[$numNorm])) ? $contactByNumber[$numNorm] : null;
                  $senderName = is_array($contact) ? (string)($contact['name'] ?? '') : '';
                ?>
                <tr>
                  <td style="font-weight:900;"><span class="ellipsis fn" title="<?=h($fn)?>"><?=h($fn)?></span></td>
                  <td class="nowrap" title="<?=h($parsed['datetime_local'] !== '' ? 'aus Dateiname' : 'Dateizeit')?>"><?=h($timeDisplay !== '' ? $timeDisplay : '—')?></td>
                  <td>
                    <div style="font-weight:900;"><?=h($senderName !== '' ? $senderName : (($numRaw !== '') ? 'Nicht im Telefonbuch' : '—'))?></div>
                    <div class="mono mut"><?=h($numRaw !== '' ? $numRaw : '—')?></div>
                  </td>
                  <td class="nowrap"><?=h(format_size($it['size']))?></td>
                  <td class="right nowrap"><a class="btn ghost small" href="?download=inboxpdf&amp;box=fax&amp;file=<?=h(rawurlencode($fn))?>">📄 PDF</a></td>
                </tr>
              <?php endforeach; ?>
            <?php endif; ?>
            </tbody>
          </table>
        </div>

        <div class="subtle">
          <div style="display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap;">
            <div>
              <div style="font-weight:900; font-size:16px;">Scan-Eingang</div>
              <div class="mut mono" style="margin-top:3px;"><?=h($DIR_SCAN_INBOX)?></div>
            </div>
            <span class="chip <?=($scanCount > 0) ? 'warn' : 'ok'?>"><?=h((string)$scanCount)?> Datei<?=($scanCount === 1) ? '' : 'en'?></span>
          </div>

          <table class="tbl" style="margin-top:10px;">
            <thead>
              <tr><th>Datei</th><th class="nowrap">Geändert</th><th class="nowrap">Größe</th><th class="right nowrap">Dokument</th></tr>
            </thead>
            <tbody>
            <?php if (!is_dir($DIR_SCAN_INBOX)): ?>
              <tr><td colspan="4" class="mut">Verzeichnis nicht vorhanden oder nicht lesbar.</td></tr>
            <?php elseif ($scanCount === 0): ?>
              <tr><td colspan="4" class="mut">Keine nicht weggeräumten Scan-PDFs gefunden.</td></tr>
            <?php else: ?>
              <?php foreach ($scanItems as $it): ?>
                <?php $fn = (string)$it['filename']; ?>
                <tr>
                  <td style="font-weight:900;"><span class="ellipsis fn" title="<?=h($fn)?>"><?=h($fn)?></span></td>
                  <td class="nowrap"><?=h((string)$it['mtime_local'] !== '' ? (string)$it['mtime_local'] : '—')?></td>
                  <td class="nowrap"><?=h(format_size($it['size']))?></td>
                  <td class="right nowrap"><a class="btn ghost small" href="?download=inboxpdf&amp;box=scan&amp;file=<?=h(rawurlencode($fn))?>">📄 PDF</a></td>
                </tr>
              <?php endforeach; ?>
            <?php endif; ?>
            </tbody>
          </table>
        </div>
      </div>

    <?php elseif ($view === 'sendelog'): ?>
      <?php
        $showAll = isset($_GET['all']) && ((string)$_GET['all'] === '1');
        $limit = $showAll ? 500 : $MAX_ARCHIVE_LIST;
      ?>
      <div style="display:flex; justify-content:space-between; align-items:end; gap:12px; flex-wrap:wrap;">
        <h2 class="section-title" style="margin:0;">✅ Sendeprotokoll (letzte <?=$showAll ? $limit : $MAX_ARCHIVE_LIST?>)</h2>
        <div>
          <?php if (!$showAll): ?>
            <a class="btn ghost small" href="?view=sendelog&amp;all=1">alle anzeigen</a>
          <?php else: ?>
            <a class="btn ghost small" href="?view=sendelog">nur letzte <?=$MAX_ARCHIVE_LIST?></a>
          <?php endif; ?>
        </div>
      </div>

      <?php
        $items = [];
        if (is_dir($DIR_ARCHIVE)) {
          $dh = opendir($DIR_ARCHIVE);
          if ($dh !== false) {
            while (($e = readdir($dh)) !== false) {
              if (!preg_match('/\.json\z/i', $e)) continue;
              $p = $DIR_ARCHIVE . '/' . $e;
              if (!is_file($p)) continue;
              $raw = @file_get_contents($p);
              if ($raw === false) continue;
              $j = json_decode($raw, true);
              if (!is_array($j)) continue;
              $end = (string)($j['end_time'] ?? $j['completed_at'] ?? $j['updated_at'] ?? '');
              $ts = parse_iso_time($end) ?? 0;
              $items[] = ['json' => $e, 'data' => $j, 'ts' => $ts];
            }
            closedir($dh);
          }
        }
        usort($items, fn($a,$b) => $b['ts'] <=> $a['ts']);
        $items = array_slice($items, 0, $limit);
      ?>

      <table class="tbl">
        <thead>
          <tr>
            <th>Ergebnis</th><th>Ende</th><th>Empfänger</th><th>Dauer</th><th>Seiten</th><th class="right nowrap">Dokument</th>
          </tr>
        </thead>
        <tbody>
        <?php if (count($items) === 0): ?>
          <tr><td colspan="6" class="mut">Noch keine Archiv-JSONs gefunden.</td></tr>
        <?php else: ?>
          <?php foreach ($items as $it): ?>
            <?php
              $j = $it['data'];
              $end = (string)($j['end_time'] ?? $j['completed_at'] ?? $j['updated_at'] ?? '');
              $start = (string)($j['started_at'] ?? '');
              $name = (string)($j['recipient']['name'] ?? '');
              $num = (string)($j['recipient']['number'] ?? '');
              $status = (string)($j['status'] ?? '');

              $aborted = is_aborted_job($j);
              $isOk = (strcasecmp($status, 'OK') === 0) || (stripos($status, 'ok') !== false);

              $dur = '';
              $txSec = extract_transmission_duration_sec($j);
              if ($txSec !== null) {
                $dur = format_duration($txSec);
              } else {
                $t1 = parse_iso_time($start);
                $t2 = parse_iso_time($end);
                if ($t1 !== null && $t2 !== null) $dur = format_duration($t2 - $t1);
              }

              $pages = extract_pages($j);

              $pdf = '';
              if (preg_match('/\A(.+)\.json\z/i', $it['json'], $m)) {
                $stem = $m[1];
                $cand = $stem . '__OK.pdf';
                if (is_file($DIR_ARCHIVE . '/' . $cand)) $pdf = $cand;
              }
            ?>
            <tr>
              <td class="nowrap">
                <?php if ($aborted): ?><span class="chip abort">⛔ Abgebrochen</span>
                <?php elseif ($isOk): ?><span class="chip ok">✅ Senden erfolgreich</span>
                <?php else: ?><span class="chip fail">❌ Fehlgeschlagen</span><?php endif; ?>
              </td>
              <td class="nowrap" title="<?=h($end)?>"><?=h(format_local_datetime($end))?></td>
              <td><div style="font-weight:900;"><?=h($name)?></div><div class="mono mut"><?=h($num)?></div></td>
              <td class="nowrap"><?=h($dur ?: '—')?></td>
              <td class="nowrap"><?=h($pages ?: '—')?></td>
              <td class="right nowrap">
                <?php if ($pdf !== ''): ?><a class="btn ghost small" href="?download=okpdf&amp;file=<?=h($pdf)?>">📄 PDF</a><?php else: ?><span class="mut">—</span><?php endif; ?>
                <a class="btn ghost small" href="?download=jsonok&amp;file=<?=h($it['json'])?>">🧾 JSON</a>
              </td>
            </tr>
          <?php endforeach; ?>
        <?php endif; ?>
        </tbody>
      </table>

    <?php elseif ($view === 'sendefehler-berichte'): ?>
      <h2 class="section-title">⚠️ Sendefehler-Berichte</h2>

      <div class="subtle" style="margin-bottom:10px;">
        <div style="font-weight:900;">Erneut senden?</div>
        <div class="mut" style="margin-top:6px;">
          Bitte die Original-PDF im Tab <b><?=h(source_label('sendefehler'))?></b> auswählen und neu beauftragen.
        </div>
        <div class="checkline">
          <a class="btn primary" href="?src=sendefehler">↩️ Zum erneuten Senden (<?=h(source_label('sendefehler'))?>)</a>
        </div>
      </div>

      <?php
        $fails = [];
        if (is_dir($DIR_FAIL_REP)) {
          $dh = opendir($DIR_FAIL_REP);
          if ($dh !== false) {
            while (($e = readdir($dh)) !== false) {
              if (!preg_match('/\.json\z/i', $e)) continue;
              $p = $DIR_FAIL_REP . '/' . $e;
              if (!is_file($p)) continue;
              $raw = @file_get_contents($p);
              if ($raw === false) continue;
              $j = json_decode($raw, true);
              if (!is_array($j)) continue;
              $t = (string)($j['end_time'] ?? $j['updated_at'] ?? $j['created_at'] ?? '');
              $ts = parse_iso_time($t) ?? 0;
              $fails[] = ['json' => $e, 'data' => $j, 'ts' => $ts];
            }
            closedir($dh);
          }
        }
        usort($fails, fn($a,$b) => $b['ts'] <=> $a['ts']);
        $fails = array_slice($fails, 0, $MAX_FAIL_LIST);
      ?>

      <form method="post" class="stack">
        <input type="hidden" name="action" value="fail_cleanup">

        <div class="checkline" style="align-items:center;">
          <button class="btn danger" type="submit" name="op" value="delete" onclick="return confirm('Ausgewählte Fehler wirklich löschen?');">🗑️ Ausgewählte löschen</button>
          <button class="btn ghost" type="submit" name="op" value="adopt" onclick="return confirm('Ausgewählte Fehler ins Sendeprotokoll übernehmen?');">✅ Fehler in Sendeprotokoll übernehmen</button>
        </div>

        <table class="tbl">
          <thead><tr><th class="nowrap"></th><th>Ergebnis</th><th>Zeit</th><th>Empfänger</th><th>Fehler</th><th class="right nowrap">Artefakte</th></tr></thead>
          <tbody>
          <?php if (count($fails) === 0): ?>
            <tr><td colspan="6" class="mut">Keine Fehler-JSONs gefunden.</td></tr>
          <?php else: ?>
            <?php foreach ($fails as $it): ?>
              <?php
                $j = $it['data'];
                $t = (string)($j['end_time'] ?? $j['updated_at'] ?? $j['created_at'] ?? '');
                $name = (string)($j['recipient']['name'] ?? '');
                $num = (string)($j['recipient']['number'] ?? '');

                $aborted = is_aborted_job($j);

                $err = '';
                if (isset($j['result']) && is_array($j['result'])) {
                  $err = (string)($j['result']['error_message'] ?? $j['result']['stderr'] ?? '');
                  if ($err === '') $err = (string)($j['result']['reason'] ?? $j['result']['status_text'] ?? '');
                }
                if ($err === '') $err = (string)($j['error'] ?? $j['error_message'] ?? 'FAILED');

                $pdf = '';
                if (preg_match('/\A(.+)\.json\z/i', $it['json'], $m)) {
                  $stem = $m[1];
                  $cand = $stem . '__FAILED.pdf';
                  if (is_file($DIR_FAIL_REP . '/' . $cand)) $pdf = $cand;
                }
              ?>
              <tr>
                <td class="nowrap"><input type="checkbox" name="failjson[]" value="<?=h($it['json'])?>"></td>
                <td class="nowrap">
                  <?php if ($aborted): ?><span class="chip abort">⛔ Abgebrochen</span>
                  <?php else: ?><span class="chip fail">❌ Fehlgeschlagen</span><?php endif; ?>
                </td>
                <td class="nowrap"><?=h($t)?></td>
                <td><div style="font-weight:900;"><?=h($name)?></div><div class="mono mut"><?=h($num)?></div></td>
                <td><?=h($err ?: '—')?></td>
                <td class="right nowrap">
                  <?php if ($pdf !== ''): ?><a class="btn ghost small" href="?download=failedpdf&amp;file=<?=h($pdf)?>">📄 PDF</a><?php else: ?><span class="mut">—</span><?php endif; ?>
                  <a class="btn ghost small" href="?download=jsonfail&amp;file=<?=h($it['json'])?>">🧾 JSON</a>
                </td>
              </tr>
            <?php endforeach; ?>
          <?php endif; ?>
          </tbody>
        </table>
      </form>

    <?php else: ?>
      <?php
        $srcDir = $ALLOW_SOURCES[$src];
        $pdfs = list_source_pdfs($srcDir, $EXCLUDE_SUFFIXES, $EXCLUDE_CONTAINS, $MAX_LIST_FILES);
        $srcLabel = source_label($src);
      ?>

      <h2 class="section-title">📄 Quelle: <?=h($srcLabel)?></h2>

      <form method="post" class="stack">
        <input type="hidden" name="action" value="create_jobs">
        <input type="hidden" name="src" value="<?=h($src)?>">

        <div class="subtle recipient-limits">
          <div class="recipient-head">
            <div style="font-weight:900; font-size:16px;">Empfänger</div>
            <button class="btn ghost small" type="button" id="addRecipientBtn">➕ Weiteren Empfänger hinzufügen</button>
          </div>

          <div id="recipientsList" class="recipient-list">
            <div class="recipient-block" data-recipient-index="0">
              <div class="recipient-title-row">
                <div class="recipient-title">Empfänger 1</div>
                <button class="btn ghost small recipient-remove" type="button" data-role="remove-recipient" style="display:none;">Entfernen</button>
              </div>

              <label>Telefonbuch (optional)</label>
              <select name="recipients[0][contact_id]" data-role="contact">
                <option value="">— Kontakt wählen —</option>
                <?php foreach ($contacts as $c): ?>
                  <option value="<?=(int)$c['id']?>"><?=h($c['name'])?> · <?=h($c['number'])?></option>
                <?php endforeach; ?>
              </select>

              <div class="recipient-row">
                <div>
                  <label>Empfängername</label>
                  <input type="text" name="recipients[0][name]" data-role="name" placeholder="z.B. Radiologie XY">
                </div>
                <div>
                  <label>Faxnummer</label>
                  <input type="text" name="recipients[0][number]" data-role="number" placeholder="z.B. 02331...">
                </div>
              </div>

              <label class="inline-check">
                <input type="checkbox" name="recipients[0][save_to_phonebook]" value="1" data-role="save">
                Im Telefonbuch speichern
              </label>
            </div>
          </div>

          <div class="actionrow">
            <div class="optstack">
              <label>
                <input type="checkbox" name="ecm" checked>
                ECM
              </label>
            </div>

            <div>
              <label style="margin:0 0 6px;">Auflösung</label>
              <select name="resolution">
                <option value="fine" selected>fine</option>
                <option value="standard">standard</option>
              </select>
            </div>

            <button class="btn primary" type="submit">🚀 Fax beauftragen</button>
          </div>

          <div class="mut" style="font-size:13px; margin-top:10px;">
            Kontakt auswählen → Felder werden übernommen (du kannst danach ändern).
          </div>
        </div>

        <template id="recipientTemplate">
          <div class="recipient-block" data-recipient-index="">
            <div class="recipient-title-row">
              <div class="recipient-title">Empfänger</div>
              <button class="btn ghost small recipient-remove" type="button" data-role="remove-recipient">Entfernen</button>
            </div>

            <label>Telefonbuch (optional)</label>
            <select data-role="contact">
              <option value="">— Kontakt wählen —</option>
              <?php foreach ($contacts as $c): ?>
                <option value="<?=(int)$c['id']?>"><?=h($c['name'])?> · <?=h($c['number'])?></option>
              <?php endforeach; ?>
            </select>

            <div class="recipient-row">
              <div>
                <label>Empfängername</label>
                <input type="text" data-role="name" placeholder="z.B. Radiologie XY">
              </div>
              <div>
                <label>Faxnummer</label>
                <input type="text" data-role="number" placeholder="z.B. 02331...">
              </div>
            </div>

            <label class="inline-check">
              <input type="checkbox" value="1" data-role="save">
              Im Telefonbuch speichern
            </label>
          </div>
        </template>

        <div class="subtle">
          <div style="display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap;">
            <div>
              <div style="font-weight:900; font-size:16px;">PDF-Auswahl</div>
              <div class="mut" style="font-size:13px;">Mehrfachauswahl möglich</div>
            </div>
            <div class="checkline" style="margin:0;">
              <button type="button" class="btn ghost small" onclick="selectAll(true)">✅ Alle</button>
              <button type="button" class="btn ghost small" onclick="selectAll(false)">🧹 Keine</button>
              <button type="submit" class="btn danger small" formaction="" onclick="return confirm('Ausgewählte PDFs wirklich löschen?');"
                      name="action" value="delete_source_files">🗑️ löschen</button>
            </div>
          </div>

          <table class="tbl" style="margin-top:10px;">
            <thead><tr><th class="nowrap"></th><th>Datei</th><th class="nowrap">Größe</th><th class="right nowrap">Vorschau</th></tr></thead>
            <tbody id="sourceFilesBody">
            <?php if (count($pdfs) === 0): ?>
              <tr><td colspan="4" class="mut">Keine sendbaren PDFs gefunden.</td></tr>
            <?php else: ?>
              <?php foreach ($pdfs as $fn): ?>
                <?php
                  $p = $srcDir . '/' . $fn;
                  $sz = is_file($p) ? filesize($p) : null;
                ?>
                <tr>
                  <td class="nowrap"><input type="checkbox" name="files[]" value="<?=h($fn)?>" class="filebox"></td>
                  <td style="font-weight:900;">
                    <span class="ellipsis fn" title="<?=h($fn)?>"><?=h($fn)?></span>
                  </td>
                  <td class="nowrap"><?=h(format_size(is_int($sz) ? $sz : null))?></td>
                  <td class="right nowrap"><a class="btn ghost small" href="?download=srcpdf&amp;src=<?=h($src)?>&amp;file=<?=h($fn)?>">👁️ PDF</a></td>
                </tr>
              <?php endforeach; ?>
            <?php endif; ?>
            </tbody>
          </table>
        </div>
      </form>

      <script>
        const CONTACTS = <?=json_encode($contactMap, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)?>;
        const recipientList = document.getElementById('recipientsList');
        const recipientTemplate = document.getElementById('recipientTemplate');
        const addRecipientBtn = document.getElementById('addRecipientBtn');

        function recipientBlocks() {
          return Array.from(recipientList.querySelectorAll('.recipient-block'));
        }

        function setRecipientIndex(block, index) {
          block.dataset.recipientIndex = String(index);
          const no = index + 1;
          const title = block.querySelector('.recipient-title');
          if (title) title.textContent = 'Empfänger ' + no;

          const contact = block.querySelector('[data-role="contact"]');
          const name = block.querySelector('[data-role="name"]');
          const number = block.querySelector('[data-role="number"]');
          const save = block.querySelector('[data-role="save"]');

          if (contact) contact.name = 'recipients[' + index + '][contact_id]';
          if (name) name.name = 'recipients[' + index + '][name]';
          if (number) number.name = 'recipients[' + index + '][number]';
          if (save) save.name = 'recipients[' + index + '][save_to_phonebook]';
        }

        function updateRecipientRemoveButtons() {
          recipientBlocks().forEach((block, index) => {
            setRecipientIndex(block, index);
            const remove = block.querySelector('[data-role="remove-recipient"]');
            if (remove) remove.style.display = index === 0 ? 'none' : '';
          });
        }

        function fillRecipientFromContact(block) {
          const sel = block.querySelector('[data-role="contact"]');
          if (!sel) return;
          const id = sel.value;
          if (!id || !CONTACTS[id]) return;

          const nameEl = block.querySelector('[data-role="name"]');
          const numEl = block.querySelector('[data-role="number"]');
          if (nameEl) nameEl.value = CONTACTS[id].name || '';
          if (numEl) numEl.value = CONTACTS[id].number || '';
        }

        if (addRecipientBtn && recipientTemplate && recipientList) {
          addRecipientBtn.addEventListener('click', () => {
            const frag = recipientTemplate.content.cloneNode(true);
            const block = frag.querySelector('.recipient-block');
            recipientList.appendChild(frag);
            if (block) {
              setRecipientIndex(block, recipientBlocks().length - 1);
              const contact = block.querySelector('[data-role="contact"]');
              if (contact) contact.focus();
            }
            updateRecipientRemoveButtons();
          });
        }

        if (recipientList) {
          recipientList.addEventListener('change', (ev) => {
            const target = ev.target;
            if (!target || !target.matches('[data-role="contact"]')) return;
            const block = target.closest('.recipient-block');
            if (block) fillRecipientFromContact(block);
          });

          recipientList.addEventListener('click', (ev) => {
            const btn = ev.target && ev.target.closest('[data-role="remove-recipient"]');
            if (!btn) return;
            const block = btn.closest('.recipient-block');
            if (block) block.remove();
            updateRecipientRemoveButtons();
          });

          updateRecipientRemoveButtons();
        }

        function selectAll(on) {
          document.querySelectorAll('.filebox').forEach(b => b.checked = on);
        }
      </script>

    <?php endif; ?>
  </div>
</div>

<footer>
  <a href="https://kienzlefax.de/" target="_blank" rel="noopener"><?=h($APP_TITLE)?></a> · v<?=h($APP_VERSION)?> · <?=h($APP_AUTHOR)?>
</footer>

<script>
  // 1.4 Live-AJAX (+ Sound): KPIs, aktive Jobs, Fehlerpuls, Eingangszaehler und PDF-Liste der aktuellen Quelle.
  (function(){
    // -------------------- Sound (faxton.mp3) --------------------
    const SOUND_URL = <?=json_encode($ALERT_MP3, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)?>;
    const CURRENT_SRC = <?=json_encode($view === '' ? $src : '', JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)?>;
    const INITIAL_INBOX_COUNTS = <?=json_encode([
      'fax' => $inboxFaxCount,
      'scan' => $inboxScanCount,
      'total' => $inboxTotalCount,
      'latest_mtime' => $inboxLatestMtime,
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)?>;
    const bell = document.getElementById('soundBell');

    function soundEnabled(){
      return localStorage.getItem('kf_sound') !== 'off';
    }
    function setSoundEnabled(on){
      localStorage.setItem('kf_sound', on ? 'on' : 'off');
      if (bell){
        if (on) bell.classList.remove('off');
        else bell.classList.add('off');
      }
    }

    // Init UI state
    setSoundEnabled(soundEnabled());

    if (bell){
      bell.addEventListener('click', () => {
        setSoundEnabled(!soundEnabled());
      });
    }

    // last fail_count (persist)
    let lastFailCount = Number(localStorage.getItem('kf_last_fail_count') || '0');
    if (!Number.isFinite(lastFailCount) || lastFailCount < 0) lastFailCount = 0;

    let lastInboxTotal = Number(INITIAL_INBOX_COUNTS.total || 0);
    if (!Number.isFinite(lastInboxTotal) || lastInboxTotal < 0) lastInboxTotal = 0;
    let lastInboxLatestMtime = Number(INITIAL_INBOX_COUNTS.latest_mtime || 0);
    if (!Number.isFinite(lastInboxLatestMtime) || lastInboxLatestMtime < 0) lastInboxLatestMtime = 0;

    const kpiQueue = document.getElementById('kpiQueue');
    const kpiProc  = document.getElementById('kpiProc');
    const failTab  = document.getElementById('failTab');
    const inboxTab = document.getElementById('inboxTab');
    const listEl   = document.getElementById('activeJobsList');
    const sourceFilesBody = document.getElementById('sourceFilesBody');
    let lastSourceFilesSig = null;

    function pad2(n){ return (n<10?'0':'') + n; }

    // "5:23"-artig (m:ss) oder (h:mm:ss)
    function fmtHMS(sec){
      sec = Math.max(0, Math.floor(sec));
      const h = Math.floor(sec/3600);
      const m = Math.floor((sec%3600)/60);
      const s = sec%60;
      if (h > 0) return h + ':' + pad2(m) + ':' + pad2(s);
      return m + ':' + pad2(s);
    }

    function safeText(s){ return (s===null || s===undefined) ? '' : String(s); }

    function safeNumber(v){
      if (v === null || v === undefined || v === '') return null;
      const n = Number(v);
      return Number.isFinite(n) ? n : null;
    }

    function playSoftInboxBell(){
      if (!soundEnabled()) return;
      try {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (!Ctx) return;
        const ctx = playSoftInboxBell.ctx || (playSoftInboxBell.ctx = new Ctx());
        if (ctx.state === 'suspended') ctx.resume().catch(() => {});
        const now = ctx.currentTime;

        [0, 0.12].forEach((delay, index) => {
          const osc = ctx.createOscillator();
          const gain = ctx.createGain();
          osc.type = 'sine';
          osc.frequency.setValueAtTime(index === 0 ? 880 : 1175, now + delay);
          gain.gain.setValueAtTime(0.0001, now + delay);
          gain.gain.exponentialRampToValueAtTime(0.055, now + delay + 0.018);
          gain.gain.exponentialRampToValueAtTime(0.0001, now + delay + 0.32);
          osc.connect(gain);
          gain.connect(ctx.destination);
          osc.start(now + delay);
          osc.stop(now + delay + 0.34);
        });
      } catch (e) {}
    }

    function updateInboxBadges(counts){
      if (!counts || typeof counts !== 'object') return;
      const fax = safeNumber(counts.fax);
      const scan = safeNumber(counts.scan);
      const total = safeNumber(counts.total);
      const latest = safeNumber(counts.latest_mtime);

      const values = {fax: fax === null ? 0 : fax, scan: scan === null ? 0 : scan};
      document.querySelectorAll('[data-inbox-count]').forEach(el => {
        const kind = el.getAttribute('data-inbox-count');
        if (kind !== 'fax' && kind !== 'scan') return;
        const n = values[kind];
        const compact = el.getAttribute('data-inbox-compact') === '1';
        el.textContent = compact ? String(n) : ((kind === 'fax' ? 'Fax ' : 'Scan ') + String(n));
        el.classList.toggle('warn', n > 0);
        el.classList.toggle('ok', n <= 0);
      });

      if (inboxTab) {
        inboxTab.title = 'Eingänge: Fax ' + values.fax + ', Scan ' + values.scan;
      }

      const nextTotal = total === null ? (values.fax + values.scan) : total;
      const nextLatest = latest === null ? 0 : latest;
      if ((nextTotal > lastInboxTotal || nextLatest > lastInboxLatestMtime) && nextTotal > 0) {
        playSoftInboxBell();
      }

      lastInboxTotal = nextTotal;
      lastInboxLatestMtime = nextLatest;
    }

    function buildAsteriskFaxLine(live, nowMs){
      if (!live || !live.asterisk_fax || !live.asterisk_fax.active) return '';
      const af = live.asterisk_fax;
      const page = safeNumber(af.page_number);
      const total = safeNumber(af.total_pages);
      let elapsed = safeNumber(af.elapsed_sec);

      if (safeText(af.connected_at)) {
        const t0 = Date.parse(safeText(af.connected_at));
        if (!isNaN(t0)) elapsed = Math.max(0, Math.floor((nowMs - t0) / 1000));
      }

      let pageText = 'läuft';
      if (page !== null && total !== null) pageText = String(page) + '/' + String(total);
      else if (page !== null) pageText = String(page);
      else if (total !== null) pageText = '1/' + String(total);

      const parts = ['Sende: ' + pageText];
      if (elapsed !== null) parts.push(fmtHMS(elapsed));
      return parts.join(' · ');
    }

    function buildLine2(job, nowMs){
      const where = safeText(job.where);
      const submitted = safeText(job.submitted_at) !== '';
      const startedAt = safeText(job.started_at);
      const live = job.live || null;

      const asteriskLine = buildAsteriskFaxLine(live, nowMs);
      if (asteriskLine) return asteriskLine;

      if (where === 'processing' && live && live.progress && live.dials) {
        const sent  = (live.progress.sent !== null && live.progress.sent !== undefined) ? live.progress.sent : null;
        const total = (live.progress.total !== null && live.progress.total !== undefined) ? live.progress.total : null;
        const done  = (live.dials.done !== null && live.dials.done !== undefined) ? live.dials.done : null;
        const max   = (live.dials.max !== null && live.dials.max !== undefined) ? live.dials.max : null;

        const parts = [];

        if (sent !== null && total !== null) parts.push('Sende: ' + sent + '/' + total);

        if (startedAt) {
          const t0 = Date.parse(startedAt);
          if (!isNaN(t0)) parts.push(fmtHMS((nowMs - t0)/1000));
        }

        parts.push(where);
        if (submitted) parts.push('submitted');
        if (done !== null && max !== null) parts.push('Versuch ' + done + '/' + max);

        return parts.join(' · ');
      }

      if (where === 'queue') {
        const ca = safeText(job.created_at);
        let hm = '';
        if (ca) {
          const t = Date.parse(ca);
          if (!isNaN(t)) {
            const d = new Date(t);
            hm = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
          }
        }
        return 'queued' + (hm ? (' · erstellt ' + hm) : '');
      }

      return where || 'aktiv';
    }

    function buildTooltips(job, line2){
      const r = job.recipient || {};
      const s = job.source || {};
      const t1 = [
        'Fax: ' + safeText(r.number),
        'Datei: ' + safeText(s.filename_original),
        'Job: ' + safeText(job.job_id)
      ].join('\n');

      let t2 = line2;
      const live = job.live || null;
      if (live) {
        const extra = [];
        const af = live.asterisk_fax || null;
        if (af && af.active) {
          if (safeText(af.state) || safeText(af.last_status)) extra.push('Status: ' + [safeText(af.state), safeText(af.last_status)].filter(Boolean).join(' / '));
          if (safeText(af.session)) extra.push('Session: ' + safeText(af.session));
          if (safeText(af.channel)) extra.push('Kanal: ' + safeText(af.channel));
          if (safeText(af.connected_at)) {
            const t0 = Date.parse(safeText(af.connected_at));
            if (!isNaN(t0)) extra.push('Callzeit: ' + fmtHMS((Date.now() - t0) / 1000));
          }
          if (safeNumber(af.data_rate) !== null && safeNumber(af.data_rate) > 0) extra.push('Datenrate: ' + String(safeNumber(af.data_rate)) + ' bit/s');
          if (safeText(af.file_name)) extra.push('TIFF: ' + safeText(af.file_name));
          if (safeText(af.updated_at)) extra.push('Update: ' + safeText(af.updated_at));
        }
        if (safeText(live.state)) extra.push('state ' + safeText(live.state));
        if (safeText(live.faxstat_status)) extra.push(safeText(live.faxstat_status));
        if (extra.length) t2 = t2 + '\n' + extra.join('\n');
      }
      return {t1, t2};
    }

    function escapeHtml(s){
      s = String(s);
      return s
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;')
        .replace(/'/g,'&#039;');
    }

    function renderSourceFiles(payload){
      if (!sourceFilesBody || !payload || !Array.isArray(payload.files)) return;

      const files = payload.files;
      const sig = files.map(f => safeText(f.filename) + '\t' + safeText(f.size)).join('\n');
      if (sig === lastSourceFilesSig) return;
      lastSourceFilesSig = sig;

      const checked = new Set(
        Array.from(sourceFilesBody.querySelectorAll('.filebox:checked')).map(b => b.value)
      );

      if (files.length === 0) {
        sourceFilesBody.innerHTML = '<tr><td colspan="4" class="mut">Keine sendbaren PDFs gefunden.</td></tr>';
        return;
      }

      const src = safeText(payload.src) || CURRENT_SRC;
      sourceFilesBody.innerHTML = files.map(f => {
        const fn = safeText(f.filename);
        const sizeLabel = safeText(f.size_label) || '—';
        const isChecked = checked.has(fn) ? ' checked' : '';
        const href = '?download=srcpdf&src=' + encodeURIComponent(src) + '&file=' + encodeURIComponent(fn);
        return `
<tr>
  <td class="nowrap"><input type="checkbox" name="files[]" value="${escapeHtml(fn)}" class="filebox"${isChecked}></td>
  <td style="font-weight:900;">
    <span class="ellipsis fn" title="${escapeHtml(fn)}">${escapeHtml(fn)}</span>
  </td>
  <td class="nowrap">${escapeHtml(sizeLabel)}</td>
  <td class="right nowrap"><a class="btn ghost small" href="${escapeHtml(href)}">👁️ PDF</a></td>
</tr>`;
      }).join('');
    }

    function renderJobs(activeJobs){
      if (!listEl) return;

      if (!Array.isArray(activeJobs) || activeJobs.length === 0) {
        listEl.innerHTML = '<li><span class="mut">Keine aktiven Jobs</span></li>';
        return;
      }

      const nowMs = Date.now();

      const itemsHtml = activeJobs.map(job => {
        const r = job.recipient || {};
        const name = safeText(r.name) || '—';
        const line2 = buildLine2(job, nowMs);
        const tips = buildTooltips(job, line2);

        const jobId = safeText(job.job_id);
        const where = safeText(job.where);

        return `
<li>
  <div style="min-width:0;">
    <div style="font-weight:900;">
      <span class="ellipsis sidebar" title="${escapeHtml(tips.t1)}">${escapeHtml(name)}</span>
    </div>
    <div class="mut" style="font-size:13px; margin-top:2px;">
      <span class="ellipsis sidebar" title="${escapeHtml(tips.t2)}">${escapeHtml(line2)}</span>
    </div>
  </div>

  <div style="display:flex; align-items:center; gap:8px;">
    <form method="post" style="display:inline;" onsubmit="return confirm('Job wirklich abbrechen?');">
      <input type="hidden" name="action" value="cancel_job">
      <input type="hidden" name="job_id" value="${escapeHtml(jobId)}">
      <input type="hidden" name="where" value="${escapeHtml(where)}">
      <button class="btn icon-danger" type="submit" title="Abbruch anfordern">⛔</button>
    </form>
  </div>
</li>`;
      }).join('');

      listEl.innerHTML = itemsHtml;
    }

    async function poll(){
      if (document.visibilityState !== 'visible') return;
      try {
        const url = new URL(window.location.href);
        url.searchParams.set('ajax', 'status');
        url.searchParams.set('_', String(Date.now()));

        const res = await fetch(url.toString(), {cache: 'no-store'});
        if (!res.ok) return;
        const j = await res.json();

        if (kpiQueue && typeof j.queue_count === 'number') kpiQueue.textContent = String(j.queue_count);
        if (kpiProc  && typeof j.processing_count === 'number') kpiProc.textContent = String(j.processing_count);

        if (failTab && typeof j.fail_count === 'number') {
          failTab.title = 'Fehlerberichte (' + j.fail_count + ')';
          if (j.fail_count > 0) failTab.classList.add('pulse-danger');
          else failTab.classList.remove('pulse-danger');

          // Sound nur bei Anstieg (Handlungsbedarf)
          if (j.fail_count > lastFailCount && soundEnabled()) {
            try {
              const a = new Audio(SOUND_URL);
              a.play().catch(() => {});
            } catch (e) {}
          }
          lastFailCount = j.fail_count;
          localStorage.setItem('kf_last_fail_count', String(lastFailCount));
        }

        updateInboxBadges(j.inbox_counts || null);
        renderJobs(j.active_jobs || []);
        renderSourceFiles(j.source_files || null);
      } catch (e) {
        // still
      }
    }

    poll();
    setInterval(poll, 5000);
  })();
</script>

</body>
</html>
