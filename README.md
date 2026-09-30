# pve-flr-portal auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/treycentric/pve-flr-portal`
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python/FastAPI + Uvicorn, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"
```

> Lokal testen: `bash install/pve-flr-portal.sh --help`.

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"
PVE_HOST=192.168.178.2 PVE_STORAGE=pbs bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FileLevelRestoreProxmox/main/install/pve-flr-portal.sh)"
bash install/pve-flr-portal.sh --ctid 150 --cores 1 --memory 1024 --disk 4 --bridge vmbr0 --storage local-lvm --pve-host 192.168.178.2 --pve-storage pbs
bash install/pve-flr-portal.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/pve-flr-portal-install-*.log
```

Ohne `--pve-host`/`PVE_HOST` fragt das Script interaktiv (nur bei TTY, Default-Vorschlag = Host-IP);
ohne Angabe bleibt der `.env`-Platzhalter und das Banner warnt fett, dass jeder Login mit HTTP 500 scheitert.

> Die systemd-Unit liegt unter `systemd/pve-flr-portal.service` desselben Repos und wird
> vom Installer per Download übernommen (Fallback: Inline-Unit im Script).
> Upstream-Template (`deploy/pve-flr-portal.service.template`) enthält `__APP_DIR__`-Platzhalter
> und `Restart=on-failure` – der Installer rendert ersatzweise konkrete Pfade,
> die mitgelieferte Unit nutzt `Restart=always`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `pve-flr-portal` |
| Zweck | File Level Restore Portal für Proxmox Backup Server – Snapshot-Timeline + File-Browser + Download (.zip/.tar.gz/.tar.zst) + Restore via qemu-guest-agent |
| Tech-Stack | Python/FastAPI + Uvicorn (HTTPS), venv `/opt/pve-flr-portal/.venv`, `run.py` bindet `0.0.0.0` |
| GitHub-Repo (Upstream) | `https://github.com/treycentric/pve-flr-portal` |
| Web UI | `https://<LXC-IP>:8008` (Self-Signed, Browser-Warnung beim 1. Aufruf ist erwartet) |
| Standard-Ressourcen | 1 vCPU / 1024 MB RAM / 4 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `pve-flr-portal` (`onboot: 1`, unprivilegiert),
3. installiert im Container Python+venv+git, legt System-User `pveflr` an,
   klont/pullt `treycentric/pve-flr-portal` nach `/opt/pve-flr-portal`,
   checkt das neueste `v*.*.*`-Tag aus (Upstream-Release-Kanal), installiert
   `requirements.txt`, legt `.env` aus `.env.example` an (falls fehlt) und
   schreibt `PVE_HOST`/`PVE_STORAGE` (Flag/ENV/Abfrage) direkt hinein,
   schreibt `pve-flr-portal.service`, `systemctl enable --now pve-flr-portal`,
4. verifiziert `systemctl is-active pve-flr-portal` + HTTPS auf `localhost:8008/`
   (`curl -k` wegen Self-Signed) **+ PVE-API-Erreichbarkeit**
   (`curl -k https://<PVE_HOST>:8006/api2/json/version` aus dem Container)
   und gibt die finale URL + Container-IP aus. Ist PVE nicht erreichbar,
   warnt das Banner fett, dass jeder Login mit HTTP 500 scheitert.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active pve-flr-portal = active).
[OK]    Web UI antwortet (HTTPS 200 auf localhost:8008/, -k wegen Self-Signed).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : pve-flr-portal – File Level Restore Portal für PBS
  Container    : CT 100 (Hostname: pve-flr-portal, unprivilegiert, onboot=1)
  Ressourcen   : 1 vCPU / 1024 MB RAM / 4 GB Disk
  Web UI       : https://192.168.1.100:8008
                 (Browser warnt beim ersten Aufruf vor Self-Signed – erwartet.)
  ...
  Log          : /tmp/pve-flr-portal-install-2026-....log
══════════════════════════════════════════════════════════
```

## Nach der Installation (PVE-Zugang prüfen)

Wurde `PVE_HOST`/`PVE_STORAGE` bei der Installation gesetzt (Flag/ENV/Abfrage),
ist die `.env` bereits korrekt und das Banner zeigt „PVE-API erreichbar".
Sonst nachholen:

```bash
pct exec 100 -- nano /opt/pve-flr-portal/.env
# PVE_HOST=<PVE-IP> PVE_STORAGE=<PBS-Storage-ID> setzen
pct exec 100 -- systemctl restart pve-flr-portal
# Verify: kein "Could not fetch realms" mehr im Journal
pct exec 100 -- journalctl -u pve-flr-portal --no-pager -n 20
```

Auf dem PVE-Host (einmalig):

```bash
pveum role add FileRestoreReader -privs "Datastore.AllocateSpace,VM.Backup,VM.Audit"
pveum acl modify /storage/<storage-id> --users <user>@<realm> --roles FileRestoreReader
pveum acl modify /vms --users <user>@<realm> --roles FileRestoreReader
```

Details: Upstream-README „Provisioning access" (+ Restore-to-guest braucht separaten `FileRestoreOperator`-Grant, PVE 9+).

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active pve-flr-portal
curl -kfs https://<LXC-IP>:8008/ >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash install/pve-flr-portal.sh --ctid 100   # Update: idempotent (fetch + latest Tag + pip + restart)
pct stop 100 && pct destroy 100             # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/pve-flr-portal-install-*.log`.
- `bash install/pve-flr-portal.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status pve-flr-portal --no-pager`, `journalctl -u pve-flr-portal -n 100`.
- **Login → „Internal Server Error"**: fast immer `PVE_HOST` falsch/nicht gesetzt.
  Im Journal steht dann `httpx.ConnectError: [Errno -2] Name or service not known`
  bei `backend/auth.py, line 115, in login` plus `Could not fetch realms from PVE`.
  Fix: `PVE_HOST` (IP statt Hostname umgeht DNS) in der `.env` setzen + `systemctl restart pve-flr-portal`.
  „Invalid username or password" dagegen heißt: PVE ist erreichbar, Credentials/Rolle prüfen.

## Dateien

- `install/pve-flr-portal.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/pve-flr-portal.service` – Uvicorn-Unit (`After=network-online.target`, `Restart=always`).
