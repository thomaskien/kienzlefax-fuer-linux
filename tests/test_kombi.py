"""Paketabnahme ohne Root, Netzwerkzugriffe oder laufende Linux-Dienste."""
import os
import re
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

    def prepare_regular_provider_install(self):
        self.pack()
        self.prepare_host()
        self.env["TEST_MODULES"] = str(self.package / MOD)
        self.stub("curl", '''
case "$*" in
  *raw.githubusercontent.com/thomaskien/kienzlefax-fuer-linux/refs/heads/main/installer-modular/*)
    case "${2##*/}" in
      pjsip-provider.sh|extensions.sh|telefonie-queue.sh) exec cp "$TEST_MODULES/${2##*/}" "$4" ;;
    esac ;;
  *faxton.mp3) echo "Testton" > "$3"; exit 0 ;;
esac
echo "$*" >> "$TEST_BLOCKED"; exit 90''')
        for script in self.cache.glob("*.sh"):
            if script.name in ("pjsip-provider.sh", "extensions.sh", "telefonie-queue.sh"):
                script.unlink()
            else:
                script.write_text("exit 0\n")

    def assert_trunk(self, filename, registration, endpoint, domain, user, number, *,
                     proxy="", client="", from_user="", password, expiration="300", identify=""):
        text = (self.host / "etc/asterisk" / filename).read_text()

        def section(name):
            blocks = re.findall(r"^\[" + re.escape(name) + r"\]\n((?:[^\[\n][^\n]*\n|\n)*)", text, re.M)
            self.assertEqual(len(blocks), 1, name)
            return dict(line.split("=", 1) for line in blocks[0].splitlines()
                        if "=" in line and not line.startswith(";"))

        reg = section(registration)
        ep = section(endpoint)
        auth = section(reg["outbound_auth"])
        aor = section(ep["aors"])
        self.assertEqual([reg["type"], auth["type"], aor["type"], ep["type"]],
                         ["registration", "auth", "aor", "endpoint"])
        self.assertEqual(reg["endpoint"], endpoint)
        self.assertEqual(reg["line"], "yes")
        self.assertEqual(ep["outbound_auth"], reg["outbound_auth"])
        self.assertEqual(reg["server_uri"], "sip:" + domain)
        self.assertEqual(aor["contact"], reg["server_uri"])
        self.assertEqual(reg["client_uri"], client or f"sip:{user}@{domain}")
        self.assertEqual(reg["contact_user"], number)
        self.assertEqual(reg["expiration"], expiration)
        self.assertEqual(auth["username"], user)
        self.assertEqual(auth["password"], password.replace("\\", "\\\\").replace(";", "\\;"))
        self.assertEqual(ep["from_user"], from_user or user)
        self.assertEqual(ep["from_domain"], domain)
        self.assertEqual(ep["context"], "kfx-provider-in")
        for obj in (reg, ep, aor):
            self.assertEqual(obj.get("outbound_proxy", ""), proxy)
        identify_name = reg["outbound_auth"].removesuffix("-auth") + "-identify"
        if identify:
            match = section(identify_name)
            self.assertEqual((match["endpoint"], match["match"]), (endpoint, identify))
        else:
            self.assertNotIn(f"\n[{identify_name}]\n", text)

    def regular_provider_roundtrip(self, fax_provider, phone_provider, separate_provider=None):
        self.prepare_regular_provider_install()
        secret = r'Test$mit;"A\B`'
        fax_did, phone_did, out_did = "49305550101", "49305550102", "49305550103"
        # In- und Ausgang unterscheiden, damit ein vertauschter Provider auffaellt.

        def inputs(provider, role, number):
            if provider == "fonial":
                return ["Plusnet", role, number, secret, secret, "", "", "", "420",
                        f"sip:client-{role}@other.invalid", "from-" + role]
            return ["6", role, number, secret, secret, "custom.invalid" if role == "out" else "",
                    "", "-" if role == "out" else "", ""]

        fax = inputs(fax_provider, "fax", fax_did)
        phone = inputs(phone_provider, "phone", phone_did)
        run_options = ["", "", "", "n", *([""] * 6), "n", "y", "n"]
        answers = ["fax-test", "n", fax[0], "", *fax[1:], "y", "", "", "1", "1",
                   "", "", "", "y", "", "", "", "", "1", "n", *phone]
        if separate_provider:
            answers += ["y", *inputs(separate_provider, "out", out_did), "y"]
        else:
            answers += ["n"]
        output = self.shell(self.package / MAIN, answers=[*answers, "n", *run_options, ""])
        self.assertNotIn(secret, output)
        self.assertEqual(self.envfile.stat().st_mode & 0o777, 0o600)
        self.assertIn(f'KFX_PHONE_IN_PROVIDER="{phone_provider}"', self.envfile.read_text())
        out_provider = separate_provider or phone_provider
        self.assertIn(f'KFX_PHONE_OUT_PROVIDER="{out_provider}"', self.envfile.read_text())

        def check(provider, role, did, filename, reg, endpoint):
            if provider == "fonial":
                options = dict(domain="sip.plusnet.de", proxy=r"sip:sbc.sip.plusnet.de\;lr",
                               expiration="420", client=f"sip:client-{role}@other.invalid",
                               from_user="from-" + role)
            else:
                domain = "custom.invalid" if role == "out" else "b.vsip.eu"
                options = dict(domain=domain, identify="" if role == "out" else domain)
            self.assert_trunk(filename, reg, endpoint, user=role, number=did, password=secret, **options)

        check(fax_provider, "fax", fax_did, "pjsip.conf", "kfx-provider", "kfx-provider-endpoint")
        check(phone_provider, "phone", phone_did, "pjsip-kfx-telefonie.conf", "kfx-phone-in-registration",
              "kfx-phone-in-endpoint")
        if separate_provider:
            check(separate_provider, "out", out_did, "pjsip-kfx-telefonie.conf", "kfx-phone-out-registration",
                  "kfx-phone-out-endpoint")
        etc = self.host / "etc/asterisk"
        incoming = (etc / "extensions.conf").read_text()
        self.assertIn('exten => _+X.,1,Goto(kfx-provider-in,${EXTEN:1},1)', incoming)
        self.assertIn(f'exten => {fax_did},1,Goto(fax-in,{fax_did},1)', incoming)
        self.assertIn(f'exten => {phone_did},1,Goto(kfx-phone-in,s,1)', incoming)
        self.assertIn('Set(NORM=0${EXTEN:2})', incoming)
        self.assertIn('Dial(PJSIP/${NORM}@kfx-provider-endpoint', incoming)
        phone_dialplan = (etc / "extensions-kfx-telefonie.conf").read_text()
        self.assertEqual('exten => _49X.,1,Goto(0${EXTEN:2},1)' in phone_dialplan, out_provider == "voip2gsm")
        self.assertEqual('exten => _0049X.,1,Goto(0${EXTEN:4},1)' in incoming, fax_provider == "voip2gsm")
        out_role = "out" if separate_provider else "in"
        self.assertIn(f'Dial(PJSIP/${{EXTEN}}@kfx-phone-{out_role}-endpoint,120)', phone_dialplan)

        generated = {path: path.read_bytes() for path in etc.glob("*.conf")}
        # Eine aus Asterisk uebernommene vollstaendige Proxy-URI soll dasselbe
        # Ergebnis haben wie der Hostname. Die ENV bleibt shell-quotiert.
        settings = self.envfile.read_text()
        self.assertIn('="sbc.sip.plusnet.de"', settings)
        self.envfile.write_text(settings.replace('="sbc.sip.plusnet.de"', r"='sip:sbc.sip.plusnet.de\\;lr'"))
        if separate_provider:
            stale = self.cache / "telefonie-queue.sh"
            stale.write_text("# alter Cache ohne Providerprofile\nexit 91\n")
            output = self.shell(self.package / MAIN, answers=["n", *run_options], success=False)
            self.assertIn("Modulcache: telefonie-queue.sh", output)
            self.assertNotIn("Module ausführen", output)
        # Regulärer Updatepfad mit separat bestätigtem Austausch der drei Generatoren.
        self.shell(self.package / MAIN, answers=["n", "y", "y", "y", *run_options[3:]])
        for path, data in generated.items():
            self.assertEqual(path.read_bytes(), data, path.name)
        # Alle Providerwerte beim erneuten Durchlaufen des Dialogs übernehmen.
        # Erwartet: nur eine Bestätigung pro gespeichertem Passwort.
        reset = [
            "y", "", "",                      # neu setzen, Hostname, Vollinstallation
            "", "", "", "", "",               # Faxprovider, FQDN, Auth-ID, Nummer, Passwort behalten
            "", "", "", "",                   # Registrar, Proxy, Identify, Expiration
        ]
        if fax_provider == "fonial":
            reset += ["", ""]                 # Client-URI, From-User
        reset += [
            "", "", "", "1", "1", "", "", "",  # Adminpasswort, DID, Kopfzeile, Drucker, SIP/RTP
            "", "", "", "", "", "", "",       # Queue, Kanalgrenzen, Telefone, internes Netz
            *([""] * 8),                      # Phone-IN inkl. Passwort behalten
        ]
        if phone_provider == "fonial":
            reset += ["", ""]
        reset += [""]                         # Wahl der Ausgangsleitung beibehalten
        if separate_provider:
            reset += [""] * (9 + (2 if separate_provider == "fonial" else 0))  # Phone-OUT und Kanalzählung
        output = self.shell(self.package / MAIN, answers=[*reset, "", "", *run_options, ""])
        self.assertNotIn(secret, output)
        for path, data in generated.items():
            self.assertEqual(path.read_bytes(), data, path.name)

    def test_fonial_fax_and_voip2gsm_phone(self):
        self.regular_provider_roundtrip("fonial", "voip2gsm")

    def test_voip2gsm_fax_and_separate_phone_trunks(self):
        self.regular_provider_roundtrip("voip2gsm", "fonial", separate_provider="voip2gsm")

    def test_voip2gsm_fax_and_phone_on_same_registrar_with_fonial_outbound(self):
        self.regular_provider_roundtrip("voip2gsm", "voip2gsm", separate_provider="fonial")

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
        write(self.envfile, "KFX_QUEUE_ONLY=y\nKFX_PROVIDER=none\nKFX_SIP_USER=\nKFX_SIP_DOMAIN=\n"
              "KFX_PHONE_IN_PROVIDER=\nKFX_PHONE_IN_SIP_DOMAIN=\nKFX_PHONE_IN_SIP_EXPIRATION=\n"
              "KFX_PHONE_ENDPOINT_201_PASSWORD=test-bestand\n")
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
        self.shell(self.package / MAIN, "--kombi", answers=["n", "n", *PHONE_ANSWERS[:6], *([""] * 8), "n", "n", "n", "n", "y", "n"])
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
