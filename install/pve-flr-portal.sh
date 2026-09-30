#!/usr/bin/env bash
#
# pve-flr-portal Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      File Level Restore Portal for Proxmox Backup Server (PBS FLR Timeline + File-Browser)
# Upstream: https://github.com/treycentric/pve-flr-portal
# Stack:    Python/FastAPI + Uvicorn (HTTPS :8008, Self-Signed), venv /opt/pve-flr-portal/.venv,
#           ohne Docker, ohne Cloud. run.py bindet 0.0.0.0 (Haupt-Listener + opt. DNT-Listener).
# Läuft:    vollständig lokal im LXC, keine externen Cloud-Dienste nötig
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"
#   CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"
#   PVE_HOST=192.168.178.2 PVE_STORAGE=pbs bash pve-flr-portal.sh   # PVE-Zugang direkt setzen (ohne Abfrage)
#   bash pve-flr-portal.sh --ctid 150 --cores 1 --memory 1024 --disk 4 --bridge vmbr0 --debug
#
# Installer-Repo: https://github.com/HatchetMan111/FileLevelRestoreProxmox
# (install/ + systemd/ + README.md liegen dort; Upstream-App bleibt treycentric.)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="pve-flr-portal"                          # Container-Hostname + Service-Name
APP_PORT="8008"                               # Web UI (HTTPS, Self-Signed)
APP_PROTO="https"                             # Upstream serviert HTTPS by default (run.py)
UPSTREAM_REPO="https://github.com/treycentric/pve-flr-portal"
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/FileLevelRestoreProxmox}"
SERVICE_URL="${SERVICE_URL:-https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/systemd/pve-flr-portal.service}"
# SERVICE_URL ist nur Best-Effort: Die funktionierende Unit liegt inline weiter
# unten (Restart=always, reboot-sicher) und wird genommen, falls der Download
# scheitert oder ein Template mit __PLATZHALTER__ liefert.

DEFAULT_CORES="1"                             # vCPU (1 reicht, 2 bei vielen parallelen Restores)
DEFAULT_RAM="1024"                            # RAM in MB (FastAPI + Helper-VM-Calls)
DEFAULT_SWAP="512"                            # Swap (MB)
DEFAULT_DISK="4"                              # Disk in GB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie (Upstream: Debian 12)
UNPRIVILEGED="1"                              # 1 = unprivilegiert
FEATURES="nesting=1"                          # nesting=1 für pip/venv Robustheit

APP_USER="pveflr"
APP_DIR="/opt/pve-flr-portal"
VENV_DIR="/opt/pve-flr-portal/.venv"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=2048 DISK=8 ./pve-flr-portal.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
# PVE-Zugang für die App-.env (ohne diese scheitert jeder Login mit HTTP 500,
# da PVE_HOST dann nicht auflösbar ist – siehe Troubleshooting in README.md):
# per Flag, per ENV oder interaktiv (nur bei TTY) – sonst Platzhalter + Warnung.
PVE_HOST_ARG="${PVE_HOST:-}"
PVE_STORAGE_ARG="${PVE_STORAGE:-pbs}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash pve-flr-portal.sh [OPTIONEN]
  CT_ID=150 bash pve-flr-portal.sh
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --pve-host IP/NAME   PVE-Host für die App (Default: ENV PVE_HOST, sonst Abfrage)
  --pve-storage ID     PBS-Storage-ID für die App (Default: ENV PVE_STORAGE oder 'pbs', sonst Abfrage)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG="" PVE_HOST="$PVE_HOST_ARG" PVE_STORAGE_ID="$PVE_STORAGE_ARG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --pve-host) PVE_HOST="$2"; shift 2;;
    --pve-storage) PVE_STORAGE_ID="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 1b. PVE-Zugang für die App-.env (ohne gültigen PVE_HOST scheitert jeder
#     Login mit HTTP 500: "Name or service not known" im Journal)
# ---------------------------------------------------------------------------
# Reihenfolge: Flag/ENV > interaktive Abfrage (nur bei TTY, kein Hängen bei
# Pipe/CI) > Platzhalter aus .env.example + fette Warnung am Ende.
if [[ -z "$PVE_HOST" ]]; then
  if [[ -t 0 ]]; then
    DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    PVE_INPUT=""
    read -r -p "  PVE_HOST – IP/Hostname des Proxmox-Hosts für die App-API [${DETECTED_IP:-keine erkannt}]: " PVE_INPUT || true
    PVE_HOST="${PVE_INPUT:-${DETECTED_IP:-}}"
  fi
  [[ -z "$PVE_HOST" ]] && msg_warn "Kein PVE_HOST angegeben (nicht-interaktiv?) – .env behält den Platzhalter, Login wird mit HTTP 500 scheitern!"
fi
if [[ -t 0 ]]; then
  STORAGE_INPUT=""
  read -r -p "  PVE_STORAGE – PBS-Storage-ID für die App [${PVE_STORAGE_ID}]: " STORAGE_INPUT || true
  PVE_STORAGE_ID="${STORAGE_INPUT:-$PVE_STORAGE_ID}"
fi
[[ -n "$PVE_HOST" ]] && msg_info "PVE_HOST=$PVE_HOST  PVE_STORAGE=$PVE_STORAGE_ID"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for _ in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. pve-flr-portal im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere pve-flr-portal im Container (nativ, ohne Docker) ..."
# Hinweis: äußere Single-Quotes – der Block läuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping nötig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3 python3-venv python3-pip openssl
  id pveflr >/dev/null 2>&1 || useradd --system --home-dir /opt/pve-flr-portal --shell /usr/sbin/nologin pveflr
  # CVE-2022-24765: git verweigert "dubious ownership" als fremder User –
  # --system gilt für root UND pveflr nach dem chown weiter unten.
  git config --system --add safe.directory /opt/pve-flr-portal 2>/dev/null || true
  if [ ! -d /opt/pve-flr-portal/.git ]; then
    rm -rf /opt/pve-flr-portal
    git clone https://github.com/treycentric/pve-flr-portal.git /opt/pve-flr-portal
  else
    git -C /opt/pve-flr-portal fetch --tags --quiet
    # Upstream-Release-Kanal: neuestes vX.Y.Z-Tag, sonst main (vgl. deploy/lxc-create.sh)
    TAG=$(git -C /opt/pve-flr-portal tag -l "v*.*.*" --sort=-v:refname | head -1 || true)
    if [ -n "$TAG" ]; then
      git -C /opt/pve-flr-portal checkout --quiet "$TAG"
    else
      git -C /opt/pve-flr-portal checkout --quiet main || true
    fi
    git -C /opt/pve-flr-portal pull --ff-only || true
  fi
  if [ ! -x /opt/pve-flr-portal/.venv/bin/python ]; then
    python3 -m venv /opt/pve-flr-portal/.venv
  fi
  /opt/pve-flr-portal/.venv/bin/pip install --quiet --upgrade pip
  /opt/pve-flr-portal/.venv/bin/pip install --quiet -r /opt/pve-flr-portal/requirements.txt
  if [ ! -f /opt/pve-flr-portal/.env ]; then
    cp /opt/pve-flr-portal/.env.example /opt/pve-flr-portal/.env
    echo "HINWEIS: /opt/pve-flr-portal/.env wurde aus .env.example angelegt – PVE_HOST/PVE_STORAGE anpassen!"
  fi
  chown -R pveflr:pveflr /opt/pve-flr-portal
'
# Hinweis: bewusst kein '| tail' hier – mit pipefail würde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# PVE-Zugang in die App-.env schreiben (VOR enable --now, damit der erste
# Start schon die richtige Config hat). pct exec ohne Shell – die Host-Seite
# expandiert $PVE_HOST/$PVE_STORAGE_ID direkt als sed-Argumente.
if [[ -n "$PVE_HOST" ]]; then
  pct exec "$CT_ID" -- sed -i "s|^PVE_HOST=.*|PVE_HOST=${PVE_HOST}|" /opt/pve-flr-portal/.env
  msg_ok "PVE_HOST=${PVE_HOST} in Container-.env gesetzt."
fi
if [[ -n "$PVE_STORAGE_ID" ]]; then
  pct exec "$CT_ID" -- sed -i "s|^PVE_STORAGE=.*|PVE_STORAGE=${PVE_STORAGE_ID}|" /opt/pve-flr-portal/.env
  msg_ok "PVE_STORAGE=${PVE_STORAGE_ID} in Container-.env gesetzt."
fi

# systemd-Unit aus Repo übernehmen (fällt auf Inline-Unit zurück).
# Upstream-Template enthält __APP_DIR__/__APP_USER__-Platzhalter und
# Restart=on-failure – wir brauchen konkrete Pfade + Restart=always.
UNIT_OK=0
if pct exec "$CT_ID" -- curl -fsSL -o /tmp/pve-flr-portal.service.dl "$SERVICE_URL" 2>/dev/null; then
  if pct exec "$CT_ID" -- grep -q "__APP_DIR__" /tmp/pve-flr-portal.service.dl 2>/dev/null; then
    msg_warn "Service-Template enthält Platzhalter – rendere mit echten Pfaden."
    pct exec "$CT_ID" -- bash -c "sed 's#__APP_DIR__#/opt/pve-flr-portal#g; s#__APP_USER__#pveflr#g' /tmp/pve-flr-portal.service.dl > /etc/systemd/system/pve-flr-portal.service"
    UNIT_OK=1
  else
    pct exec "$CT_ID" -- bash -c "cp /tmp/pve-flr-portal.service.dl /etc/systemd/system/pve-flr-portal.service"
    UNIT_OK=1
  fi
  msg_ok "pve-flr-portal.service aus Repo übernommen."
fi
if [[ "$UNIT_OK" != "1" ]]; then
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit (Restart=always)."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/pve-flr-portal.service <<UNIT
[Unit]
Description=File Level Restore Portal for Proxmox Backup Server (pve-flr-portal)
Documentation=https://github.com/treycentric/pve-flr-portal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pveflr
Group=pveflr
WorkingDirectory=/opt/pve-flr-portal
Environment=PYTHONUNBUFFERED=1
Environment=PFR_DATA_DIR=%S/pve-flr-portal
ExecStart=/opt/pve-flr-portal/.venv/bin/python run.py
Restart=always
RestartSec=5
StateDirectory=pve-flr-portal
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/pve-flr-portal
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now pve-flr-portal

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI (HTTPS, Self-Signed)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active pve-flr-portal || { msg_error "systemd-Service pve-flr-portal ist nicht active."; pct exec "$CT_ID" -- systemctl status pve-flr-portal --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active pve-flr-portal = active)."

msg_info "Warte auf Web UI (max. 3 Min, HTTPS Self-Signed -> curl -k) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -kfs -m 10 "https://localhost:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf https://localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status pve-flr-portal --no-pager || true; pct exec "$CT_ID" -- journalctl -u pve-flr-portal --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTPS 200 auf localhost:${APP_PORT}/, -k wegen Self-Signed)."

# PVE-API vom Container aus erreichbar? Genau dieser Call (auth.login) war es,
# der bei unkonfiguriertem PVE_HOST jeden Login mit HTTP 500 scheitern ließ
# ("Name or service not known"). Darum harter Check mit klarem Urteil.
msg_info "Prüfe PVE-API vom Container aus ..."
PVE_API_OK=0
PVE_HOST_EFFECTIVE="$(pct exec "$CT_ID" -- grep -E "^PVE_HOST=" /opt/pve-flr-portal/.env 2>/dev/null | cut -d= -f2- || true)"
if [[ -n "${PVE_HOST_EFFECTIVE:-}" && "$PVE_HOST_EFFECTIVE" != "<hostname or IP of PVE host>" ]]; then
  if pct exec "$CT_ID" -- curl -ks -m 10 "https://${PVE_HOST_EFFECTIVE}:8006/api2/json/version" 2>/dev/null | grep -q '"version"'; then
    PVE_API_OK=1
  fi
fi
if [[ "$PVE_API_OK" == "1" ]]; then
  msg_ok "PVE-API erreichbar (https://${PVE_HOST_EFFECTIVE}:8006 antwortet)."
else
  msg_warn "PVE-API NICHT erreichbar (PVE_HOST='${PVE_HOST_EFFECTIVE:-<leer>}') – jeder Login wird mit HTTP 500 scheitern!"
  msg_warn "Fix: PVE_HOST in der .env setzen + Service neu starten (siehe Banner unten)."
fi

# Finale IP erneut auflösen (DHCP kann sich während des Setups geändert haben)
CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')"

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : pve-flr-portal – File Level Restore Portal für PBS"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : https://${CT_IP}:${APP_PORT}"
echo "                 (Browser warnt beim ersten Aufruf vor Self-Signed – erwartet.)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status pve-flr-portal  (im Container via: pct enter $CT_ID)"
if [[ "$PVE_API_OK" == "1" ]]; then
echo "  PVE-API      : https://${PVE_HOST_EFFECTIVE}:8006 erreichbar – Login sollte funktionieren."
echo "                 Storage-ID 'pbs' ggf. prüfen: pvesm status (muss PBS-Storage sein)."
else
echo "  !!! PVE-HOST NICHT KONFIGURIERT/ERREICHBAR – LOGIN SCHEITERT MIT HTTP 500 !!!"
echo "  Fix          : pct exec $CT_ID -- nano /opt/pve-flr-portal/.env"
echo "                 (PVE_HOST=<PVE-IP> + PVE_STORAGE=<PBS-ID> setzen, dann: pct exec $CT_ID -- systemctl restart pve-flr-portal)"
fi
echo "  PVE-Rolle    : pveum role add FileRestoreReader -privs \"Datastore.AllocateSpace,VM.Backup,VM.Audit\""
echo "  Update       : Skript erneut laufen lassen (idempotent, fetch + latest Tag + pip + restart)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -kfs https://${CT_IP}:${APP_PORT}/ >/dev/null && echo WEB_UI_OK"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
