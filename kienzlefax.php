<?php
/**
 * kienzlefax.php
 * Producer Web-UI (sendet NICHT selbst).
 *
 * Version: 1.2.1
 * Author: Dr. Thomas Kienzle
 * Stand: 2026-02-14
 *
 * Changelog (komplett):
 * - 1.2.1 (2026-02-14):
 *   - FIX: Robustere Erkennung "⛔ Abgebrochen" in Fehlerberichte UND Sendeprotokoll:
 *          • cancel.requested=true UND cancel.handled_at vorhanden -> Abgebrochen
 *          • ODER result.reason/status_text enthält "aborted"
 *          • ODER statuscode==345 in Kombination mit cancel.requested
 *   - FIX: Formfelder nutzen box-sizing:border-box (Faxnummer läuft nicht mehr über Begrenzung).
 *   - UI: Abbruch-Button bei aktiven Jobs nun dezenter Icon-Button (kein großes rotes Feld).
 *
 * - 1.2 (2026-02-14):
 *   - UI: Version + Autor als Footer unten mittig (nicht mehr im Header).
 *   - UI: Empfänger-Layout korrigiert: deutlich mehr Abstand Name↔Fax, Gesamtbreite reduziert, Empfängernamefeld kürzer.
 *   - UI: "Fax beauftragen" wieder auf Höhe des Auflösungs-Dropdowns (bündig).
 *   - UI: PDF-Button in Dateiliste: Text nur "löschen" (Funktion unverändert).
 *   - UI: PDF-Dateiliste zeigt zusätzlich Dateigröße (KB/MB).
 *   - UI: Aktive Jobs können abgebrochen werden (⛔-Button je Job, mit Rückfrage).
 *   - JSON: Abbruch setzt in job.json: cancel.requested=true + cancel.requested_at=ISO8601 (kein Statuswechsel; Worker übernimmt).
 *   - UI: Status-Anzeige "⛔ Abgebrochen" (statt "Fehlgeschlagen") in Fehlerberichte UND Sendeprotokoll,
 *         wenn JSON result.reason/status_text "aborted" enthält (z.B. "Job aborted by request").
 *   - UI: Fehlerberichte-Tab pulsiert weiterhin deutlich, wenn Fehler vorhanden (unverändert – nur beibehalten).
 *
 * - 1.1 (2026-02-14):
 *   - UI: Subtitle ersetzt durch "Der ideale Server für Arztpraxen".
 *   - UI: "Bitte wählen:" über der Ordnerauswahl.
 *   - UI: Refresh-Button in der Kopfzeile.
 *   - UI: PDF-Auswahl: Button zum Löschen ausgewählter PDFs (Quelle) hinzugefügt.
 *   - UI: Sendeprotokoll: Option "alle anzeigen" (aus Performancegründen gecappt).
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

$DB_PATH      = $BASE . '/phonebook.sqlite';

$ALLOW_SOURCES = [
  'fax1' => $DIR_INCOMING . '/fax1',
  'fax2' => $DIR_INCOMING . '/fax2',
  'fax3' => $DIR_INCOMING . '/fax3',
  'fax4' => $DIR_INCOMING . '/fax4',
  'fax5' => $DIR_INCOMING . '/fax5',
  'pdf-zu-fax' => $DIR_DROPIN,
  'sendefehler' => $DIR_FAIL_IN, // sendefehler/eingang ist sendbar
];

$EXCLUDE_SUFFIXES = ['__OK.pdf', '__FAILED.pdf'];
$EXCLUDE_CONTAINS = ['__REPORT__'];

$MAX_LIST_FILES   = 500;
$MAX_ACTIVE_JOBS  = 12;
$MAX_FAIL_LIST    = 200;
$MAX_ARCHIVE_LIST = 25;

$APP_TITLE   = 'kienzlefax';
$APP_VERSION = '1.2.1';
$APP_AUTHOR  = 'Dr. Thomas Kienzle';

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

function format_duration(?int $sec): string {
  if ($sec === null || $sec < 0) return '';
  $m = intdiv($sec, 60);
  $s = $sec % 60;
  if ($m <= 0) return $s . ' s';
  return $m . ' min ' . $s . ' s';
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

/**
 * 1.2.1: Abbruch robust erkennen:
 * - cancel.requested && cancel.handled_at
 * - oder "aborted" in result.reason/status_text
 * - oder statuscode==345 && cancel.requested
 */
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

function format_size(?int $bytes): string {
  if ($bytes === null || $bytes < 0) return '—';
  if ($bytes < 1024) return $bytes . ' B';
  $kb = $bytes / 1024;
  if ($kb < 1024) return (string)round($kb) . ' KB';
  $mb = $kb / 1024;
  return number_format($mb, 1, '.', '') . ' MB';
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
    $contact_id = trim((string)($_POST['contact_id'] ?? ''));
    $recipient_name = trim((string)($_POST['recipient_name'] ?? ''));
    $recipient_number = trim((string)($_POST['recipient_number'] ?? ''));

    $save_to_phonebook = isset($_POST['save_to_phonebook']);

    // Wenn Kontakt gewählt: Felder (falls leer) automatisch übernehmen
    if ($contact_id !== '') {
      $c = get_contact($pdo, (int)$contact_id);
      if ($c) {
        if ($recipient_name === '') $recipient_name = (string)$c['name'];
        if ($recipient_number === '') $recipient_number = (string)$c['number'];
      } else {
        add_err("Telefonbuch-Eintrag nicht gefunden.");
      }
    }

    $norm = normalize_fax_number($recipient_number);

    if ($recipient_name === '') add_err("Empfängername fehlt.");
    if ($norm === '') add_err("Faxnummer fehlt/ungültig.");

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
      $created = 0;
      $movedSources = 0;

      foreach ($valid as $fn) {
        $jobid = make_job_id();
        $jobStagingDir = $DIR_STAGING . '/' . $jobid;
        $jobQueueDir   = $DIR_QUEUE . '/' . $jobid;

        if (!mkdir($jobStagingDir, 0775, true) && !is_dir($jobStagingDir)) {
          add_err("Konnte staging-Jobordner nicht anlegen: $jobid");
          continue;
        }

        $srcPath = $srcDir . '/' . $fn;

        // 1) doc.pdf in staging erzeugen (copy, damit wir bei späteren Fehlern NICHT die Quelle verlieren)
        $docPath = $jobStagingDir . '/doc.pdf';
        if (!copy($srcPath, $docPath)) {
          @rmdir($jobStagingDir);
          add_err("Konnte PDF nicht kopieren: " . $fn);
          continue;
        }

        $job = [
          "job_id" => $jobid,
          "created_at" => date('c'),
          "source" => [
            "src" => $src,
            "filename_original" => $fn,
          ],
          "recipient" => [
            "name" => $recipient_name,
            "number" => $norm,
          ],
          "options" => [
            "ecm" => $ecm,
            "resolution" => $res,
          ],
          "status" => "queued",
        ];

        try {
          json_write_atomic($jobStagingDir . '/job.json', $job);
        } catch (Throwable $e) {
          @unlink($docPath);
          @unlink($jobStagingDir . '/job.json');
          @rmdir($jobStagingDir);
          add_err("Konnte job.json nicht schreiben ($jobid): " . $e->getMessage());
          continue;
        }

        // 2) staging -> queue (atomar)
        if (!rename($jobStagingDir, $jobQueueDir)) {
          add_err("Konnte Job nicht in queue verschieben ($jobid).");
          continue;
        }

        $created++;

        // 3) Quelle soll verschwinden: Original in queue/<jobid>/source.pdf verschieben (rename)
        $destSource = $jobQueueDir . '/source.pdf';
        if (!file_exists($destSource)) {
          if (@rename($srcPath, $destSource)) {
            $movedSources++;
          }
        }
      }

      // 4) optional: ins Telefonbuch speichern
      if ($save_to_phonebook && count($flash['err']) === 0) {
        try {
          $cid = ($contact_id !== '') ? (int)$contact_id : null;
          upsert_contact($pdo, $cid, $recipient_name, $norm, '');
          add_ok("Empfänger im Telefonbuch gespeichert.");
          $contacts = get_contacts($pdo);
        } catch (Throwable $e) {
          add_err("Telefonbuch-Fehler: " . $e->getMessage());
        }
      }

      if ($created > 0) {
        add_ok("✅ Beauftragt: $created Job(s).");
        if ($movedSources > 0) {
          add_ok("📦 Quellen-Datei(en) verschoben: $movedSources → queue/<jobid>/source.pdf");
        } else {
          add_ok("Hinweis: Falls eine Quelle-Datei liegen bleibt, fehlen Schreibrechte zum Verschieben in die queue.");
        }
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
    if ($deleted > 0) add_ok("🗑️ Gelöscht: $deleted Datei(en) aus Quelle " . $src . ".");
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
      if (preg_match('/\A(.+)\.json\z/i', $jsonFn, $m)) {
        $stem = $m[1];
        $cand = $stem . '__FAILED.pdf';
        if (is_file($DIR_FAIL_REP . '/' . $cand)) $pdfFn = $cand;
      }

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
        $destJson = $DIR_ARCHIVE . '/' . $jsonFn;
        if (is_file($destJson)) {
          $destJson = $DIR_ARCHIVE . '/' . preg_replace('/\.json\z/i', '', $jsonFn) . '.moved.' . random_suffix(6) . '.json';
        }
        $ok = @rename($jsonPath, $destJson);
        if ($ok) {
          $moved++;
          $done++;
          if ($pdfFn !== '') {
            $srcPdf = $DIR_FAIL_REP . '/' . $pdfFn;
            $destPdf = $DIR_ARCHIVE . '/' . $pdfFn;
            if (is_file($destPdf)) {
              $destPdf = $DIR_ARCHIVE . '/' . preg_replace('/\.pdf\z/i', '', $pdfFn) . '.moved.' . random_suffix(6) . '.pdf';
            }
            if (within_dir($srcPdf, $DIR_FAIL_REP) && is_file($srcPdf)) {
              @rename($srcPdf, $destPdf);
            }
          }
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
$src  = (string)($_GET['src'] ?? 'fax1');
if ($view === '' && !isset($ALLOW_SOURCES[$src])) $src = 'fax1';

// -------------------- Sidebar Data --------------------
$queueJobs = list_job_dirs($DIR_QUEUE);
$procJobs  = list_job_dirs($DIR_PROC);

function read_job_meta(string $jobDir): ?array {
  $p = $jobDir . '/job.json';
  return read_json_file($p);
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

// Contact map for JS
$contactMap = [];
foreach ($contacts as $c) {
  $contactMap[(string)$c['id']] = ['name' => (string)$c['name'], 'number' => (string)$c['number']];
}

// Fehler vorhanden? (für Puls-Tab)
$failCount = count_json_files($DIR_FAIL_REP, 999);
$hasFails = ($failCount > 0);

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
    body{
      margin:0;
      font-family: system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;
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
    .pill{ display:inline-flex; gap:8px; align-items:center; padding:8px 10px; border:1px solid var(--line); border-radius:999px; background:#fff; box-shadow: 0 6px 14px rgba(18,34,64,.04); font-size:14px; color: var(--ink); text-decoration:none; }
    .pill b{ font-variant-numeric: tabular-nums; }

    .wrap{ max-width:1200px; margin:0 auto; padding:14px 16px 26px; display:grid; grid-template-columns: 360px 1fr; gap:14px; width:100%; flex:1 0 auto; }
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

    /* 1.2.1 FIX: box-sizing verhindert Überbreite (Faxnummer) */
    input[type="text"], textarea, select{
      width:100%;
      padding:12px 12px;
      border:1px solid var(--line);
      border-radius:12px;
      font-size:15px;
      background:#fff;
      box-sizing:border-box;
    }
    textarea{ min-height:80px; }
    label{ font-weight:800; font-size:13px; color:var(--mut); display:block; margin:10px 0 6px; }

    .row{ display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:12px; }

    /* Empfänger: bewusst schmaler + größerer Spaltabstand */
    .recipient-limits{ max-width: 860px; }
    .recipient-row{ display:grid; grid-template-columns: 1fr 1fr; column-gap: 32px; margin-top:12px; }

    .tbl{ width:100%; border-collapse:collapse; }
    .tbl th,.tbl td{ border-bottom:1px solid var(--line); padding:10px 8px; vertical-align:top; font-size:14px; }
    .tbl th{ color:var(--mut); text-align:left; font-weight:900; }
    .right{ text-align:right; }
    .nowrap{ white-space:nowrap; }
    .chip{ display:inline-flex; align-items:center; gap:8px; padding:6px 10px; border-radius:999px; border:1px solid var(--line); background:#fff; font-weight:900; font-size:13px; }
    .chip.ok{ background: rgba(24,169,87,.12); }
    .chip.fail{ background: rgba(255,77,109,.12); }
    .chip.warn{ background: rgba(255,176,32,.18); }
    .chip.abort{ background: rgba(255,77,109,.10); border-color: rgba(255,77,109,.55); }

    .stack{ display:grid; gap:10px; }
    .checkline{ display:flex; align-items:flex-end; gap:14px; margin-top:12px; flex-wrap:wrap; }
    .optstack{ display:grid; gap:8px; align-content:start; }
    .optstack label{ margin:0; font-weight:900; color:var(--ink); display:flex; align-items:center; gap:10px; }

    /* Empfänger: Auflösung + Button gleiche Höhe */
    .actionrow{
      display:grid;
      grid-template-columns: 1fr 220px auto;
      gap:14px;
      align-items:end;
      margin-top:12px;
      max-width: 860px;
    }

    /* Deutliches Pulsieren für Fehlerberichte-Tab */
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

    /* 1.2.1 UI: dezenter Icon-Abbruchknopf (kein großes rotes Feld) */
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
  </style>
</head>
<body>
<header>
  <div class="head-inner">
    <div class="brand">
      <div class="logo"></div>
      <div>
        <div style="font-size:18px; line-height:1;"><?=h($APP_TITLE)?></div>
        <div class="mut" style="font-size:13px; margin-top:3px;">Der ideale Server für Arztpraxen</div>
      </div>
    </div>
    <div class="kpis">
      <a class="pill" href="<?=h($_SERVER['REQUEST_URI'] ?? '/')?>">🔄 refresh</a>
      <span class="pill">⏳ queue <b><?=count($queueJobs)?></b></span>
      <span class="pill">⚙️ processing <b><?=count($procJobs)?></b></span>
    </div>
  </div>
</header>

<div class="wrap">
  <!-- Sidebar -->
  <div class="card">
    <div class="mut" style="font-size:13px; font-weight:900; margin-bottom:8px;">Bitte wählen:</div>

    <div class="tabs">
      <?php foreach (['fax1','fax2','fax3','fax4','fax5','pdf-zu-fax','sendefehler'] as $t): ?>
        <a class="tab <?=($view==='' && $src===$t)?'active':''?>" href="?src=<?=h($t)?>">📄 <?=h($t)?></a>
      <?php endforeach; ?>
      <a class="tab <?=($view==='sendelog')?'active':''?>" href="?view=sendelog">✅ Sendeprotokoll</a>
      <a class="tab <?=($view==='phonebook')?'active':''?>" href="?view=phonebook">📇 Telefonbuch</a>
      <a class="tab <?=($view==='sendefehler-berichte')?'active':''?> <?=($hasFails ? 'pulse-danger' : '')?>" href="?view=sendefehler-berichte">⚠️ Fehlerberichte</a>
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

      <ul class="list">
        <?php if (count($activePreview) === 0): ?>
          <li><span class="mut">Keine aktiven Jobs</span></li>
        <?php else: ?>
          <?php foreach ($activePreview as $a): ?>
            <?php
              $meta = $a['meta'] ?? null;
              $to = is_array($meta) ? ($meta['recipient']['number'] ?? '') : '';
              $name = is_array($meta) ? ($meta['recipient']['name'] ?? '') : '';
              $st = is_array($meta) ? ($meta['status'] ?? $a['where']) : $a['where'];
            ?>
            <li>
              <div style="min-width:0;">
                <div class="mono" style="white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:240px;"><?=h($a['id'])?></div>
                <div class="mut" style="font-size:13px; margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:240px;">
                  <?=h((string)$st)?> · <?=h((string)$name)?> · <span class="mono"><?=h((string)$to)?></span>
                </div>
              </div>

              <div style="display:flex; align-items:center; gap:8px;">
                <span class="chip"><?=h($a['where'])?></span>
                <form method="post" style="display:inline;" onsubmit="return confirm('Job wirklich abbrechen?');">
                  <input type="hidden" name="action" value="cancel_job">
                  <input type="hidden" name="job_id" value="<?=h($a['id'])?>">
                  <input type="hidden" name="where" value="<?=h($a['where'])?>">
                  <button class="btn icon-danger" type="submit" title="Abbruch anfordern">⛔</button>
                </form>
              </div>
            </li>
          <?php endforeach; ?>
        <?php endif; ?>
      </ul>
    </div>

    <div class="mut" style="font-size:13px; margin-top:12px;">
      <b>Hinweis:</b> Fehler erneut senden: Tab <b>sendefehler</b> (Eingang) öffnen und dort beauftragen.
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

    <?php elseif ($view === 'sendelog'): ?>
      <?php
        $showAll = ((string)($_GET['all'] ?? '') === '1');
        $limit = $showAll ? 500 : $MAX_ARCHIVE_LIST;
      ?>
      <div style="display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap;">
        <h2 class="section-title" style="margin:0;">✅ Sendeprotokoll (<?= $showAll ? 'alle' : ('letzte ' . $MAX_ARCHIVE_LIST) ?>)</h2>
        <?php if (!$showAll): ?>
          <a class="btn ghost small" href="?view=sendelog&amp;all=1">📚 alle anzeigen</a>
        <?php else: ?>
          <a class="btn ghost small" href="?view=sendelog">↩️ zurück (letzte)</a>
        <?php endif; ?>
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
              $j = read_json_file($p);
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
              $isOk = (strcasecmp($status, 'OK') === 0) || (stripos($status, 'ok') !== false);
              $isAborted = (!$isOk) && is_aborted_job($j);

              $dur = '';
              $t1 = parse_iso_time($start);
              $t2 = parse_iso_time($end);
              if ($t1 !== null && $t2 !== null) $dur = format_duration($t2 - $t1);

              $pages = '';
              if (isset($j['result']) && is_array($j['result']) && isset($j['result']['pages'])) $pages = (string)$j['result']['pages'];
              if ($pages === '' && isset($j['pages'])) $pages = (string)$j['pages'];

              $pdf = '';
              if (preg_match('/\A(.+)\.json\z/i', $it['json'], $m)) {
                $stem = $m[1];
                $candOk = $stem . '__OK.pdf';
                $candFail = $stem . '__FAILED.pdf';
                if (is_file($DIR_ARCHIVE . '/' . $candOk)) $pdf = $candOk;
                elseif (is_file($DIR_ARCHIVE . '/' . $candFail)) $pdf = $candFail;
              }
            ?>
            <tr>
              <td class="nowrap">
                <?php if ($isOk): ?><span class="chip ok">✅ Senden erfolgreich</span>
                <?php elseif ($isAborted): ?><span class="chip abort">⛔ Abgebrochen</span>
                <?php else: ?><span class="chip fail">❌ Fehlgeschlagen</span><?php endif; ?>
              </td>
              <td class="nowrap"><?=h($end)?></td>
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

      <?php if ($showAll): ?>
        <div class="mut" style="font-size:12px; margin-top:10px;">
          Hinweis: "alle anzeigen" ist aus Performance-Gründen auf 500 Einträge begrenzt.
        </div>
      <?php endif; ?>

    <?php elseif ($view === 'sendefehler-berichte'): ?>
      <h2 class="section-title">⚠️ Sendefehler-Berichte</h2>

      <div class="subtle" style="margin-bottom:10px;">
        <div style="font-weight:900;">Erneut senden?</div>
        <div class="mut" style="margin-top:6px;">
          Bitte die Original-PDF im Tab <b>sendefehler</b> (Eingang) auswählen und neu beauftragen.
        </div>
        <div class="checkline">
          <a class="btn primary" href="?src=sendefehler">↩️ Zum erneuten Senden (sendefehler)</a>
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
              $j = read_json_file($p);
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

      <form method="post" id="failForm">
        <input type="hidden" name="action" value="fail_cleanup">
        <input type="hidden" name="op" id="failOp" value="">

        <div class="checkline" style="margin-top:0; justify-content:flex-end;">
          <button type="button" class="btn ghost small" onclick="selectAllFail(true)">✅ alle</button>
          <button type="button" class="btn ghost small" onclick="selectAllFail(false)">🧹 keine</button>
          <button type="button" class="btn ghost small" onclick="submitFail('adopt')">📥 Fehler in Sendeprotokoll übernehmen</button>
          <button type="button" class="btn danger small" onclick="submitFail('delete')">🗑️ Ausgewählte löschen</button>
        </div>

        <table class="tbl" style="margin-top:10px;">
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
                $isAborted = is_aborted_job($j);

                $err = '';
                if (isset($j['result']) && is_array($j['result'])) {
                  $err = (string)($j['result']['error_message'] ?? $j['result']['stderr'] ?? '');
                  if ($err === '') $err = (string)($j['result']['status_text'] ?? $j['result']['reason'] ?? '');
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
                <td class="nowrap">
                  <input type="checkbox" name="failjson[]" value="<?=h($it['json'])?>" class="failbox">
                </td>
                <td class="nowrap">
                  <?php if ($isAborted): ?><span class="chip abort">⛔ Abgebrochen</span>
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

      <script>
        function selectAllFail(on) {
          document.querySelectorAll('.failbox').forEach(b => b.checked = on);
        }
        function submitFail(op) {
          if (op === 'delete') {
            if (!confirm('Ausgewählte Fehlerberichte wirklich löschen? (JSON + ggf. PDF)')) return;
          } else if (op === 'adopt') {
            if (!confirm('Ausgewählte Fehlerberichte ins Sendeprotokoll übernehmen?')) return;
          }
          document.getElementById('failOp').value = op;
          document.getElementById('failForm').submit();
        }
      </script>

    <?php else: ?>
      <?php
        $srcDir = $ALLOW_SOURCES[$src];
        $pdfs = list_source_pdfs($srcDir, $EXCLUDE_SUFFIXES, $EXCLUDE_CONTAINS, $MAX_LIST_FILES);
      ?>

      <h2 class="section-title">📄 Quelle: <?=h($src)?></h2>

      <form method="post" class="stack" id="srcForm">
        <input type="hidden" name="action" id="srcAction" value="create_jobs">
        <input type="hidden" name="src" value="<?=h($src)?>">

        <div class="subtle">
          <div style="font-weight:900; font-size:16px;">Empfänger</div>

          <div class="recipient-limits">
            <label>Telefonbuch (optional)</label>
            <select name="contact_id" id="contact_id">
              <option value="">— Kontakt wählen —</option>
              <?php foreach ($contacts as $c): ?>
                <option value="<?=(int)$c['id']?>"><?=h($c['name'])?> · <?=h($c['number'])?></option>
              <?php endforeach; ?>
            </select>

            <div class="recipient-row">
              <div>
                <label>Empfängername</label>
                <input type="text" name="recipient_name" id="recipient_name" placeholder="z.B. Radiologie XY">
              </div>
              <div>
                <label>Faxnummer</label>
                <input type="text" name="recipient_number" id="recipient_number" placeholder="z.B. 02331...">
              </div>
            </div>

            <div class="actionrow">
              <div class="optstack">
                <label>
                  <input type="checkbox" name="save_to_phonebook" id="save_to_phonebook">
                  Im Telefonbuch speichern
                </label>

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

              <div style="display:flex; justify-content:flex-end;">
                <button class="btn primary" type="submit" onclick="document.getElementById('srcAction').value='create_jobs'">🚀 Fax beauftragen</button>
              </div>
            </div>

            <div class="mut" style="font-size:13px; margin-top:10px;">
              Kontakt auswählen → Felder werden übernommen (du kannst danach ändern).
            </div>
          </div>
        </div>

        <div class="subtle">
          <div style="display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap;">
            <div>
              <div style="font-weight:900; font-size:16px;">PDF-Auswahl</div>
              <div class="mut" style="font-size:13px;">Mehrfachauswahl möglich</div>
            </div>
            <div class="checkline" style="margin:0;">
              <button type="button" class="btn ghost small" onclick="selectAll(true)">✅ Alle</button>
              <button type="button" class="btn ghost small" onclick="selectAll(false)">🧹 Keine</button>
              <button type="button" class="btn danger" onclick="submitDelete()">löschen</button>
            </div>
          </div>

          <table class="tbl" style="margin-top:10px;">
            <thead><tr><th class="nowrap"></th><th>Datei</th><th class="nowrap">Größe</th><th class="right nowrap">Vorschau</th></tr></thead>
            <tbody>
            <?php if (count($pdfs) === 0): ?>
              <tr><td colspan="4" class="mut">Keine sendbaren PDFs gefunden.</td></tr>
            <?php else: ?>
              <?php foreach ($pdfs as $fn): ?>
                <?php
                  $p = $srcDir . '/' . $fn;
                  $sizeStr = '—';
                  if (within_dir($p, $srcDir) && is_file($p)) {
                    $sz = @filesize($p);
                    $sizeStr = format_size(($sz === false) ? null : (int)$sz);
                  }
                ?>
                <tr>
                  <td class="nowrap"><input type="checkbox" name="files[]" value="<?=h($fn)?>" class="filebox"></td>
                  <td style="font-weight:900;"><?=h($fn)?></td>
                  <td class="mono nowrap"><?=h($sizeStr)?></td>
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

        const sel = document.getElementById('contact_id');
        const nameEl = document.getElementById('recipient_name');
        const numEl  = document.getElementById('recipient_number');

        function fillFromContact() {
          const id = sel.value;
          if (!id || !CONTACTS[id]) return;
          nameEl.value = CONTACTS[id].name || '';
          numEl.value  = CONTACTS[id].number || '';
        }
        sel.addEventListener('change', fillFromContact);

        function selectAll(on) {
          document.querySelectorAll('.filebox').forEach(b => b.checked = on);
        }

        function submitDelete() {
          const any = Array.from(document.querySelectorAll('.filebox')).some(b => b.checked);
          if (!any) { alert('Bitte erst Dateien auswählen.'); return; }
          if (!confirm('Ausgewählte Dateien wirklich löschen?')) return;
          document.getElementById('srcAction').value = 'delete_source_files';
          document.getElementById('srcForm').submit();
        }
      </script>

    <?php endif; ?>
  </div>
</div>

<footer>
  <?=h($APP_TITLE)?> · v<?=h($APP_VERSION)?> · <?=h($APP_AUTHOR)?>
</footer>
</body>
</html>
