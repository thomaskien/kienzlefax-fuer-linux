"""Paketabnahme ohne Root, Netzwerkzugriffe oder laufende Linux-Dienste."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = Path("installer-modular")
MAIN = MOD / "kienzlefax-install-modular.sh"
MANIFEST = MOD / "package-files.txt"
PACK = Path("scripts/pack.sh")

# Debian-Zielpfade für den isolierten Lauf in eine Wegwerfkopie umleiten.
HOST_PATHS = ("/etc/", "/usr/local/", "/usr/share/", "/var/lib/", "/var/www/",
              "/var/spool/", "/srv/")
PHONE_ANSWERS = [
    "", "", "", "", "1",           # Kanalgrenzen, ein Empfangstelefon
    "n",                           # nur internes Netz
    "", "1002", "", "test", "test",  # Telefonieprovider und SIP-Zugang
    "", "", "", "",                # Registrar, Proxy, Identify, Expiration
    "n", "n",                      # separate Ausgangsleitung und Überlauf
]
FAX_ANSWERS = [
    "fax-test", "", "", "1001", "", "test", "test",
    "", "", "", "",                # Registrar, Proxy, Identify, Expiration
    "y", "", "", "1", "1",         # Adminpasswort, DID, Kopfzeile, Drucker, Drop-ins
    "", "", "",                    # SIP und RTP
]


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


class KombiTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name).resolve()
        self.work = self.tmp / "Arbeitsstand mit Leerzeichen"
        self.cwd = self.tmp / "fremder Ordner"
        self.cwd.mkdir()
        self.archive = self.tmp / "Ausgabe" / "lokales Paket.tar.gz"
        self.package = self.tmp / "entpacktes Paket" / "kienzlefax"
        self.host = self.tmp / "host"
        self.trace = self.tmp / "executed"
        self.blocked = self.tmp / "downloads"
        self.envfile = self.host / "etc/kienzlefax-installer.env"
        self.web = self.host / "var/www/html"
        self.cache = self.host / "usr/local/lib/kienzlefax-installer/cache"
        self.bin = self.tmp / "bin"
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.tmp), "LC_ALL": "C", "TEST_TRACE": str(self.trace),
            "TEST_BLOCKED": str(self.blocked), "TEST_HOST": str(self.host),
        }
        for name in ("curl", "wget", "git"):
            self.stub(name, 'echo "$0 $*" >> "$TEST_BLOCKED"; exit 90')
        for rel in [*(ROOT / MANIFEST).read_text().splitlines(), PACK]:
            (self.work / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, self.work / rel)

    def tearDown(self):
        self.assertFalse(self.blocked.exists(), self.blocked.read_text() if self.blocked.exists() else "")

    def stub(self, name, body):
        path = self.bin / name
        write(path, "#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def shell(self, *args, answers=(), success=True):
        result = subprocess.run(
            ["bash", *args], env=self.env, cwd=self.cwd, input="".join(a + "\n" for a in answers),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def pack(self):
        self.shell(self.work / PACK, "--output", self.archive)
        expected = (self.work / MANIFEST).read_text().splitlines()
        with tarfile.open(self.archive, "r:gz") as archive:
            files = [member.name for member in archive if member.isfile()]
            self.assertCountEqual(files, ["kienzlefax/" + name for name in expected])
            self.assertTrue(all(m.name.split("/")[0] == "kienzlefax" and (m.isdir() or m.isfile())
                                for m in archive.getmembers()))
        self.package.parent.mkdir(exist_ok=True)
        subprocess.run(["tar", "-xzf", self.archive, "-C", self.package.parent], check=True)
        for name in expected:
            self.assertEqual((self.package / name).read_bytes(), (self.work / name).read_bytes())

    def test_archive_and_missing_required_file(self):
        for name in (".env", "install.log", "installer-modular/test-output.sh", "sources.json"):
            write(self.work / name, "lokale Testdaten\n")
        self.pack()
        dest = self.package / MOD / "agi.sh"
        dest.unlink()
        message = self.shell(self.package / MAIN, "--kombi", success=False)
        self.assertIn(str(dest), message)
        self.assertNotIn("Optionen sammeln", message)
        original = self.archive.read_bytes()
        (self.work / MOD / "agi.sh").unlink()
        message = self.shell(self.work / PACK, "--output", self.archive, success=False)
        self.assertIn(str(self.work / MOD / "agi.sh"), message)
        self.assertEqual(self.archive.read_bytes(), original)

    def test_pack_refuses_file_outside_the_working_tree(self):
        external = self.tmp / "private"
        write(external / "local.sh", "nur lokal\n")
        (self.work / "linked").symlink_to(external, target_is_directory=True)
        with (self.work / MANIFEST).open("a") as f:
            f.write("linked/local.sh\n")
        self.assertIn(str(self.work / "linked"), self.shell(self.work / PACK, "--output", self.archive, success=False))
        self.assertFalse(self.archive.exists())

    def prepare_host(self):
        # Produktiver Pack-/Quellpfad und Modulaufrufe bleiben erhalten. Nur
        # absolute Systemziele, Root-Prüfung und externe Hostoperationen ersetzen.
        for script in (self.package / MOD).glob("*.sh"):
            body = script.read_text()
            for prefix in HOST_PATHS:
                body = body.replace(prefix, str(self.host) + prefix)
            if script == self.package / MAIN:
                self.assertEqual(body.count("\nrequire_root\n"), 1)
                body = body.replace("\nrequire_root\n", "\n:\n")
            script.write_text(body)
        startup = self.tmp / "bash-env"
        write(startup, '''
case "${0##*/}" in
  [0-9][0-9]-*.sh)
    echo "${0##*/}" >>"$TEST_TRACE"
    case "${0##*/}" in 00-base.sh|40-web-ssl.sh) ;; *) exit 0 ;; esac ;;
esac
''')
        self.env["BASH_ENV"] = str(startup)
        for name in ("systemctl", "chown", "hostnamectl", "a2enmod", "a2ensite"):
            self.stub(name, "exit 0")
        for name in ("logname", "getent"):
            self.stub(name, "exit 1")
        self.stub("ip", '''case "$*" in
          *"route get"*) echo "1.1.1.1 dev eth0 src 192.0.2.10" ;;
          *) echo "2: eth0 inet 192.0.2.10/24 scope global eth0" ;;
        esac''')
        self.stub("ss", 'echo "192.0.2.10:5060 asterisk"')
        self.stub("asterisk", '''case "$2" in
          "module show like "*) module=${2##* }; echo "${module%.so}.so Running" ;;
          "pjsip show registrations") echo "kfx-provider/sip:test test Registered" ;;
          "core show settings") echo "Data directory: $TEST_HOST/var/lib/asterisk" ;;
          "queue show praxis")
              if [ -f "$TEST_HOST/queue-unavailable" ]; then echo "No such queue"
              else echo "praxis has 0 calls (max 5)"; fi ;;
        esac''')
        if sys.platform == "darwin":
            self.stub("sed", 'if [ "$1" = -i ]; then shift; exec /usr/bin/sed -i "" "$@"; fi\nexec /usr/bin/sed "$@"')
        for name in ("queue-thankyou", "queue-youarenext", "queue-thereare", "queue-callswaiting"):
            write(self.host / f"usr/share/asterisk/sounds/de/{name}.gsm", "test")
        for path in ("etc/hosts", "etc/ssl/kienzlefax/kienzlefax.crt", "etc/ssl/kienzlefax/kienzlefax.key",
                     "var/www/html/kienzlefax.php", "var/www/html/faxton.mp3"):
            write(self.host / path, "ALT\n")
        (self.host / "etc/apache2/sites-available").mkdir(parents=True)
        (self.host / "etc/asterisk").mkdir(parents=True)
        for script in (self.package / MOD).glob("*.sh"):
            write(self.cache / script.name, 'echo "ALTER CACHE"; exit 91\n')
            (self.cache / script.name).chmod(0o755)

    def test_public_bootstrap_and_standalone_full_install(self):
        self.pack()
        self.prepare_host()
        # Offline-Antworten ausschließlich für die beiden erwarteten Abrufe
        # des Einzelinstallers. Jeder andere Abruf schlägt fehl.
        self.env["TEST_MAIN"] = str(self.package / MAIN)
        self.stub("wget", '''
if [ "$1" = "https://raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/main/installer-modular/kienzlefax-install-modular.sh" ] &&
   [ "$2" = "-O" ]; then exec cp "$TEST_MAIN" "$3"; fi
echo "$*" >>"$TEST_BLOCKED"; exit 90''')
        self.stub("curl", '''
if [ "$2" = "-o" ] && [ "$3" = "$TEST_HOST/var/www/html/faxton.mp3" ] &&
   [ "$4" = "https://github.com/thomaskien/kienzlefax-fuer-linux/raw/refs/heads/main/faxton.mp3" ]; then
  echo "Faxton-Testantwort" >"$3"; exit 0
fi
echo "$*" >>"$TEST_BLOCKED"; exit 90''')
        for script in self.cache.glob("*.sh"):
            script.write_text('echo "$0" >>"$TEST_TRACE"\n')
        self.shell(self.work / "kienzlefax-installer.sh", answers=[
            FAX_ANSWERS[0], "n", *FAX_ANSWERS[1:],  # Vollinstallation
            "n", "", "", "", "",                    # Telefonie aus, Kanalgrenzen
            *([""] * 9),                             # Cache und vorhandene PHP behalten
            "n", "y", "n", "",                      # Build, Bericht, Git-Ref
        ])
        self.assertIn("KFX_PHONE_QUEUE_ENABLED=n", self.envfile.read_text())
        self.assertIn(str(self.cache / "worker.sh"), self.trace.read_text().splitlines())
        self.assertEqual((self.web / "kienzlefax.php").read_text(), "ALT\n")
        self.assertEqual((self.web / "faxton.mp3").read_text(), "Faxton-Testantwort\n")

    def test_packaged_full_install_and_standalone_queue_only(self):
        # Neue, noch ungetrackte Programmdatei und unveröffentlichter Worker
        # sind nur in dieser Arbeitskopie vorhanden.
        helper = MOD / "local-helper.sh"
        with (self.work / MANIFEST).open("a") as f:
            f.write(str(helper) + "\n")
        write(self.work / helper, 'echo "lokaler Worker ausgeführt" >>"$TEST_TRACE"\n')
        write(self.work / MOD / "worker.sh", "source installer-modular/local-helper.sh\n")
        write(self.cwd / helper, "exit 94\n")
        for name in ("agi.sh", "scan_ocr.sh", "pdf_with_header.sh", "wireguard-installer.sh"):
            write(self.work / MOD / name, 'echo "$0" >>"$TEST_TRACE"\n')
        with (self.work / "kienzlefax.php").open("a") as f:
            f.write("\n<!-- lokaler Webstand -->\n")
        self.pack()
        self.prepare_host()
        # Eine gespeicherte Queue-only-Konfiguration darf im Kombilauf keine
        # Faxstufe unterdrücken. Das bestehende Nebenstellenpasswort bleibt erhalten.
        write(self.envfile, "KFX_QUEUE_ONLY=y\nKFX_PHONE_ENDPOINT_201_PASSWORD=test-bestand\n")
        self.shell(self.package / MAIN, "--kombi", answers=[
            "y", "n", *FAX_ANSWERS, *PHONE_ANSWERS, "n", "n", "y", "n", "",
        ])
        settings = self.envfile.read_text()
        for setting in ("KFX_QUEUE_ONLY=n", "KFX_PHONE_QUEUE_ENABLED=y", 'KFX_PHONE_ENDPOINT_201_PASSWORD="test-bestand"'):
            self.assertIn(setting, settings)
        self.assertNotIn(str(self.package), settings)
        for name in ("kienzlefax.php", "faxton.mp3"):
            self.assertEqual((self.web / name).read_bytes(), (self.work / name).read_bytes())
        executed = self.trace.read_text().splitlines()
        for name in ("agi.sh", "scan_ocr.sh", "pdf_with_header.sh", "wireguard-installer.sh"):
            self.assertIn(str(self.package / MOD / name), executed)
        self.assertIn("lokaler Worker ausgeführt", executed)
        self.assertIn("50-cups-samba.sh", executed)
        self.assertIn("90-worker-unit.sh", executed)
        self.assertIn("ALTER CACHE", (self.cache / "worker.sh").read_text())
        etc = self.host / "etc/asterisk"
        for name, marker in (("queues-kfx.conf", "[praxis]"), ("extensions-kfx-telefonie.conf", "Queue(praxis,r)"),
                             ("extensions.conf", "[fax-out]"), ("extensions.conf", "[kfx_external_capacity]"),
                             ("extensions.conf", "1002,1,Goto(kfx-phone-in,s,1)"),
                             ("pjsip-kfx-telefonie.conf", "[kfx-phone-in-endpoint]")):
            self.assertIn(marker, (etc / name).read_text())

        # Bestehende Faxkonfiguration ohne aktive Telefonie ergänzen. Bei
        # abgewähltem WireGuard ist dessen Quelldatei entbehrlich.
        self.envfile.write_text(settings.replace("KFX_PHONE_QUEUE_ENABLED=y", "KFX_PHONE_QUEUE_ENABLED=n"))
        (self.package / MOD / "wireguard-installer.sh").unlink()
        self.shell(self.package / MAIN, "--kombi", answers=["n", "n", *PHONE_ANSWERS, "n", "n", "y", "n"])
        self.assertIn("KFX_PHONE_QUEUE_ENABLED=y", self.envfile.read_text())
        self.assertIn('KFX_SIP_USER="1001"', self.envfile.read_text())

        missing_wg = self.shell(self.package / MAIN, "--kombi", answers=["y"], success=False)
        self.assertIn(str(self.package / MOD / "wireguard-installer.sh"), missing_wg)
        self.assertNotIn("Optionen sammeln", missing_wg)
        (self.host / "queue-unavailable").touch()
        result = self.shell(self.package / MAIN, "--kombi", answers=["n", "n", "n", "y", "n"], success=False)
        self.assertIn("Queue praxis nicht geladen", result)

        # Eigenständiger Aufruf des Hauptinstallers mit den drei Queue-only-
        # Modulen aus dem Bestandscache, ohne Zugriff auf eine Paketliste.
        self.envfile.write_text(self.envfile.read_text().replace("KFX_QUEUE_ONLY=n", "KFX_QUEUE_ONLY=y"))
        for name in ("pjsip-provider.sh", "extensions.sh", "telefonie-queue.sh"):
            shutil.copyfile(self.package / MOD / name, self.cache / name)
        (self.package / MANIFEST).unlink()
        self.trace.unlink()
        self.shell(self.package / MAIN, answers=["n", "", "", "", "n", "n", "y"])
        self.assertNotIn("40-web-ssl.sh", self.trace.read_text())
        self.assertNotIn("90-worker-unit.sh", self.trace.read_text())
        self.assertNotIn("[fax-out]", (etc / "extensions.conf").read_text())
        self.assertIn("[praxis]", (etc / "queues-kfx.conf").read_text())


if __name__ == "__main__":
    unittest.main()
