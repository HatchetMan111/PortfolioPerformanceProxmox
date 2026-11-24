# 📈 Portfolio Performance – Proxmox-Installer

> ## ⚠️ Lese das zuerst: PP ist eine Desktop-App, kein Web-Server
>
> [Portfolio Performance](https://www.portfolio-performance.info) (EPL-2.0) ist
> eine **GTK-Desktop-App** (Eclipse RCP, Java 21) – **keine native Server-/
> Web-Anwendung**. Es gibt keinen offiziellen Headless-/Web-Modus, den man
> einfach als Dienst startet.
>
> Dieser Installer betreibt deshalb die **volle PP-GUI im Container** unter
> einem virtuellen Bildschirm (Xvfb) und liefert sie per **noVNC** im Browser
> aus – so erreichst du dein Portfolio **von überall im Browser**.
>
> | Weg | Was du bekommst | Anmerkung |
> |---|---|---|
> | 🌐 **noVNC (Hauptkanal)** | Volle PP-GUI im Browser, Port **8081** | Single-User – eine Instanz, die du fernbedienst |
> | 🔌 **REST-API (optional)** | PP-interne REST-API per nginx-Proxy, Port **8082** | Für Home Assistant / Skripte / MCP – muss in PP aktiviert werden |
> | 📱 **Mobile-App-Sync** | – | Die „Web Server“-Komponente steckt **nicht** im offiziellen Release; nicht Teil dieses Installers |
>
> **PP ist Single-User:** eine Desktop-Instanz, die du im Browser fernbedienst.
> Kein Multi-User-Webserver. Mehrere Personen gleichzeitig bedienen klappt nicht
> sinnvoll (sie sitzen am selben Desktop).

---

## Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PortfolioPerformance-Proxmox/main/install/portfolio-performance.sh)"
```

Der Installer legt einen **unprivilegierten Debian-13-Container** an, lädt das
offizielle [Portfolio-PPerformance-Release](https://github.com/portfolio-performance/portfolio/releases)
(arch-passend, GPG-signiert), installiert Java 21 + GTK/WebKit + Xvfb/noVNC und
richtet zwei systemd-Dienste ein:

- `portfolio-performance-gui` – Xvfb + openbox + PP + x11vnc + noVNC (Port 8081)
- `nginx` – REST-Proxy :8082 → 127.0.0.1:5712 (Host-Rewrite, Origin entfernt)

### Optionen (hinter dem schließenden Anführungszeichen anhängen)

```
  --id ID           Container-ID (Default: nächste freie ab 200)
  --hostname NAME   Container-Hostname (Default: portfolio)
  --memory MB       RAM (Default: 4096)
  --rootfs GB       Disk (Default: 10)
  --cores N         vCPUs (Default: 2)
  --ip CIDR         Statt DHCP (mit --gateway)
  --port PORT       noVNC-Port (Default: 8081)
  --rest-port PORT  REST-Proxy-Port (Default: 8082)
  --vnc-password PW VNC-Passwort (Default: automatisch generiert)
  --version VER     PP-Version fixieren (Default: latest)
  --sshkey PFAD     Public-Key für root-Login im CT
  --force           Vorhandenen CT (gleicher Hostname) neu anlegen
  --yes / -y        Rückfragen überspringen
```

Beispiel:

```bash
... " --id 210 --memory 6144 --vnc-password "meinGeheimesVNCpw"
```

> ### ⚠️ Falls „Container hat nach 60 s keine IP bekommen“
>
> Ursache ist fast immer die **Architektur-Falle**: ein `pct create --start 1`
> meldet **Exit 0, auch wenn der Container gar nicht startet** (z. B. wenn
> versehentlich das `arm64`-Template auf einem `x86_64`-Host erwischt wird –
> Fehler steht nur auf stderr: `sync_wait … Failed to spawn`). Der Installer
> prüft deshalb nach dem Anlegen aktiv, ob der Container wirklich `running` ist,
> und wählt das Template **arch-bewusst** (`_amd64` auf x86_64, `_arm64` auf
> arm64).
>
> Wenn du trotzdem landest (z. B. nach einem abgebrochenen Alt-Lauf):
>
> ```bash
> pct stop 204 && pct destroy 204 --purge
> # dann Installer erneut starten (er nimmt nun die nächste freie ID):
> bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PortfolioPerformanceProxmox/main/install/portfolio-performance.sh)"
> ```

---

## Zugriff

Nach der Installation zeigt die Zusammenfassung die exakten URLs. Beispiel:

- **noVNC (volle PP-GUI im Browser):** `http://<CT-IP>:8081/vnc.html`
  → VNC-Passwort eingeben (steht in der Zusammenfassung bzw. im Container
  unter `/opt/portfolio-performance/.vncpass.txt`).
- **REST-API-Proxy:** `http://<CT-IP>:8082/v1`

Beim ersten Start öffnet PP den Willkommens-/Datei-dialog. Lege dort deine
`.portfolio`-Datei an (liegt dann persistent unter
`/opt/portfolio-performance/home`) – sie bleibt über Neustarts und Updates
erhalten.

### REST-API aktivieren (optional, für HA/Skripte/MCP)

Die PP-REST-API ist **standardmäßig aus** und lauscht nur auf Loopback. Der
nginx-Proxy reicht von außen nach `127.0.0.1:5712` durch und schreibt dabei den
Host-Header auf `localhost` (sonst lehnt PP mit „must be addressed as localhost“
ab) und entfernt den `Origin`-Header (Requests mit Origin weist PP zurück).

So aktivierst du sie:

1. Im noVNC-Fenster: **Preferences → „MCP Server & REST API“**
2. **„Enable MCP server and REST API (localhost only)“** anhaken,
   Port **5712** belassen, die gewünschte Datei freigeben + **speichern**.
3. Danach per Pairing einen Token holen (Antwort enthält `pairingEndpoint`):

   ```bash
   curl -s -X POST -d '{"clientName":"Home Assistant"}' \
     http://<CT-IP>:8082/v1/auth/requests
   # → {"id":"…","status":"pending"}
   # In PP den Zugriff bestätigen, dann:
   curl -s http://<CT-IP>:8082/v1/auth/requests/<id>
   # → {"status":"approved","token":"…"}
   ```

   Den Token bei jedem Aufruf als `Authorization: Bearer <token>` mitschicken.
   Vor der Aktivierung liefert der Proxy HTTP 502 – das ist erwartet.

---

## Verwaltung (auf dem Proxmox-Host)

```bash
... " --status       # Container, Services, noVNC/REST-Erreichbarkeit
... " --update       # neueste PP-Version + Services neu einrichten
... " --uninstall    # Container löschen (Achtung: PP-Datei geht verloren)
... " --debug        # voller bash -x-Trace
```

---

## Grenzen & Ehrlichkeit

- **Single-User.** PP ist eine Desktop-App. Dieser Installer macht sie im
  Browser erreichbar, verwandelt sie aber nicht in einen Multi-User-Dienst.
- **Software-Rendering.** noVNC läuft über Xvfb/llvmpipe – zum Scrollen und
  Bedienen von PP reicht das; PP braucht keine 3D-Beschleunigung.
- **Kein Mobile-App-Sync.** Die offizielle „Portfolio Performance Mobile“-App
  synchronisiert über eine „Web Server“-Komponente, die **nicht** im
  offiziellen Release-Tarball steckt. Der Installer bietet daher **noVNC**
  (Browser-Zugriff) + **REST-API** (Automation) – nicht die App-Synchronisierung.
- **GPG-Verifikation** erfolgt gegen den offiziellen PP-Schlüssel
  (`E46E6F8FF02E4C83569084589239277F560C95AC`, Andreas Buchen). Ist der Key nicht
  abrufbar, warnt der Installer und überspringt die Prüfung.

---

## Lizenz

Der Installer-Code in diesem Repo steht unter der MIT-Lizenz (siehe `LICENSE`).
Portfolio Performance selbst ist EPL-2.0 – siehe das
[Projekt](https://github.com/portfolio-performance/portfolio).