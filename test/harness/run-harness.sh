#!/usr/bin/env bash
# =============================================================================
#  Mock-Harness für install/portfolio-performance.sh
#
#  Führt den Installer OHNE Proxmox aus: pct/pveam/curl/openssl werden durch
#  Attrappen ersetzt, die Aufrufe protokollieren und einen Container spielen.
#  So lassen sich Create-Argumente, ID-Vergabe, Setup-Übergabe, Verifikation
#  und Zusammenfassung automatisiert prüfen.
#
#  Aufruf:  bash test/harness/run-harness.sh [--keep]
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
INSTALLER="$REPO/install/portfolio-performance.sh"

if [[ "$(id -u)" -ne 0 ]]; then
    if command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
        exec unshare -rm bash "$0" "$@"
    fi
    printf '✘ Harness braucht root-Rechte (oder unshare -rm): bitte mit sudo starten.\n' >&2
    exit 1
fi

# Phils Profil exportiert grep als ugrep-Funktion – im Harness stört das.
unset -f grep 2>/dev/null || true

PASS=0
FAIL=0
KEEP="${1:-}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[0;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✔\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[0;31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

check()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has()     { grep -qF -- "$2" "$1"; }

# ── Sandbox vorbereiten ────────────────────────────────────────────────────
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pp-harness.XXXXXX")
cleanup() {
    if [[ "$KEEP" == "--keep" ]]; then
        say ""
        say "Sandbox bleibt erhalten: $ROOT"
    else
        rm -rf "$ROOT"
    fi
}
trap cleanup EXIT

FAKEBIN="$ROOT/bin"
mkdir -p "$FAKEBIN"
for tool in pct pveam curl openssl; do
    ln -sf "$HERE/mocks/$tool" "$FAKEBIN/$tool"
done

run_installer() {
    local name="$1"; shift
    local state="$ROOT/state-$name"
    mkdir -p "$state"
    touch "$state/pct.log" "$state/pveam.log" "$state/curl.log"
    (
        cd "$REPO" || exit 1
        MOCK_STATE="$state" \
        PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            bash "$INSTALLER" "$@"
    ) >"$state/out.log" 2>&1
    echo "$?"
}

# ── 1. Syntax ──────────────────────────────────────────────────────────────
step "Syntaxprüfung"
check "bash -n install/portfolio-performance.sh" bash -n "$INSTALLER"
check "keine CRLF-Zeilen" bash -c "! grep -q $'\r' '$INSTALLER'"

# ── 1b. Einzeiler/Repo-Name (Regressionsschutz gegen falschen Repo-Namen) ──
step "Einzeiler & Repo-Name"
check "Installer: kein falscher Name 'PortfolioPerformance-Proxmox'" bash -c "! grep -q 'PortfolioPerformance-Proxmox' '$INSTALLER'"
check "Installer: ONE_LINER mit korrektem Repo-Namen" bash -c "grep -q 'raw.githubusercontent.com/HatchetMan111/PortfolioPerformanceProxmox/main/install/portfolio-performance.sh' '$INSTALLER'"
check "README: kein falscher Name 'PortfolioPerformance-Proxmox'" bash -c "! grep -q 'PortfolioPerformance-Proxmox' '$REPO/README.md'"
check "README: Einzeiler mit korrektem Repo-Namen" bash -c "grep -q 'raw.githubusercontent.com/HatchetMan111/PortfolioPerformanceProxmox/main/install/portfolio-performance.sh' '$REPO/README.md'"

# ── 2. Normalfall ──────────────────────────────────────────────────────────
step "Installation (Normalfall)"
RC=$(run_installer normal --yes --password TestPasswort1234)
S="$ROOT/state-normal"
check "Exit-Code 0" test "$RC" -eq 0
if [[ "$RC" -ne 0 ]]; then
    say "--- Ausgabe ---"
    tail -n 40 "$S/out.log" | sed 's/^/    /'
fi

check "Container wurde erzeugt" test -f "$S/ct-created"
CT_ID=$(cat "$S/ct-created" 2>/dev/null || echo "")
check "nächste freie ID = 200 (199 ist belegt)" test "$CT_ID" = "200"

if [[ -f "$S/create.args" ]]; then
    ARGS=$(cat "$S/create.args")
    check "unprivilegiert" bash -c "grep -q -- '--unprivileged 1' <<<'$ARGS'"
    check "onboot=1" bash -c "grep -q -- '--onboot 1' <<<'$ARGS'"
    check "hostname portfolio" bash -c "grep -q -- '--hostname portfolio' <<<'$ARGS'"
    check "2 vCPU" bash -c "grep -q -- '--cores 2' <<<'$ARGS'"
    check "4096 MB RAM" bash -c "grep -q -- '--memory 4096' <<<'$ARGS'"
    check "rootfs 10 GB" bash -c "grep -qE -- '--rootfs local-lvm:10' <<<'$ARGS'"
    check "Bridge vmbr0" bash -c "grep -q -- 'bridge=vmbr0' <<<'$ARGS'"
    check "DHCP-IP" bash -c "grep -q -- 'ip=dhcp' <<<'$ARGS'"
    check "Passwort gesetzt" bash -c "grep -q -- '--password TestPasswort1234' <<<'$ARGS'"
    check "Debian-13-Template" bash -c "grep -q 'debian-13' <<<'$ARGS'"
    check "Template nach Host-Arch gefiltert (_amd64)" bash -c "grep -q '_amd64' <<<'$ARGS'"
    check "NICHT das arm64-Template genommen" bash -c "! grep -q '_arm64' <<<'$ARGS'"
else
    bad "pct-create-Argumente wurden nicht protokolliert"
fi

check "Setup-Script in den Container geschoben" test -f "$S/pushed-inner.sh"
if [[ -f "$S/exec.env" ]]; then
    ENV_=$(tr '\n' ' ' <"$S/exec.env")
    check "PORT=8081 übergeben" bash -c "grep -qF -- 'PORT=8081' <<<'$ENV_'"
    check "REST_PORT=8082 übergeben" bash -c "grep -qF -- 'REST_PORT=8082' <<<'$ENV_'"
    check "PP-URL übergeben" bash -c "grep -qF -- 'linux.gtk.x86_64.tar.gz' <<<'$ENV_'"
    check "PP_ASC_URL übergeben" bash -c "grep -qF -- '.tar.gz.asc' <<<'$ENV_'"
    check "GPG-Fingerprint übergeben" bash -c "grep -qF -- 'PP_SIGNER_FPR=' <<<'$ENV_'"
else
    bad "exec.env fehlt – pct exec wurde nicht wie erwartet aufgerufen"
fi

check "noVNC-URL im Log" has "$S/out.log" "vnc.html"
check "REST-URL im Log" has "$S/out.log" ":8082/v1"
check "Erfolgsmeldung im Log" has "$S/out.log" "Portfolio Performance ist bereit"
check "Single-User-Hinweis im Log" has "$S/out.log" "Single-User"
check "REST-Aktivierungshinweis im Log" has "$S/out.log" "MCP Server"
check "Update-Einzeiler im Log" has "$S/out.log" "--update"
check "Uninstall-Einzeiler im Log" has "$S/out.log" "--uninstall"

if [[ -f "$S/pushed-inner.sh" ]]; then
    INNER="$S/pushed-inner.sh"
    check "Inner-Script ist syntaktisch gültig" bash -n "$INNER"
    check "Inner-Script installiert Java 21" has "$INNER" "openjdk-21-jre-headless"
    check "Inner-Script installiert WebKitGTK 4.1" has "$INNER" "libwebkit2gtk-4.1-0"
    check "Inner-Script prüft GPG-Signatur" has "$INNER" "gpg --verify"
    check "Inner-Script startet Xvfb" has "$INNER" "Xvfb :99"
    check "Inner-Script startet PP" has "$INNER" "PortfolioPerformance"
    check "Inner-Script nutzt x11vnc" has "$INNER" "x11vnc"
    check "Inner-Script nutzt websockify" has "$INNER" "websockify"
    check "Inner-Script schreibt Host: localhost im nginx" has "$INNER" "proxy_set_header Host localhost"
    check "Inner-Script entfernt Origin" has "$INNER" 'proxy_set_header Origin'
    check "Inner-Script nginx-Proxy auf 5712" has "$INNER" "127.0.0.1:5712"
    check "Inner-Script systemd-Unit" has "$INNER" "portfolio-performance-gui.service"
    check "Inner-Script aktiviert Boot-Start" has "$INNER" "systemctl enable portfolio-performance-gui"
fi

# ── 3. Zweiter Lauf (Idempotenz) ───────────────────────────────────────────
step "Zweiter Lauf ohne --force"
RC=$(run_installer normal --yes --password TestPasswort1234)
check "Lauf 2 scheitert mit Hinweis" test "$RC" -ne 0
check "Meldung 'existiert bereits'" has "$S/out.log" "existiert bereits"

# ── 4. --status ────────────────────────────────────────────────────────────
step "--status"
mkdir -p "$ROOT/state-status"
echo "200" >"$ROOT/state-status/ct-created"
touch "$ROOT/state-status/nginx-installed"
MOCK_STATE="$ROOT/state-status" \
PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash "$INSTALLER" --status >"$ROOT/state-status/out.log" 2>&1
RC=$?
check "Status-Exit 0" test "$RC" -eq 0
check "Status zeigt GUI-Service" has "$ROOT/state-status/out.log" "portfolio-performance-gui läuft"
check "Status zeigt nginx" has "$ROOT/state-status/out.log" "nginx"
check "Status zeigt noVNC HTTP 200" has "$ROOT/state-status/out.log" "vnc.html"
check "Status zeigt REST HTTP 401" has "$ROOT/state-status/out.log" "REST-API"

# ── 5. --uninstall ─────────────────────────────────────────────────────────
step "--uninstall --yes"
mkdir -p "$ROOT/state-uninstall"
echo "200" >"$ROOT/state-uninstall/ct-created"
MOCK_STATE="$ROOT/state-uninstall" \
PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash "$INSTALLER" --uninstall --yes >"$ROOT/state-uninstall/out.log" 2>&1
RC=$?
check "Uninstall-Exit 0" test "$RC" -eq 0
check "pct destroy wurde gerufen" has "$ROOT/state-uninstall/pct.log" "destroy 200"
check "Container ist weg" test ! -f "$ROOT/state-uninstall/ct-created"

# ── 6. Port-Kollision ──────────────────────────────────────────────────────
step "Port-Kollision wird abgelehnt"
RC=$(run_installer portcol --yes --port 9000 --rest-port 9000)
check "Kollision Exit != 0" test "$RC" -ne 0
check "Fehlermeldung 'dürfen nicht gleich'" has "$ROOT/state-portcol/out.log" "dürfen nicht gleich"

# ── 7. Individuelle Ports ──────────────────────────────────────────────────
step "Individuelle Ports (--port / --rest-port)"
RC=$(run_installer ports --yes --port 9001 --rest-port 9002 --password TestPasswort1234)
P="$ROOT/state-ports"
check "Ports-Exit 0" test "$RC" -eq 0
check "PORT=9001 übergeben" has "$P/exec.env" "PORT=9001"
check "REST_PORT=9002 übergeben" has "$P/exec.env" "REST_PORT=9002"
check "noVNC-URL nutzt 9001" has "$P/out.log" ":9001/vnc.html"
check "REST-URL nutzt 9002" has "$P/out.log" ":9002/v1"
check "Summary: keine rohen ESC-Codes im Log" bash -c "! grep -qF '\\033' '$P/out.log'"
check "Summary: Einzeiler wird genau 1x ausgegeben" bash -c "test \"\$(grep -cF 'wget -qLO -' '$P/out.log')\" -eq 1"
check "Summary: Container-Zeile mit IP" has "$P/out.log" "läuft"

# ── 7b. WebDAV (Mobile-App-Sync) ───────────────────────────────────────────
step "WebDAV aktiv (--webdav-port 8083)"
RC=$(run_installer webdav --yes --password TestPasswort1234 --webdav-port 8083)
W="$ROOT/state-webdav"
check "WebDAV-Exit 0" test "$RC" -eq 0
check "WEBDAV_PORT=8083 übergeben" has "$W/exec.env" "WEBDAV_PORT=8083"
check "WEBDAV_USER übergeben" has "$W/exec.env" "WEBDAV_USER=portfolio"
check "WEBDAV_PASSWORD übergeben" has "$W/exec.env" "WEBDAV_PASSWORD="
check "Inner-Script: rclone serve webdav" has "$W/pushed-inner.sh" "rclone serve webdav"
check "Inner-Script: portfolio-webdav.service" has "$W/pushed-inner.sh" "portfolio-webdav.service"
check "WebDAV-URL im Log" has "$W/out.log" ":8083/"

step "WebDAV-Port kollidiert mit noVNC-Port"
RC=$(run_installer wdcol --yes --password TestPasswort1234 --webdav-port 8081)
check "Kollision Exit != 0" test "$RC" -ne 0
check "Fehlermeldung 'kollidiert'" has "$ROOT/state-wdcol/out.log" "kollidiert"

# ── 8. Spawn-Fehler wird erkannt (Arch-Mismatch-Falle) ─────────────────────
step "Spawn-Fehler (pct create Exit 0, aber CT läuft nicht)"
SP="$ROOT/state-spawnfail"
mkdir -p "$SP"
touch "$SP/pct.log" "$SP/pveam.log" "$SP/curl.log"
: >"$SP/fail-spawn"   # pct-Mock meldet 'stopped' statt 'running'
(
    cd "$REPO" || exit 1
    MOCK_STATE="$SP" \
    PATH="$FAKEBIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        bash "$INSTALLER" --yes --password TestPasswort1234
) >"$SP/out.log" 2>&1
RC=$?
check "Spawn-Fehler Exit != 0" test "$RC" -ne 0
check "Meldung 'läuft NICHT'" has "$SP/out.log" "läuft NICHT"
check "Arch-Diagnose im Log" has "$SP/out.log" "Host-Architektur"

# ── 9. --help ──────────────────────────────────────────────────────────────
step "--help"
bash "$INSTALLER" --help >"$ROOT/help.log" 2>&1
check "Hilfe zeigt Einzeiler" has "$ROOT/help.log" 'bash -c "$(wget -qLO -'
check "Hilfe erklärt --port" has "$ROOT/help.log" "--port"
check "Hilfe erklärt --rest-port" has "$ROOT/help.log" "--rest-port"
check "Hilfe erklärt --webdav-port" has "$ROOT/help.log" "--webdav-port"
check "Hilfe erklärt --version" has "$ROOT/help.log" "--version"

# ── Ergebnis ───────────────────────────────────────────────────────────────
printf '\n\033[1mErgebnis: %d grün, %d rot\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]