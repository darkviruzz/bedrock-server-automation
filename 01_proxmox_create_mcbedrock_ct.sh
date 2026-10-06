#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Minecraft Bedrock LXC creator for Proxmox VE
# Run as root on a Proxmox VE node.

log(){ printf '\033[1;34m[mc-bedrock]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ask(){
  local __var="$1" prompt="$2" def="${3-}" val
  if [[ -n "$def" ]]; then read -r -p "$prompt [$def]: " val || true; else read -r -p "$prompt: " val || true; fi
  printf -v "$__var" '%s' "${val:-$def}"
}
yesno(){
  local __var="$1" prompt="$2" def="${3:-y}" val
  local hint='[Y/n]'; [[ "$def" == n ]] && hint='[y/N]'
  read -r -p "$prompt $hint: " val || true
  val="${val:-$def}"; case "${val,,}" in y|yes|j|ja) printf -v "$__var" y;; *) printf -v "$__var" n;; esac
}

[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null || die "pct nicht gefunden – dieses Skript muss auf einem Proxmox-VE-Host laufen."
command -v pvesm >/dev/null || die "pvesm nicht gefunden."
command -v pveam >/dev/null || die "pveam nicht gefunden."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/02_mcbedrock_setup.sh"
[[ -f "$SETUP_SCRIPT" ]] || die "02_mcbedrock_setup.sh muss im selben Verzeichnis liegen."

log "Ermittle sichere Defaults aus diesem Proxmox-Host …"
DEFAULT_CTID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
[[ "$DEFAULT_CTID" =~ ^[0-9]+$ ]] || DEFAULT_CTID=200

# Prefer active storages that support rootdir / templates.
mapfile -t ROOT_STORAGES < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
mapfile -t TMPL_STORAGES < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
[[ ${#ROOT_STORAGES[@]} -gt 0 ]] || die "Kein aktives Proxmox-Storage mit content=rootdir gefunden."
[[ ${#TMPL_STORAGES[@]} -gt 0 ]] || die "Kein aktives Proxmox-Storage mit content=vztmpl gefunden."
DEFAULT_ROOT_STORAGE="${ROOT_STORAGES[0]}"
DEFAULT_TMPL_STORAGE="${TMPL_STORAGES[0]}"
for s in "${ROOT_STORAGES[@]}"; do [[ "$s" == "local-lvm" ]] && DEFAULT_ROOT_STORAGE="$s"; done
for s in "${TMPL_STORAGES[@]}"; do [[ "$s" == "local" ]] && DEFAULT_TMPL_STORAGE="$s"; done

DEFAULT_BRIDGE=""
if ip link show vmbr0 >/dev/null 2>&1; then DEFAULT_BRIDGE=vmbr0; else
  DEFAULT_BRIDGE="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^vmbr' | head -n1 || true)"
fi
[[ -n "$DEFAULT_BRIDGE" ]] || die "Keine Proxmox/Linux-Bridge (vmbr*) erkannt."

cat <<EOF

Abgefragt werden nur die host-/server-spezifischen Werte. Defaults:
  CTID            automatisch nächste freie ID ($DEFAULT_CTID)
  Hostname        mc-bedrock
  CPU/RAM         4 vCPU / 4096 MiB (+512 MiB Swap)
  Disk            20 GiB
  Root-Storage    $DEFAULT_ROOT_STORAGE
  Template-Store  $DEFAULT_TMPL_STORAGE
  Bridge          $DEFAULT_BRIDGE
  Netzwerk        DHCP (für feste IP ggf. DHCP-Reservation im Router bevorzugt)
  LXC             unprivilegiert, onboot=1, Ubuntu 24.04 LTS

EOF

ask CTID "CTID" "$DEFAULT_CTID"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CTID."
pct status "$CTID" >/dev/null 2>&1 && die "CTID $CTID existiert bereits."
ask HOSTNAME "Hostname" "mc-bedrock"
ask CORES "vCPU" "4"
ask MEMORY "RAM in MiB" "4096"
ask SWAP "Swap in MiB" "512"
ask DISK_GB "Root-Disk in GiB" "20"
ask ROOT_STORAGE "Rootfs-Storage" "$DEFAULT_ROOT_STORAGE"
pvesm status -content rootdir | awk 'NR>1{print $1}' | grep -Fxq "$ROOT_STORAGE" || die "Storage '$ROOT_STORAGE' unterstützt rootdir nicht oder existiert nicht."
ask TMPL_STORAGE "Template-Storage" "$DEFAULT_TMPL_STORAGE"
pvesm status -content vztmpl | awk 'NR>1{print $1}' | grep -Fxq "$TMPL_STORAGE" || die "Storage '$TMPL_STORAGE' unterstützt vztmpl nicht oder existiert nicht."
ask BRIDGE "Netzwerk-Bridge" "$DEFAULT_BRIDGE"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' existiert nicht."
ask NET_MODE "Netzwerkmodus (dhcp/static)" "dhcp"
NET_MODE="${NET_MODE,,}"
case "$NET_MODE" in
  dhcp) NET0="name=eth0,bridge=$BRIDGE,ip=dhcp,firewall=0" ;;
  static)
    ask IP_CIDR "IPv4 inkl. Präfix, z.B. 192.168.1.50/24" ""
    [[ "$IP_CIDR" == */* ]] || die "IPv4 muss CIDR-Präfix enthalten."
    ask GATEWAY "IPv4-Gateway" ""
    [[ -n "$GATEWAY" ]] || die "Gateway fehlt."
    NET0="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=0"
    ;;
  *) die "Netzwerkmodus muss dhcp oder static sein." ;;
esac

yesno AUTOSTART_SETUP "CT nach Erstellung starten und Setup-Skript hinein kopieren?" y

log "Aktualisiere Proxmox-Template-Liste …"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '$2 ~ /^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || die "Kein Ubuntu-24.04-LXC-Template in pveam gefunden."

if ! pveam list "$TMPL_STORAGE" 2>/dev/null | awk 'NR>1{print $1}' | grep -Fq "vztmpl/$TEMPLATE"; then
  log "Lade Template $TEMPLATE nach $TMPL_STORAGE …"
  pveam download "$TMPL_STORAGE" "$TEMPLATE"
else
  log "Template bereits vorhanden: $TEMPLATE"
fi
TEMPLATE_REF="$TMPL_STORAGE:vztmpl/$TEMPLATE"

log "Erzeuge unprivilegierten LXC $CTID …"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$ROOT_STORAGE:$DISK_GB" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --onboot 1 \
  --ostype ubuntu \
  --features keyctl=1 \
  --start 0

# Helpful but nonessential metadata.
pct set "$CTID" --description "Minecraft Bedrock Dedicated Server (managed by mc-bedrock scripts)" >/dev/null

if [[ "$AUTOSTART_SETUP" == y ]]; then
  log "Starte CT $CTID …"
  pct start "$CTID"
  for _ in {1..60}; do
    if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
    sleep 1
  done
  pct exec "$CTID" -- true >/dev/null 2>&1 || die "Container wurde nicht rechtzeitig erreichbar."

  log "Kopiere Setup-Skript in den Container …"
  pct push "$CTID" "$SETUP_SCRIPT" /root/02_mcbedrock_setup.sh -perms 0750

  # Wait for a usable IP and outbound DNS/HTTPS where possible.
  CT_IP=""
  for _ in {1..45}; do
    CT_IP="$(pct exec "$CTID" -- sh -lc "ip -4 -o addr show dev eth0 | sed -nE 's/.* inet ([0-9.]+)\\/.*/\\1/p' | head -n1" 2>/dev/null || true)"
    [[ -n "$CT_IP" ]] && break
    sleep 1
  done
  if ! pct exec "$CTID" -- getent hosts www.minecraft.net >/dev/null 2>&1; then
    warn "DNS/Internet im CT ist noch nicht erreichbar. Das zweite Skript prüft dies erneut."
  fi

  cat <<EOF

Container erstellt und gestartet.
  CTID:       $CTID
  Hostname:   $HOSTNAME
  IPv4:       ${CT_IP:-noch nicht ermittelt}
  Bridge:     $BRIDGE
  Storage:    $ROOT_STORAGE

Jetzt auf dem Proxmox-Host ausführen:

  pct enter $CTID
  /root/02_mcbedrock_setup.sh

Für iPads im gleichen LAN reicht anschließend die IPv4 des Containers + UDP-Port 19132.
Für Zugriff aus dem Internet muss am Router zusätzlich UDP 19132 auf diese CT-IP weitergeleitet werden; das kann der LXC selbst nicht konfigurieren.
EOF
else
  cat <<EOF
Container $CTID wurde erstellt, aber nicht gestartet.
Start/Kopie später:
  pct start $CTID
  pct push $CTID "$SETUP_SCRIPT" /root/02_mcbedrock_setup.sh -perms 0750
  pct enter $CTID
  /root/02_mcbedrock_setup.sh
EOF
fi