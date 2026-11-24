#!/usr/bin/env bash
# =============================================================================
#  📈 Portfolio Performance – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/PortfolioPerformance-Proxmox
#
#  Portfolio Performance (portfolio-performance.info, EPL-2.0) ist eine
#  GTK-Desktop-App (Eclipse RCP, Java 21) – KEINE native Server-/Web-App.
#  Damit man "überall im Browser" darauf zugreifen kann, läuft PP hier in
#  einem Container unter einem virtuellen Bildschirm (Xvfb) und wird per
#  noVNC (HTML5-VNC) im Browser ausgeliefert:
#
#    • Volle PP-GUI im Browser – von überall erreichbar (Port +0)
#    • Xvfb + openbox + PortfolioPerformance + x11vnc + noVNC
#    • PP-eigene REST-API (lo 5712, standardmäßig AUS) zusätzlich per
#      nginx-Proxy erreichbar (Port +1) – für HA/Skripte/Automation.
#      Die REST-API lauscht nur auf Loopback und lehnt nicht-lokale Host-
#      Header + Origin-Header ab; der Proxy schreibt Host -> localhost und
#      entfernt Origin, damit Aufrufe von außerhalb durchgehen.
#
#  Architektur im Container (Debian 13):
#    portfolio-performance-gui.service : Xvfb + openbox + PP + x11vnc + noVNC
#    nginx (REST-Proxy)                : :REST_PORT -> 127.0.0.1:5712 (Host-Rewrite)
#
#  WICHTIG / Grenzen (ehrlich):
#    • PP ist Single-User: eine Desktop-Instanz, die du per Browser fernbedienst.
#      Kein Multi-User-Webserver, keine native Mobile-App-Synchronisierung.
#    • Die REST-API muss EINMAL in PP aktiviert werden (Preferences →
#      "MCP Server & REST API" → Haken setzen). Der Proxy steht sofort, ohne
#      aktivierte API liefert er 502. Das Aktivieren/Pairing machst du im noVNC.
#    • Die PP-eigene "Web Server"-Mobile-Sync-Komponente steckt NICHT im
#      offiziellen Release und wird hier nicht versprechen können.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PortfolioPerformance-Proxmox/main/install/portfolio-performance.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096
#
#  Update / Deinstall / Status / Debug:
#    ... " --update  |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"
APP_NAME="portfolio"            # Kurzname (Logs, Services heißen portfolio*)
APP_PRETTY="Portfolio Performance"
CT_HOSTNAME="portfolio"         # CT bekommt den passenden Namen
# Hinweis: Repo-Koordinaten stehen nur im Einzeiler/oben im Kopf, nicht als
# Variablen – dieser Installer lädt KEINEN App-Code aus einem eigenen Repo,
# sondern Portfolio Performance direkt aus dem offiziellen PP-Release.

# Portfolio Performance selbst kommt als offizielles GitHub-Release (tar.gz).
PP_OWNER="portfolio-performance"
PP_REPO="portfolio"
PP_VERSION="latest"             # "latest" oder z. B. "0.90.0"
PP_TARBALL_URL=""               # wird zur Laufzeit (arch-bewusst) ermittelt

CT_ID=""                        # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_STORAGE="local-lvm"
CT_ROOTFS=10                    # GB – Debian + Java + WebKitGTK + PP
CT_CORES=2
CT_MEMORY=4096                  # MB – Java 21 + PP + Xvfb
CT_SWAP=2048
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""                   # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""                  # leer = automatisch generieren
CT_SSHKEY=""                    # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""
PORT=8081                       # noVNC-Port (PP-GUI im Browser)
REST_PORT=8082                  # nginx-Proxy -> PP-REST-API (127.0.0.1:5712)
VNC_PASSWORD=""                 # leer = automatisch generiert
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PortfolioPerformance-Proxmox/main/install/portfolio-performance.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + GUI):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/portfolio-setup.log 2>/dev/null
            echo "--- journalctl -u portfolio-performance-gui ---"
            journalctl -u portfolio-performance-gui --no-pager 2>/dev/null | tail -n 25
            echo "--- nginx error.log ---"
            tail -n 20 /var/log/nginx/error.log 2>/dev/null
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # NAME ist Spalte 2 (pct list: VMID(1) NAME(2) STATUS(3) ...)
    if pct list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # NAME ist Spalte 2 – NICHT $NF (das wäre die PID).
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$2==h {print $1; exit}'
}

get_ct_ip() {
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).
  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1
  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

# ── Release-Auflösung (offizielles PP-Release, arch-bewusst) ───────────────
host_arch() {
    # Host-Architektur bestimmt Template UND PP-Binary (x86_64 / aarch64).
    local a
    a=$(dpkg --print-architecture 2>/dev/null || uname -m || true)
    case "$a" in
        amd64|x86_64) echo "x86_64" ;;
        arm64|aarch64) echo "aarch64" ;;
        *) echo "$a" ;;
    esac
}

resolve_release() {
    # Ermittelt die arch-passende Linux-gtk-tar.gz-URL des PP-Releases.
    if [[ -n "$PP_TARBALL_URL" ]]; then
        info "Release-URL ist vorgegeben: $PP_TARBALL_URL"
        return 0
    fi
    local arch
    arch=$(host_arch)
    info "Host-Architektur: $arch"
    local api="https://api.github.com/repos/${PP_OWNER}/${PP_REPO}/releases"
    if [[ "$PP_VERSION" == "latest" ]]; then
        api="${api}/latest"
    else
        api="${api}/tags/${PP_VERSION}"
    fi

    header "📦 Portfolio Performance Release auflösen"
    info "Quelle: $api"
    local json
    json=$(curl -fsSL --retry 3 --retry-delay 2 \
           -H 'Accept: application/vnd.github+json' "$api") \
        || die "GitHub-API nicht erreichbar ($api).
  Offline-Installation: PP_TARBALL_URL=<direkte Asset-URL> ${ONE_LINER}"
    local urls tag
    urls=$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' \
           | sed 's/.*": *"//; s/"$//' || true)
    tag=$(printf '%s\n' "$json" | grep -m1 -o '"tag_name": *"[^"]*"' \
           | sed 's/.*": *"//; s/"$//' || true)
    [[ -n "$tag" ]] && PP_VERSION="${tag#v}"

    PP_TARBALL_URL=$(printf '%s\n' "$urls" \
        | grep -E -- "-linux\.gtk\.${arch}\.tar\.gz$" | head -1 || true)
    if [[ -z "$PP_TARBALL_URL" ]]; then
        die "Im Release ${PP_VERSION} wurde kein Linux-gtk-${arch}-tar.gz gefunden.
  Verfügbare Linux-Assets:
$(printf '%s\n' "$urls" | grep -E -- 'linux' | sed 's/^/    /')"
    fi
    local asc_url
    asc_url="${PP_TARBALL_URL}.asc"
    if printf '%s\n' "$urls" | grep -qxF "$asc_url"; then
        PP_ASC_URL="$asc_url"
    else
        PP_ASC_URL=""
    fi
    info "Tarball: $PP_TARBALL_URL"
    ok "Portfolio Performance ${PP_VERSION} (${arch})"
    return 0
}

# ── Templatewahl ───────────────────────────────────────────────────────────
template_for_debian() {
    local major="$1"
    pveam list local 2>/dev/null \
        | grep -E "debian-${major}[^ ]*standard" \
        | sort -V | tail -1 | awk '{print $1}'
}

ensure_template() {
    local major="$1" tpl=""
    tpl=$(template_for_debian "$major")
    if [[ -z "$tpl" ]]; then
        info "Kein Debian-${major}-Template lokal – lade es herunter ..."
        pveam update >/dev/null 2>&1 || true
        local avail
        avail=$(pveam available 2>/dev/null \
                | grep -E "debian-${major}[^ ]*standard" | tail -1 | awk '{print $2}' || true)
        if [[ -z "$avail" ]]; then
            return 1
        fi
        pveam download local "$avail" >/dev/null 2>&1 || return 1
        tpl=$(template_for_debian "$major")
    fi
    if [[ -z "$tpl" ]]; then
        return 1
    fi
    echo "$tpl"
}

ensure_ct_running() {
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rest-port)     REST_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --vnc-password)  VNC_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --version)       PP_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --pp-url)        PP_TARBALL_URL="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Ports hart validieren – sie landen direkt im systemd-Service/nginx.
    local p
    for p in "$PORT" "$REST_PORT"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [[ "$p" -lt 1 || "$p" -gt 65535 ]]; then
            die "Ungültiger Port: '$p' (1–65535 erwartet, z. B. --port 8081)"
        fi
    done
    if [[ "$PORT" == "$REST_PORT" ]]; then
        die "noVNC-Port und REST-Proxy-Port dürfen nicht gleich sein ($PORT)."
    fi
}

print_help() {
    cat <<'EOF'
📈 Portfolio Performance – Proxmox-Installer

Wichtig: Portfolio Performance ist eine GTK-Desktop-App (Java 21), KEINE native
Server-/Web-App. Dieser Installer betreibt die volle PP-GUI im Container unter
Xvfb und liefert sie per noVNC im Browser aus – von überall erreichbar.
PP ist Single-User (eine Desktop-Instanz, die du per Browser fernbedienst).

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/PortfolioPerformance-Proxmox/main/install/portfolio-performance.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: portfolio)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 10)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 4096)
  --swap MB        Swap (Default: 2048)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      noVNC-Port (PP-GUI im Browser, Default: 8081)
  --rest-port PORT REST-Proxy-Port der PP-REST-API (Default: 8082)
  --vnc-password PW  VNC-Passwort für noVNC (Default: automatisch generiert)
  --version VER    PP-Version fixieren (Default: latest, z. B. 0.90.0)
  --pp-url URL     Direkte PP-Release-Asset-URL (überspringt GitHub-API)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         Container aktualisieren (neueste PP-Version + Services)
  --uninstall      Container stoppen und löschen
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug

Nach der Installation (siehe Zusammenfassung):
  • noVNC (volle PP-GUI im Browser):  http://<CT-IP>:<PORT>/vnc.html
  • REST-API-Proxy (für HA/Skripte):  http://<CT-IP>:<REST_PORT>/v1  (nach Aktivierung)
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte kommen als Umgebungsvariablen via `pct exec -- env …` in den Container.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Portfolio Performance In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: PORT, REST_PORT, VNC_PASSWORD, PP_TARBALL_URL, PP_VERSION,
#                    HOST_DNS, PP_ASC_URL, PP_SIGNER_FPR
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

err(){ echo "✘ $1" >&2; }
warn(){ echo "⚠  $1" >&2; }
die(){ err "$1"; exit 1; }

: "${PORT:?PORT fehlt (env)}"
: "${REST_PORT:?REST_PORT fehlt (env)}"
: "${PP_TARBALL_URL:?PP_TARBALL_URL fehlt (env)}"
: "${PP_VERSION:?PP_VERSION fehlt (env)}"
: "${HOST_DNS:?HOST_DNS fehlt (env)}"
APP_USER="${APP_USER:-portfolio}"
APP_ROOT=/opt/portfolio-performance
PP_HOME="${APP_ROOT}/pp"          # entpacktes PP (portfolio/…)

echo ">>> Grundpakete + Java 21 + GTK/WebKit + Xvfb/noVNC installieren ..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl wget gnupg >/dev/null
# PP braucht Java 21, GTK3, WebKitGTK 4.1 (für SWT). GUI-Stack: Xvfb, x11vnc,
# noVNC, openbox, nginx (REST-Proxy). Debian 13 (trixie) liefert openjdk-21.
if ! apt-get install -y -qq openjdk-21-jre-headless libgtk-3-0 libwebkit2gtk-4.1-0 \
        xvfb x11vnc novnc websockify openbox x11-utils \
        libgl1-mesa-dri fonts-dejavu-core nginx >/dev/null; then
    die "Paketinstallation fehlgeschlagen. Läuft der Container auf Debian 13 (trixie)?
  WebKitGTK 4.1 + openjdk-21 gibt es dort; auf Debian 12 nicht.
  Neu anlegen:  pct stop ${APP_USER:-portfolio} && pct destroy <id> --purge"
fi
command -v java >/dev/null 2>&1 || die "java (openjdk-21) nicht installiert – apt prüfen."
command -v Xvfb >/dev/null 2>&1 || die "Xvfb nicht installiert – apt prüfen."

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# PP: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' \
    > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' \
    "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Portfolio Performance ${PP_VERSION} herunterladen ..."
curl -fSL --retry 3 "${PP_TARBALL_URL}" -o /tmp/pp.tar.gz
TARBALL_NAME=$(basename "${PP_TARBALL_URL}")
# GPG-Signatur prüfen (offizieller PP-Key), wenn .asc verfügbar.
if [ -n "${PP_ASC_URL:-}" ]; then
    echo ">>> GPG-Signatur prüfen (${TARBALL_NAME}.asc) ..."
    curl -fSL --retry 3 "${PP_ASC_URL}" -o /tmp/pp.tar.gz.asc
    gpg --keyserver hkps://keys.openpgp.org --recv-keys "${PP_SIGNER_FPR}" \
        >/dev/null 2>&1 || \
        { gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "${PP_SIGNER_FPR}" \
              >/dev/null 2>&1 || true; }
    if gpg --list-keys "${PP_SIGNER_FPR}" >/dev/null 2>&1; then
        gpg --verify /tmp/pp.tar.gz.asc /tmp/pp.tar.gz \
            || die "GPG-Signatur von Portfolio Performance ist ungültig – Abbruch."
        echo "    GPG-Signatur gültig (Key ${PP_SIGNER_FPR})."
    else
        warn "Öffentlicher PP-Schlüssel nicht abrufbar – GPG-Prüfung übersprungen."
    fi
else
    warn "Keine .asc-Signatur am Release – GPG-Prüfung übersprungen."
fi

echo ">>> Entpacken nach ${PP_HOME} ..."
rm -rf "${PP_HOME}"
mkdir -p "${PP_HOME}"
tar -xzf /tmp/pp.tar.gz -C "${PP_HOME}" --strip-components=1
[ -x "${PP_HOME}/PortfolioPerformance" ] \
    || die "PortfolioPerformance-Executable fehlt im Tarball. Inhalt: $(ls "${PP_HOME}" | tr '\n' ' ')"

# ── Benutzer & Rechte ──────────────────────────────────────────────────────
id -u "${APP_USER}" &>/dev/null \
    || useradd --system --create-home --home-dir "${APP_ROOT}/home" \
        --shell /usr/sbin/nologin "${APP_USER}"
mkdir -p "${APP_ROOT}/home" "${APP_ROOT}/data" "${APP_ROOT}/bin" "${APP_ROOT}/log"
chown -R "${APP_USER}:${APP_USER}" "${APP_ROOT}"

# ── VNC-Passwort ───────────────────────────────────────────────────────────
if [ -n "${VNC_PASSWORD:-}" ]; then
    printf '%s\n' "${VNC_PASSWORD}" > "${APP_ROOT}/.vncpass.txt"
else
    printf '%s\n' "$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)" \
        > "${APP_ROOT}/.vncpass.txt"
fi
chmod 600 "${APP_ROOT}/.vncpass.txt"
x11vnc -storepasswd "$(cat "${APP_ROOT}/.vncpass.txt")" "${APP_ROOT}/.vncpass" >/dev/null 2>&1 \
    || die "x11vnc-Passwortdatei konnte nicht erzeugt werden."
chown "${APP_USER}:${APP_USER}" "${APP_ROOT}/.vncpass" "${APP_ROOT}/.vncpass.txt"

# ── GUI-Skript: Xvfb + openbox + PP + x11vnc + noVNC ────────────────────────
cat > "${APP_ROOT}/bin/portfolio-gui.sh" <<GUIEOF
#!/usr/bin/env bash
# Startet Portfolio Performance unter Xvfb und reicht den Bildschirm per noVNC
# weiter. Läuft als systemd-Service portfolio-performance-gui; beendet beim Stop
# alle Kinder.
set -uo pipefail
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
export HOME="${APP_ROOT}/home"
LOG=${APP_ROOT}/log/portfolio-gui.log
PIDS=()
cleanup() {
    local p
    for p in "\${PIDS[@]:-}"; do
        kill "\$p" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

: "\${NOVNC_DIR:?NOVNC_DIR fehlt}"
: "\${GUI_PORT:?GUI_PORT fehlt}"

Xvfb :99 -screen 0 1600x1000x24 -ac +extension GLX +render -noreset >>"\$LOG" 2>&1 &
PIDS+=(\$!)
for _ in \$(seq 1 20); do
    xdpyinfo -display :99 >/dev/null 2>&1 && break
    sleep 0.5
done
xdpyinfo -display :99 >/dev/null 2>&1 || { echo "Xvfb startet nicht:"; tail -n 20 "\$LOG"; exit 1; }

command -v openbox >/dev/null && { openbox >>"\$LOG" 2>&1 & PIDS+=(\$!); }

# Portfolio Performance starten. -name setzt den Applikationsnamen; das
# Workspace-/Datenverzeichnis liegt unter HOME, damit es persistent ist.
"${PP_HOME}/PortfolioPerformance" >>"\$LOG" 2>&1 &
PIDS+=(\$!)

x11vnc -display :99 -forever -shared -rfbauth ${APP_ROOT}/.vncpass \
    -rfbport 5900 -quiet >>"\$LOG" 2>&1 &
PIDS+=(\$!)
sleep 1

# websockify bleibt im Vordergrund – systemd überwacht genau diesen Prozess.
exec websockify --web="\$NOVNC_DIR" "\${GUI_PORT}" localhost:5900
GUIEOF
chmod 0755 "${APP_ROOT}/bin/portfolio-gui.sh"

NOVNC_DIR=$(dpkg -L novnc 2>/dev/null | grep -m1 '/vnc.html$' | xargs -r dirname)
if [ -z "${NOVNC_DIR:-}" ] || [ ! -f "${NOVNC_DIR}/vnc.html" ]; then
    die "noVNC-Webroot nicht gefunden (Paket novnc installiert?)."
fi

echo ">>> systemd-Service portfolio-performance-gui installieren ..."
cat > /etc/systemd/system/portfolio-performance-gui.service <<UNITEOF
[Unit]
Description=Portfolio Performance GUI – PP im Browser (Xvfb + noVNC)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
Environment=NOVNC_DIR=${NOVNC_DIR}
Environment=GUI_PORT=${PORT}
ExecStart=${APP_ROOT}/bin/portfolio-gui.sh
Restart=always
RestartSec=8
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNITEOF

# ── nginx: REST-API-Proxy (loopback-only 5712 -> extern) ────────────────────
# Die PP-REST-API lauscht NUR auf 127.0.0.1 und lehnt nicht-lokale Host-Header
# sowie Origin-Header ab. Der Proxy schreibt Host -> localhost, entfernt Origin
# und reicht von extern nach 127.0.0.1:5712 durch. (API muss in PP aktiviert
# sein, sonst antwortet 5712 nicht -> 502.)
echo ">>> nginx-REST-Proxy (:${REST_PORT} -> 127.0.0.1:5712) installieren ..."
cat > /etc/nginx/sites-available/portfolio-rest <<NGINXEOF
server {
    listen ${REST_PORT};
    listen [::]:${REST_PORT};
    server_name _;
    # Etwas größere Body-Grenze für evtl. JSON-Imports.
    client_max_body_size 16m;
    location / {
        proxy_pass http://127.0.0.1:5712;
        proxy_http_version 1.1;
        # PP verlangt Host: localhost – sonst 403 "must be addressed as localhost".
        proxy_set_header Host localhost;
        # Origin entfernen – PP lehnt Requests mit Origin-Header ab.
        proxy_set_header Origin "";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_read_timeout 300s;
    }
}
NGINXEOF
ln -sf /etc/nginx/sites-available/portfolio-rest /etc/nginx/sites-enabled/portfolio-rest
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || die "nginx-Konfiguration ist ungültig (nginx -t oben prüfen)."

systemctl daemon-reload
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
systemctl enable portfolio-performance-gui >/dev/null 2>&1
systemctl restart portfolio-performance-gui

echo ">>> Prüfe noVNC ..."
NOVNC_OK=""
for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/vnc.html"; then
        NOVNC_OK=1
        break
    fi
    sleep 1
done
if [ -n "$NOVNC_OK" ]; then
    echo "    noVNC antwortet auf Port ${PORT}."
else
    warn "noVNC antwortet (noch) nicht auf Port ${PORT}.
  Logs: journalctl -u portfolio-performance-gui -e && tail -n 30 ${APP_ROOT}/log/portfolio-gui.log"
fi

echo ">>> Aufräumen ..."
rm -f /tmp/pp.tar.gz /tmp/pp.tar.gz.asc 2>/dev/null || true

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Portfolio Performance im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert)
    local host_dns
    host_dns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    pct exec "$ct_id" -- env \
        PORT="$PORT" \
        REST_PORT="$REST_PORT" \
        VNC_PASSWORD="${VNC_PASSWORD:-}" \
        PP_TARBALL_URL="$PP_TARBALL_URL" \
        PP_VERSION="$PP_VERSION" \
        PP_ASC_URL="${PP_ASC_URL:-}" \
        PP_SIGNER_FPR="E46E6F8FF02E4C83569084589239277F560C95AC" \
        HOST_DNS="${host_dns:-1.1.1.1}" \
        APP_USER="$APP_NAME" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/portfolio-setup.log'
}

get_installed_version() {
    local v=""
    v=$(pct exec "$1" -- sh -c 'grep -m1 -oE "[0-9]+\.[0-9]+\.[0-9]+" /var/log/portfolio-setup.log 2>/dev/null || true' 2>/dev/null | head -n 1 || true)
    echo "$v"
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0

    header "✅ Verifikation"

    # GUI-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet portfolio-performance-gui 2>/dev/null; then
            ok "Service portfolio-performance-gui läuft (noVNC auf Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service portfolio-performance-gui läuft nicht.
  Debug: pct exec $ct_id -- journalctl -u portfolio-performance-gui -e
         pct exec $ct_id -- tail -n 40 /opt/portfolio-performance/log/portfolio-gui.log"
        fi
        sleep 1
    done

    # noVNC ausgeliefert?
    tries=0
    local code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${PORT}/vnc.html" || true)
        if [[ "$code" == "200" ]]; then
            ok "noVNC liefert vnc.html (HTTP 200 auf Port $PORT)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "noVNC antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).
  Debug: pct exec $ct_id -- journalctl -u portfolio-performance-gui -e"
        fi
        sleep 1
    done

    # PP-Executable vorhanden?
    if pct exec "$ct_id" -- test -x /opt/portfolio-performance/pp/PortfolioPerformance 2>/dev/null; then
        ok "PortfolioPerformance-Executable vorhanden"
    else
        die "pp/PortfolioPerformance fehlt im Container.
  Debug: pct exec $ct_id -- tail -n 40 /var/log/portfolio-setup.log"
    fi

    # nginx-REST-Proxy aktiv? (API selbst evtl. noch aus -> 502 ist ok,
    # solange nginx läuft und die Config gültig ist.)
    if pct exec "$ct_id" -- systemctl is-active --quiet nginx 2>/dev/null; then
        ok "nginx-REST-Proxy läuft (Port $REST_PORT -> 127.0.0.1:5712)"
    else
        warn "nginx läuft nicht – REST-API-Proxy nicht erreichbar.
  Logs: pct exec $ct_id -- journalctl -u nginx -e"
    fi

    # Erreichbarkeit vom PROXMOX-HOST aus
    local ct_ip="" nc_code="" rest_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        nc_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                  "http://${ct_ip}:${PORT}/vnc.html" || true)
        if [[ "$nc_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${PORT}/vnc.html (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${nc_code:-000} über http://${ct_ip}:${PORT}/vnc.html)."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
        # REST-Proxy: 502/504 ist OK solange die API in PP noch nicht aktiviert
        # ist; wir melden nur, was kommt.
        rest_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${REST_PORT}/v1/version" || true)
        case "$rest_code" in
            200) ok "REST-API antwortet bereits (HTTP 200 auf :$REST_PORT/v1/version)" ;;
            401) ok "REST-API erreichbar (HTTP 401 = API aktiv, Token/Pairing steht noch aus)" ;;
            502|503|504) info "REST-Proxy läuft, aber PP-REST-API ist in PP noch NICHT aktiviert (HTTP ${rest_code}) – in PP unter Preferences → „MCP Server & REST API“ aktivieren." ;;
            *) warn "REST-Proxy: HTTP ${rest_code:-unbekannt} von http://${ct_ip}:${REST_PORT}/v1/version" ;;
        esac
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🏛️  Portfolio Performance ist bereit!"
    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    local novnc_url="http://${ct_ip:-<CT-IP>}:${PORT}/vnc.html"
    local rest_url="http://${ct_ip:-<CT-IP>}:${REST_PORT}/v1"

    cat <<SUM

  ${GREEN}Portfolio Performance läuft als Desktop-App im Container und wird
  im Browser ausgeliefert. Voller Zugriff von überall.${NC}

  ${BOLD}🌐 Zugriff im Browser (noVNC – volle PP-GUI)${NC}
     URL:        ${novnc_url}
     VNC-PW:     ${VNC_PASSWORD:-<leer – im Container unter /opt/portfolio-performance/.vncpass.txt>}

  ${BOLD}🔌 REST-API (optional, für Home Assistant / Skripte / Automation)${NC}
     Proxy-URL:  ${rest_url}
     • In PP EINMAL aktivieren:  Preferences → „MCP Server & REST API“
       → „Enable MCP server and REST API (localhost only)“ anhaken,
       Port 5712 (Default) belassen, gewünschte Datei freigeben + speichern.
     • Danach Token per Pairing holen (siehe README): POST ${rest_url%/v1}/v1/auth/requests
     • Ohne Aktivierung liefert der Proxy 502 – das ist erwartet.

  ${BOLD}🔄 Verwaltung (auf dem Proxmox-Host)${NC}
     Status:     ${ONE_LINER} --status
     Update:     ${ONE_LINER} --update
     Deinstall:  ${ONE_LINER} --uninstall

  ${BOLD}ℹ Hinweise${NC}
     • PP ist Single-User – eine Desktop-Instanz, die du im Browser fernbedienst.
     • Die offizielle Mobile-App synchronisiert über eine „Web Server“-Komponente,
       die NICHT im Release steckt – dieser Installer bietet daher noVNC + REST-API.
     • Web-Frontend läuft über Software-Rendering (llvmpipe) – für flüssiges
       Scrollen in PP reicht das; kein 3D-Bedarf.
SUM
}

# ── Installation ───────────────────────────────────────────────────────────
do_install() {
    header "📈 ${APP_PRETTY} – Installation"

    # Vorhandenen Container mit gleichem Hostname erkennen
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.
  Update:         ${ONE_LINER} --update
  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian 13 (trixie) nötig: openjdk-21 + WebKitGTK 4.1.
    header "🧱 Container-Template"
    local template=""
    template=$(ensure_template 13 || true)
    if [[ -z "$template" ]]; then
        die "Debian 13 (trixie) ist nicht verfügbar – es wird für openjdk-21 +
  WebKitGTK 4.1 (PP-GUI) zwingend benötigt.
  Prüfe: pveam available | grep 'debian-13'"
    fi
    ok "Template: $template"

    # Release auflösen (arch-passendes tar.gz)
    resolve_release

    # ID & Passwörter
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="portfolio-$(date +%s)"
        fi
    fi
    if [[ -z "$VNC_PASSWORD" ]]; then
        VNC_PASSWORD=$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)
        if [[ -z "$VNC_PASSWORD" ]]; then
            VNC_PASSWORD="portfolio-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "$template" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update ${APP_PRETTY}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.
  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"
    resolve_release

    # VNC-Passwort beim Update beibehalten, nicht stillrotieren.
    if [[ -z "$VNC_PASSWORD" ]]; then
        VNC_PASSWORD=$(pct exec "$ct_id" -- cat /opt/portfolio-performance/.vncpass.txt 2>/dev/null | head -1 || true)
    fi

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – deine PP-Datei unter /opt/portfolio-performance/home blieb erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere ${APP_PRETTY}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "Deine Portfolio-Datei (unter /opt/portfolio-performance/home) geht verloren."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.
  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id gelöscht."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status ${APP_PRETTY}"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    pct list 2>/dev/null | awk -v id="$ct_id" -v st="$state" '$1==id {print "Container:  " $1 " (" $2 ") – " st}'

    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet portfolio-performance-gui 2>/dev/null; then
        ok "Service:   portfolio-performance-gui läuft (noVNC auf Port $PORT)"
    else
        err "Service:   portfolio-performance-gui läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u portfolio-performance-gui -e"
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet nginx 2>/dev/null; then
        ok "Service:   nginx (REST-Proxy auf Port $REST_PORT) läuft"
    else
        warn "Service:   nginx läuft NICHT (REST-Proxy nicht erreichbar)"
    fi

    local ip novnc_code="" rest_code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        novnc_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${PORT}/vnc.html" || true)
        if [[ "$novnc_code" == "200" ]]; then
            ok "noVNC:     http://${ip}:${PORT}/vnc.html  (HTTP 200)"
        else
            warn "noVNC:     HTTP-Code ${novnc_code:-unbekannt} von http://${ip}:${PORT}/vnc.html"
        fi
        rest_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${REST_PORT}/v1/version" || true)
        case "$rest_code" in
            200|401) ok "REST-API:  http://${ip}:${REST_PORT}/v1  erreichbar (HTTP ${rest_code})" ;;
            502|503|504) info "REST-API:  Proxy läuft, PP-API in PP noch nicht aktiviert (HTTP ${rest_code})" ;;
            *) warn "REST-API:  HTTP-Code ${rest_code:-unbekannt} von http://${ip}:${REST_PORT}/v1/version" ;;
        esac
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi