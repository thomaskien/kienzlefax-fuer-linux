# Asterisk-Fax (ReceiveFAX/SendFAX) mit SpanDSP – Installation & Kompilierung (Asterisk 20.x)

Diese Notizen fassen die **minimal notwendigen Module/Abhängigkeiten** zusammen, um in Asterisk
Fax über **res_fax + res_fax_spandsp (SpanDSP)** nutzen zu können (z.B. `ReceiveFAX()` / `SendFAX()`).

Besonders relevant, wenn Asterisk **selbst kompiliert** wurde und beim Fax z.B. erscheint:

- `Could not locate a FAX technology module with capabilities (RECEIVE)`

Dann ist meist **res_fax_spandsp** nicht gebaut oder nicht geladen.

---

## 1) Voraussetzungen / Pakete (Debian/Ubuntu)

Ziel: SpanDSP + Build-Toolchain + Asterisk Build-Prereqs

~~~bash
sudo apt update
sudo apt install -y \
  build-essential git pkg-config autoconf automake libtool \
  libxml2-dev libncurses5-dev libedit-dev uuid-dev \
  libssl-dev libsqlite3-dev \
  libsrtp2-dev \
  wget curl ca-certificates
~~~

### SpanDSP Build-Abhängigkeiten

Je nach Distribution/Version ist SpanDSP bereits als `libspandsp-dev` verfügbar – oft aber in zu alter Version.
Empfehlung: SpanDSP aus Source bauen.

~~~bash
sudo apt install -y libtiff-dev
~~~

---

## 2) SpanDSP aus Source bauen (empfohlen)

Asterisk prüft beim `./configure` u.a. auf `t38_terminal_init` etc.
Diese Symbole müssen in deiner SpanDSP-Version vorhanden sein.

~~~bash
cd /usr/src
sudo git clone https://github.com/freeswitch/spandsp.git
cd spandsp
sudo ./bootstrap.sh
sudo ./configure
sudo make -j"$(nproc)"
sudo make install
sudo ldconfig
~~~

### Check: SpanDSP ist im System sichtbar

~~~bash
pkg-config --modversion spandsp || echo "spandsp pkg-config nicht gefunden"
ldconfig -p | grep -i spandsp || echo "spandsp nicht in ldconfig"
~~~

---

## 3) Asterisk vorbereiten & konfigurieren

### Asterisk Source holen (Beispiel 20.18.2)

~~~bash
cd /usr/src
sudo wget http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-20.18.2.tar.gz
sudo tar xzf asterisk-20.18.2.tar.gz
cd asterisk-20.18.2
~~~

### Optional: MP3-Unterstützung

~~~bash
sudo contrib/scripts/get_mp3_source.sh
~~~

### Configure (SpanDSP-Erkennung prüfen)

~~~bash
sudo ./configure
~~~

SpanDSP-Check prüfen:

~~~bash
sudo ./configure | grep -i spandsp || true
~~~

Du willst im Output sehen, dass SpanDSP gefunden wird, z.B.:

~~~
checking for minimum version of SpanDSP... yes
checking for t38_terminal_init in -lspandsp... yes
~~~

Wenn hier `no` steht: SpanDSP fehlt / zu alt / nicht im Linkerpfad.

---

## 4) Module auswählen: res_fax + res_fax_spandsp

~~~bash
sudo make menuselect
~~~

Aktivieren (mit `[ * ]`):

- **Resource Modules**
  - `res_fax`
  - `res_fax_spandsp`
    
**bei mir hiess das irgendwie anders aber spandsp war irgendwo in der liste!**

- `res_pjsip`
- `res_rtp_asterisk` (meist ohnehin aktiv)

Hinweis:

> `res_fax` allein reicht nicht.  
> Asterisk braucht ein **FAX Technology Modul** (SpanDSP oder Digium-Fax).  
> Für Open-Source: `res_fax_spandsp`.

Speichern & beenden.

---

## 5) Bauen & Installieren

~~~bash
sudo make -j"$(nproc)"
sudo make install
sudo make samples
sudo make config
sudo ldconfig
~~~

Asterisk neu starten:

~~~bash
sudo systemctl restart asterisk
~~~

---

## 6) Laufzeit-Checks in der Asterisk-CLI

~~~bash
sudo asterisk -rvvvvv
~~~

### Prüfen, ob Fax-Module geladen sind

~~~text
module show like fax
~~~

Erwartet u.a.:

- `res_fax.so`
- `res_fax_spandsp.so`

### Prüfen, ob Fax-Technologie verfügbar ist

~~~text
fax show capabilities
~~~

Bei `RECEIVE` / `SEND` sollte z.B. **SpanDSP** erscheinen.

---

## 7) Minimaler Dialplan-Test für Empfang

~~~ini
; extensions.conf (Beispiel)

[fax-in]
exten => 4923319265247,1,NoOp(Inbound Fax)
 same => n,Answer()
 same => n,Set(FAXOPT(ecm)=no)
 same => n,Set(FAXOPT(maxrate)=9600)
 same => n,ReceiveFAX(/var/spool/asterisk/fax/${STRFTIME(${EPOCH},,%Y%m%d-%H%M%S)}.tif)
 same => n,Hangup()
~~~

---

## 8) Typische Fehler & schnelle Ursachen

### Fehler: „Could not locate a FAX technology module …“

Ursachen:

- `res_fax_spandsp` nicht gebaut oder nicht geladen
- SpanDSP nicht erkannt (zu alt / fehlt / Linkerpfad)

Fix:

- SpanDSP korrekt installieren (`make install`, `ldconfig`)
- Asterisk `./configure` erneut laufen lassen und SpanDSP-Checks prüfen
- `make menuselect` → `res_fax_spandsp` aktivieren → neu bauen

### Fehler: Modul ist gebaut, aber wird nicht geladen

Ursachen:

- `modules.conf` blockiert via `noload`
- Autoload deaktiviert
- falsches Installationsprefix / alte Module im Pfad

Check:
im asterisk! "asterisk -rvvv"
~~~text
module show like spandsp
module load res_fax_spandsp.so
~~~

---

## 9) Fax in PDF umwandeln (tiff2pdf)

~~~bash
sudo apt install -y libtiff-tools
~~~

Beispiel:

~~~bash
tiff2pdf -o fax.pdf fax.tif
~~~
