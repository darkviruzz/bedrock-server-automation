#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# Full Minecraft Bedrock Dedicated Server + Add-ons setup for Ubuntu 24.04 LXC.
# Installs BDS, systemd service, five pinned stable add-ons, backups,
# guarded BDS updates, optional guarded add-on updates, and health tests.

log(){ printf '\033[1;34m[mc-bedrock]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
ask(){
  local __var="$1" prompt="$2" def="${3-}" val
  if [[ -n "$def" ]]; then read -r -p "$prompt [$def]: " val || true; else read -r -p "$prompt: " val || true; fi
  printf -v "$__var" '%s' "${val:-$def}"
}
yesno(){
  local __var="$1" prompt="$2" def="${3:-y}" val hint='[Y/n]'
  [[ "$def" == n ]] && hint='[y/N]'
  read -r -p "$prompt $hint: " val || true
  val="${val:-$def}"; case "${val,,}" in y|yes|j|ja) printf -v "$__var" y;; *) printf -v "$__var" n;; esac
}

[[ $EUID -eq 0 ]] || die "Bitte als root im Ubuntu-LXC ausführen."
source /etc/os-release || true
[[ "${ID:-}" == ubuntu ]] || warn "Offiziell unterstützt BDS unter Linux Ubuntu; erkannt wurde ${PRETTY_NAME:-unbekannt}."

cat <<'EOF'

Das Skript fragt jetzt alle Werte ab, die es nicht sicher selbst entscheiden kann.
Sinnvolle Defaults sind bereits gesetzt:
  - Survival / Normal, 10 Spieler, Cheats aus
  - UDP 19132 (IPv4) / 19133 (IPv6)
  - 16 Chunks Sichtweite, 6 Tick-Distance
  - Allowlist an (für privaten Kinder-/Familienserver)
  - tägliche Backups, 14 Tage Aufbewahrung
  - BDS Stable automatisch aktualisieren: JA, mit Backup/Test/Rollback
  - Add-ons automatisch aktualisieren: NEIN; wöchentlicher Update-Check
    (optional JA: nur CurseForge-Release, dann Backup/Test/Rollback)
  - Add-on-Reihenfolge: Essentials+ > Gravestone > Dynamic Light > Epic Machinery > Better on Bedrock
    Damit bekommt Essentials+ bei möglichen Überschneidungen die höhere Priorität.

Für vollautomatische CurseForge-Downloads wird ein CurseForge-API-Key benötigt.
Er wird nur root-lesbar unter /etc/minecraft-bedrock/curseforge.key gespeichert.
EOF

ask SERVER_NAME "Servername" "Minecraft Bedrock"
ask LEVEL_NAME "Weltname/level-name" "Survival"
[[ "$LEVEL_NAME" != *'/'* && "$LEVEL_NAME" != *$'\n'* ]] || die "Weltname darf keinen Slash/Zeilenumbruch enthalten."
ask GAMEMODE "Gamemode (survival/creative/adventure)" "survival"
case "$GAMEMODE" in survival|creative|adventure) ;; *) die "Ungültiger Gamemode.";; esac
ask DIFFICULTY "Schwierigkeit (peaceful/easy/normal/hard)" "normal"
case "$DIFFICULTY" in peaceful|easy|normal|hard) ;; *) die "Ungültige Schwierigkeit.";; esac
ask MAX_PLAYERS "Maximale Spielerzahl" "10"
ask PORT4 "UDP-Port IPv4" "19132"
ask PORT6 "UDP-Port IPv6" "19133"
ask VIEW_DISTANCE "view-distance" "16"
ask TICK_DISTANCE "tick-distance (4-12)" "6"
yesno ALLOW_CHEATS "Cheats erlauben?" n
yesno USE_ALLOWLIST "Allowlist aktivieren?" y
ALLOWLIST_NAMES=""
if [[ "$USE_ALLOWLIST" == y ]]; then
  ask ALLOWLIST_NAMES "Gamertags für Start-Allowlist, kommagetrennt (leer = zunächst niemand)" ""
fi
ask LEVEL_SEED "Seed (leer = zufällig)" ""
ask TZ_NAME "Zeitzone" "Europe/Berlin"
ask BACKUP_RETENTION_DAYS "Backup-Aufbewahrung in Tagen" "14"
yesno AUTO_BDS "BDS Stable automatisch aktualisieren?" y
yesno AUTO_ADDONS "Add-ons automatisch (nur Release + Rollback) aktualisieren?" n

printf 'CurseForge API-Key (Eingabe wird nicht angezeigt): '
IFS= read -r -s CF_API_KEY || true
printf '\n'
[[ -n "$CF_API_KEY" ]] || die "Ein CurseForge-API-Key ist für die automatische Installation der fünf Add-ons erforderlich."

# Paths/constants
MC_USER=minecraft
MC_GROUP=minecraft
BASE=/srv/minecraft-bedrock
OPT=/opt/minecraft-bedrock
ETC=/etc/minecraft-bedrock
RELEASES="$OPT/releases"
CURRENT="$OPT/current"
ARCHIVES="$BASE/addon_archives"
PACKS="$BASE/packs"
STATE="$BASE/state"
BACKUPS="$BASE/backups"
WORLD_DIR="$BASE/worlds/$LEVEL_NAME"
CF_BASE=https://api.curseforge.com/v1
MS_DOWNLOAD_API=https://net-secondary.web.minecraft-services.net/api/v1.0/download/links

export DEBIAN_FRONTEND=noninteractive
log "Installiere Betriebssystem-Abhängigkeiten …"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq unzip rsync python3 tar zstd tzdata iproute2 procps libatomic1
ln -snf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime || true
printf '%s\n' "$TZ_NAME" > /etc/timezone

getent group "$MC_GROUP" >/dev/null || groupadd --system "$MC_GROUP"
id "$MC_USER" >/dev/null 2>&1 || useradd --system --gid "$MC_GROUP" --home-dir "$BASE" --shell /usr/sbin/nologin "$MC_USER"
install -d -m 0755 "$RELEASES" "$ETC"
install -d -o "$MC_USER" -g "$MC_GROUP" -m 0755 "$BASE" "$BASE/worlds" "$ARCHIVES" "$PACKS" "$PACKS/behavior" "$PACKS/resource" "$STATE" "$BACKUPS" "$BASE/logs" "$BASE/config"
printf '%s\n' "$CF_API_KEY" > "$ETC/curseforge.key"
chmod 0600 "$ETC/curseforge.key"

cat > "$ETC/settings.env" <<EOF
MC_USER=$MC_USER
MC_GROUP=$MC_GROUP
BASE=$BASE
OPT=$OPT
ETC=$ETC
LEVEL_NAME=$(printf '%q' "$LEVEL_NAME")
PORT4=$PORT4
PORT6=$PORT6
BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS
AUTO_ADDONS=$AUTO_ADDONS
CF_BASE=$CF_BASE
MS_DOWNLOAD_API=$MS_DOWNLOAD_API
EOF
chmod 0644 "$ETC/settings.env"

# Initial pinned stable CurseForge releases, verified 2026-10-04.
# Priority: higher number = listed higher in world pack stack.
cat > "$ETC/addons.seed.json" <<'EOF'
[
  {"slug":"bedrock-essentials","name":"Bedrock Essentials+","projectId":1285412,"fileId":8837761,"priority":100},
  {"slug":"advanced-gravestone","name":"Advanced Gravestone","projectId":1471818,"fileId":8893465,"priority":90},
  {"slug":"lilium-dynamic-light","name":"Lilium Dynamic Light","projectId":1575969,"fileId":8943140,"priority":80},
  {"slug":"epic-machinery","name":"Epic Machinery","projectId":1377615,"fileId":8671527,"priority":70},
  {"slug":"better-on-bedrock","name":"Better on Bedrock","projectId":1057117,"fileId":7951504,"priority":60}
]
EOF

# Server properties are persistent across binary upgrades.
ALLOWLIST_BOOL=false; [[ "$USE_ALLOWLIST" == y ]] && ALLOWLIST_BOOL=true
CHEATS_BOOL=false; [[ "$ALLOW_CHEATS" == y ]] && CHEATS_BOOL=true
cat > "$BASE/server.properties" <<EOF
server-name=$SERVER_NAME
gamemode=$GAMEMODE
force-gamemode=false
difficulty=$DIFFICULTY
allow-cheats=$CHEATS_BOOL
max-players=$MAX_PLAYERS
online-mode=true
allow-list=$ALLOWLIST_BOOL
server-port=$PORT4
server-portv6=$PORT6
enable-lan-visibility=true
view-distance=$VIEW_DISTANCE
tick-distance=$TICK_DISTANCE
player-idle-timeout=30
max-threads=0
level-name=$LEVEL_NAME
level-seed=$LEVEL_SEED
default-player-permission-level=member
texturepack-required=true
content-log-file-enabled=true
compression-threshold=1
compression-algorithm=zlib
client-side-chunk-generation-enabled=true
block-network-ids-are-hashes=true
disable-persona=false
disable-custom-skins=false
server-authoritative-movement=server-auth
EOF
chown "$MC_USER:$MC_GROUP" "$BASE/server.properties"

printf '[]\n' > "$BASE/permissions.json"
python3 - "$BASE/allowlist.json" "$ALLOWLIST_NAMES" <<'PY'
import json,sys
out,names=sys.argv[1],sys.argv[2]
vals=[]
for raw in names.split(','):
    n=raw.strip()
    if n: vals.append({"name":n,"ignoresPlayerLimit":False})
with open(out,'w',encoding='utf-8') as f: json.dump(vals,f,indent=2,ensure_ascii=False); f.write('\n')
PY
chown "$MC_USER:$MC_GROUP" "$BASE/permissions.json" "$BASE/allowlist.json"

# Python add-on manager: safe recursive .mcaddon/.mcpack unpacking, manifest validation,
# stable API gate, persistent custom-pack store, world pack-stack generation.
cat > /usr/local/lib/mc-bedrock-addon-manager.py <<'PY'
#!/usr/bin/env python3
import argparse, json, os, re, shutil, sys, tempfile, zipfile
from pathlib import Path

BAD_WORDS=("beta","preview","experimental")

def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr); raise SystemExit(2)

def read_json(p):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8-sig"))
    except Exception as e: fail(f"Ungültiges JSON {p}: {e}")

def safe_extract(zpath, dest):
    dest=Path(dest).resolve()
    with zipfile.ZipFile(zpath) as z:
        for info in z.infolist():
            target=(dest/info.filename).resolve()
            if target != dest and dest not in target.parents:
                fail(f"Unsicherer ZIP-Pfad in {zpath}: {info.filename}")
        z.extractall(dest)

def unpack_recursive(archive, root):
    first=Path(root)/"root"
    first.mkdir(parents=True, exist_ok=True)
    safe_extract(archive, first)
    seen=set()
    while True:
        nested=[]
        for p in Path(root).rglob('*'):
            if p.is_file() and p.suffix.lower() in ('.mcpack','.mcaddon','.zip') and str(p) not in seen:
                try:
                    if zipfile.is_zipfile(p): nested.append(p)
                except OSError: pass
        if not nested: break
        for p in nested:
            seen.add(str(p))
            d=p.with_name(p.name+".unpacked")
            d.mkdir(exist_ok=True)
            safe_extract(p,d)


def classify_manifest(man):
    types={str(m.get('type','')).lower() for m in man.get('modules',[]) if isinstance(m,dict)}
    if 'resources' in types: return 'resource'
    if types & {'data','script'}: return 'behavior'
    # Fallback for older/simple manifests.
    return None

def validate_manifest(path, man):
    hdr=man.get('header') or {}
    uuid=hdr.get('uuid'); ver=hdr.get('version')
    if not isinstance(uuid,str) or not re.fullmatch(r'[0-9a-fA-F-]{32,36}',uuid): fail(f"Manifest ohne gültige header.uuid: {path}")
    if not (isinstance(ver,list) and len(ver)>=3 and all(isinstance(x,int) for x in ver[:3])): fail(f"Manifest ohne gültige header.version: {path}")
    caps=man.get('capabilities',[]) or []
    for c in caps:
        if any(w in str(c).lower() for w in BAD_WORDS): fail(f"Experimentelle Capability abgelehnt: {c} in {path}")
    for dep in man.get('dependencies',[]) or []:
        if not isinstance(dep,dict): continue
        for key in ('version','module_name'):
            val=dep.get(key)
            if any(w in str(val).lower() for w in BAD_WORDS): fail(f"Beta/Preview/Experimental Dependency abgelehnt: {dep} in {path}")
    return uuid,ver[:3]

def copytree_clean(src,dst):
    if dst.exists(): shutil.rmtree(dst)
    shutil.copytree(src,dst)

def build(args):
    lock=read_json(args.lock)
    if not isinstance(lock,list): fail("addon-lock.json muss Array sein")
    bdir=Path(args.behavior); rdir=Path(args.resource); wdir=Path(args.world)
    for d in (bdir,rdir):
        d.mkdir(parents=True,exist_ok=True)
        for p in d.iterdir():
            if p.name.startswith('u_'):
                if p.is_dir(): shutil.rmtree(p)
                else: p.unlink()
    packs=[]
    with tempfile.TemporaryDirectory(prefix='mcaddon-') as td:
        for addon in sorted(lock,key=lambda x:int(x.get('priority',0)), reverse=True):
            archive=Path(args.archives)/f"{addon['slug']}.mcaddon"
            if not archive.is_file(): fail(f"Archiv fehlt: {archive}")
            root=Path(td)/addon['slug']; root.mkdir()
            unpack_recursive(archive,root)
            manifests=[]
            for mp in root.rglob('manifest.json'):
                # Ignore manifests nested beneath another manifest pack root.
                parent=mp.parent
                if any((q/'manifest.json').is_file() for q in parent.parents if q != root and root in q.parents):
                    continue
                manifests.append(mp)
            if not manifests: fail(f"Keine manifest.json in {archive.name} gefunden")
            found=0
            for mp in manifests:
                man=read_json(mp); kind=classify_manifest(man)
                if not kind: continue
                uuid,ver=validate_manifest(mp,man)
                destbase=bdir if kind=='behavior' else rdir
                dest=destbase/f"u_{uuid.replace('-','')[:8]}"
                copytree_clean(mp.parent,dest)
                packs.append({"addon":addon['name'],"slug":addon['slug'],"priority":int(addon.get('priority',0)),"kind":kind,"uuid":uuid,"version":ver,"folder":dest.name,"manifest":str(mp)})
                found += 1
            if found == 0: fail(f"Keine Behavior-/Resource-Pack-Module in {archive.name} gefunden")
    # Duplicate UUIDs are unsafe.
    seen={}
    for p in packs:
        key=(p['kind'],p['uuid'])
        if key in seen: fail(f"Doppelte Pack-UUID {key}: {seen[key]} und {p['addon']}")
        seen[key]=p['addon']
    wdir.mkdir(parents=True,exist_ok=True)
    for kind,fname in [('behavior','world_behavior_packs.json'),('resource','world_resource_packs.json')]:
        entries=[{"pack_id":p['uuid'],"version":p['version']} for p in sorted(packs,key=lambda x:x['priority'],reverse=True) if p['kind']==kind]
        (wdir/fname).write_text(json.dumps(entries,indent=2)+"\n",encoding='utf-8')
    Path(args.report).write_text(json.dumps(packs,indent=2,ensure_ascii=False)+"\n",encoding='utf-8')
    print(json.dumps(packs,indent=2,ensure_ascii=False))

def inspect(args):
    man=read_json(args.manifest); validate_manifest(args.manifest,man); print(classify_manifest(man) or 'unknown')

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    b=sub.add_parser('build')
    for x in ('archives','behavior','resource','world','lock','report'): b.add_argument('--'+x,required=True)
    b.set_defaults(fn=build)
    i=sub.add_parser('inspect'); i.add_argument('manifest'); i.set_defaults(fn=inspect)
    a=ap.parse_args(); a.fn(a)
if __name__=='__main__': main()
PY
chmod 0755 /usr/local/lib/mc-bedrock-addon-manager.py

# Shared shell library.
cat > /usr/local/lib/mc-bedrock-common.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/minecraft-bedrock/settings.env
CF_KEY_FILE="$ETC/curseforge.key"
RELEASES="$OPT/releases"; CURRENT="$OPT/current"; ARCHIVES="$BASE/addon_archives"; PACKS="$BASE/packs"; STATE="$BASE/state"; BACKUPS="$BASE/backups"
log(){ printf '[mc-bedrock] %s\n' "$*"; }
cf_key(){ cat "$CF_KEY_FILE"; }
cf_get(){ curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/json' -H "x-api-key: $(cf_key)" "$1"; }
bds_url(){ curl -fsSL --retry 3 --connect-timeout 15 "$MS_DOWNLOAD_API" | jq -er '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl' | head -n1; }
bds_version_from_url(){ basename "$1" | sed -nE 's/^bedrock-server-([0-9.]+)\.zip$/\1/p'; }
mc_active(){ systemctl is-active --quiet minecraft-bedrock.service; }
stop_mc(){ systemctl stop minecraft-bedrock.service 2>/dev/null || true; }
start_mc(){ systemctl start minecraft-bedrock.service; }
release_link_persistent(){
  local d="$1"
  for f in server.properties allowlist.json permissions.json; do rm -f "$d/$f"; ln -s "$BASE/$f" "$d/$f"; done
  rm -rf "$d/worlds"; ln -s "$BASE/worlds" "$d/worlds"
  mkdir -p "$d/behavior_packs" "$d/resource_packs"
  rm -rf "$d"/behavior_packs/u_* "$d"/resource_packs/u_* 2>/dev/null || true
  for p in "$PACKS/behavior"/u_*; do [[ -d "$p" ]] && rsync -a --delete "$p/" "$d/behavior_packs/$(basename "$p")/"; done
  for p in "$PACKS/resource"/u_*; do [[ -d "$p" ]] && rsync -a --delete "$p/" "$d/resource_packs/$(basename "$p")/"; done
  chown -R root:root "$d/behavior_packs" "$d/resource_packs"; chmod -R a+rX "$d/behavior_packs" "$d/resource_packs"
}
install_bds_release(){
  local url="$1" ver="$2" d="$RELEASES/$ver" tmp
  if [[ ! -x "$d/bedrock_server" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    log "Download BDS $ver"
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp/bds.zip" "$url"
    unzip -q "$tmp/bds.zip" -d "$tmp/extract"
    mkdir -p "$d"; rsync -a "$tmp/extract/" "$d/"
    chmod 0755 "$d/bedrock_server"
    rm -rf "$tmp"; trap - RETURN
  fi
  release_link_persistent "$d"
  if ldd "$d/bedrock_server" 2>&1 | grep -q 'not found'; then ldd "$d/bedrock_server" >&2; return 1; fi
}
SH
chmod 0644 /usr/local/lib/mc-bedrock-common.sh

# Download one pinned CurseForge file and validate that it is a Release.
cat > /usr/local/sbin/mc-bedrock-cf-download <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
[[ $# -eq 3 ]] || { echo "Usage: $0 PROJECT_ID FILE_ID OUTPUT" >&2; exit 2; }
pid="$1"; fid="$2"; out="$3"
meta="$(cf_get "$CF_BASE/mods/$pid/files/$fid")"
[[ "$(jq -r '.data.releaseType' <<<"$meta")" == 1 ]] || { echo "Abgelehnt: CurseForge file $fid ist kein Release." >&2; exit 3; }
[[ "$(jq -r '.data.isEarlyAccessContent // false' <<<"$meta")" != true ]] || { echo "Abgelehnt: Early-Access-Datei." >&2; exit 3; }
url="$(cf_get "$CF_BASE/mods/$pid/files/$fid/download-url" | jq -er '.data')"
tmp="${out}.part"
curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$url"
sha1="$(jq -r '.data.hashes[]? | select(.algo==1) | .value' <<<"$meta" | head -n1)"
md5="$(jq -r '.data.hashes[]? | select(.algo==2) | .value' <<<"$meta" | head -n1)"
if [[ -n "$sha1" ]]; then echo "$sha1  $tmp" | sha1sum -c - >/dev/null
elif [[ -n "$md5" ]]; then echo "$md5  $tmp" | md5sum -c - >/dev/null
fi
mv -f "$tmp" "$out"
jq -c '.data | {id,fileName,fileDate,releaseType,gameVersions}' <<<"$meta"
SH
chmod 0755 /usr/local/sbin/mc-bedrock-cf-download

log "Lade die fünf gepinnten Stable-Add-ons …"
cp "$ETC/addons.seed.json" "$BASE/addon-lock.json"
while IFS=$'\t' read -r slug pid fid; do
  log "  $slug (project=$pid file=$fid)"
  /usr/local/sbin/mc-bedrock-cf-download "$pid" "$fid" "$ARCHIVES/$slug.mcaddon" > "$STATE/$slug.file.json"
done < <(jq -r '.[] | [.slug,.projectId,.fileId] | @tsv' "$BASE/addon-lock.json")
chown -R "$MC_USER:$MC_GROUP" "$ARCHIVES" "$STATE" "$BASE/addon-lock.json"

log "Entpacke und validiere Add-ons (Beta/Preview/Experimental-Abhängigkeiten werden abgelehnt) …"
install -d -o "$MC_USER" -g "$MC_GROUP" "$WORLD_DIR"
/usr/local/lib/mc-bedrock-addon-manager.py build \
  --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" \
  --world "$WORLD_DIR" --lock "$BASE/addon-lock.json" --report "$STATE/active-packs.json" >/tmp/mc-bedrock-packs.json
chown -R "$MC_USER:$MC_GROUP" "$PACKS" "$WORLD_DIR" "$STATE"

# Install current stable BDS and wire persistent state.
source /usr/local/lib/mc-bedrock-common.sh
BDS_URL="$(bds_url)"
BDS_VER="$(bds_version_from_url "$BDS_URL")"
[[ -n "$BDS_VER" ]] || die "BDS-Version konnte aus Download-URL nicht bestimmt werden: $BDS_URL"
log "Installiere offiziellen BDS Stable $BDS_VER …"
install_bds_release "$BDS_URL" "$BDS_VER"
ln -sfn "$RELEASES/$BDS_VER" "$CURRENT"
printf '%s\n' "$BDS_VER" > "$STATE/bds-version"
chown "$MC_USER:$MC_GROUP" "$STATE/bds-version"

# Sync user packs into release after manager build.
release_link_persistent "$CURRENT"

cat > /etc/systemd/system/minecraft-bedrock.service <<EOF
[Unit]
Description=Minecraft Bedrock Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$MC_USER
Group=$MC_GROUP
WorkingDirectory=$CURRENT
Environment=LD_LIBRARY_PATH=.
ExecStart=$CURRENT/bedrock_server
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
KillSignal=SIGINT
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Health test: service + UDP listener + fresh-log fatal scan.
cat > /usr/local/sbin/mc-bedrock-test <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
wait_s="${1:-90}"
for ((i=0;i<wait_s;i++)); do
  if ! systemctl is-active --quiet minecraft-bedrock.service; then
    echo "Service ist nicht aktiv." >&2; journalctl -u minecraft-bedrock.service -n 80 --no-pager >&2 || true; exit 1
  fi
  if ss -lunp 2>/dev/null | grep -Eq ":${PORT4}([[:space:]]|$)"; then break; fi
  sleep 1
done
ss -lunp 2>/dev/null | grep -Eq ":${PORT4}([[:space:]]|$)" || { echo "UDP $PORT4 lauscht nicht." >&2; journalctl -u minecraft-bedrock.service -n 100 --no-pager >&2; exit 1; }
logs="$(journalctl -u minecraft-bedrock.service --since '-3 minutes' --no-pager 2>/dev/null || true)"
if grep -Eqi '(configured pack.*not found|unable to load.*pack|failed to load.*pack|requires a newer version|syntaxerror|unhandledpromiserejection|resourceprocessingerror|fatal error|server shutdown unexpectedly)' <<<"$logs"; then
  echo "Fatales Add-on/BDS-Muster im aktuellen Journal gefunden:" >&2
  grep -Ei '(configured pack.*not found|unable to load.*pack|failed to load.*pack|requires a newer version|syntaxerror|unhandledpromiserejection|resourceprocessingerror|fatal error|server shutdown unexpectedly)' <<<"$logs" >&2 || true
  exit 1
fi
echo "OK: minecraft-bedrock aktiv; UDP $PORT4 lauscht; kein bekanntes fatales Pack-Muster im frischen Journal."
SH
chmod 0755 /usr/local/sbin/mc-bedrock-test

# Offline backup. --leave-stopped is used by update transactions.
cat > /usr/local/sbin/mc-bedrock-backup <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
leave=0; [[ "${1:-}" == "--leave-stopped" ]] && leave=1
was=0; mc_active && was=1
stop_mc
stamp="$(date +%Y%m%d-%H%M%S)"; out="$BACKUPS/mc-bedrock-$stamp.tar.zst"
tar -C "$BASE" --zstd -cf "$out" worlds server.properties allowlist.json permissions.json addon-lock.json addon_archives packs state
chmod 0640 "$out"
find "$BACKUPS" -type f -name 'mc-bedrock-*.tar.zst' -mtime "+$BACKUP_RETENTION_DAYS" -delete
if [[ $leave -eq 0 && $was -eq 1 ]]; then start_mc; fi
echo "$out"
SH
chmod 0755 /usr/local/sbin/mc-bedrock-backup

cat > /usr/local/sbin/mc-bedrock-restore-backup <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: $0 BACKUP.tar.zst" >&2; exit 2; }
stop_mc
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tar -C "$tmp" --zstd -xf "$1"
for x in worlds addon_archives packs state; do rm -rf "$BASE/$x"; cp -a "$tmp/$x" "$BASE/$x"; done
for x in server.properties allowlist.json permissions.json addon-lock.json; do cp -a "$tmp/$x" "$BASE/$x"; done
chown -R "$MC_USER:$MC_GROUP" "$BASE"
release_link_persistent "$CURRENT"
start_mc
/usr/local/sbin/mc-bedrock-test 90
SH
chmod 0755 /usr/local/sbin/mc-bedrock-restore-backup

# Guarded stable BDS update transaction.
cat > /usr/local/sbin/mc-bedrock-update-bds <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
url="$(bds_url)"; new="$(bds_version_from_url "$url")"; old="$(basename "$(readlink -f "$CURRENT")")"
[[ -n "$new" ]] || { echo "Keine BDS-Version erkannt" >&2; exit 2; }
if [[ "$new" == "$old" ]]; then echo "BDS bereits aktuell: $old"; exit 0; fi
log "BDS Update $old -> $new"
backup="$(/usr/local/sbin/mc-bedrock-backup --leave-stopped)"
if ! install_bds_release "$url" "$new"; then
  log "Neue Binary/Dependencies ungültig; starte alten Stand."
  ln -sfn "$RELEASES/$old" "$CURRENT"; start_mc; exit 1
fi
ln -sfn "$RELEASES/$new" "$CURRENT"
printf '%s\n' "$new" > "$STATE/bds-version"; chown "$MC_USER:$MC_GROUP" "$STATE/bds-version"
release_link_persistent "$CURRENT"
start_mc
if /usr/local/sbin/mc-bedrock-test 90; then
  log "BDS Update erfolgreich: $new"
  exit 0
fi
log "BDS Update fehlgeschlagen; Rollback auf $old inklusive Weltbackup."
stop_mc
ln -sfn "$RELEASES/$old" "$CURRENT"
/usr/local/sbin/mc-bedrock-restore-backup "$backup"
exit 1
SH
chmod 0755 /usr/local/sbin/mc-bedrock-update-bds

# Add-on update checker / guarded updater.
cat > /usr/local/sbin/mc-bedrock-update-addons <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
apply=0; [[ "${1:-}" == "--apply" ]] && apply=1
lock="$BASE/addon-lock.json"; tmp_lock="$(mktemp)"; trap 'rm -f "$tmp_lock"' EXIT
cp "$lock" "$tmp_lock"
changes=0
for idx in $(seq 0 $(( $(jq 'length' "$lock") - 1 ))); do
  pid="$(jq -r ".[$idx].projectId" "$lock")"; oldfid="$(jq -r ".[$idx].fileId" "$lock")"; name="$(jq -r ".[$idx].name" "$lock")"
  files="$(cf_get "$CF_BASE/mods/$pid/files?pageSize=50")"
  latest="$(jq -c '[.data[] | select(.releaseType==1 and (.isEarlyAccessContent != true))] | sort_by(.fileDate) | last // empty' <<<"$files")"
  [[ -n "$latest" ]] || { echo "$name: kein Release gefunden" >&2; continue; }
  fid="$(jq -r '.id' <<<"$latest")"
  if [[ "$fid" != "$oldfid" ]]; then
    changes=$((changes+1)); echo "UPDATE: $name file $oldfid -> $fid ($(jq -r '.fileName' <<<"$latest"))"
    jq --argjson i "$idx" --argjson fid "$fid" '.[$i].fileId=$fid' "$tmp_lock" > "$tmp_lock.n" && mv "$tmp_lock.n" "$tmp_lock"
  else echo "OK: $name ($oldfid)"; fi
done
[[ $changes -gt 0 ]] || exit 0
if [[ $apply -eq 0 ]]; then echo "$changes Add-on-Update(s) verfügbar; nicht angewendet."; exit 10; fi
log "Wende $changes Release-Update(s) transaktional an …"
backup="$(/usr/local/sbin/mc-bedrock-backup --leave-stopped)"
snap="$(mktemp -d)"; cp -a "$ARCHIVES" "$snap/archives"; cp -a "$lock" "$snap/lock.json"
rollback(){
  set +e; stop_mc; rm -rf "$ARCHIVES"; cp -a "$snap/archives" "$ARCHIVES"; cp -a "$snap/lock.json" "$lock"
  /usr/local/lib/mc-bedrock-addon-manager.py build --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" --world "$BASE/worlds/$LEVEL_NAME" --lock "$lock" --report "$STATE/active-packs.json" >/dev/null
  chown -R "$MC_USER:$MC_GROUP" "$BASE"; release_link_persistent "$CURRENT"
  /usr/local/sbin/mc-bedrock-restore-backup "$backup" || true; rm -rf "$snap"; exit 1
}
trap rollback ERR
while IFS=$'\t' read -r slug pid fid; do
  cur="$(jq -r --arg s "$slug" '.[]|select(.slug==$s)|.fileId' "$lock")"
  [[ "$fid" == "$cur" ]] && continue
  /usr/local/sbin/mc-bedrock-cf-download "$pid" "$fid" "$ARCHIVES/$slug.mcaddon" >/dev/null
done < <(jq -r '.[]|[.slug,.projectId,.fileId]|@tsv' "$tmp_lock")
cp "$tmp_lock" "$lock"
/usr/local/lib/mc-bedrock-addon-manager.py build --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" --world "$BASE/worlds/$LEVEL_NAME" --lock "$lock" --report "$STATE/active-packs.json" >/dev/null
chown -R "$MC_USER:$MC_GROUP" "$BASE"; release_link_persistent "$CURRENT"
start_mc
/usr/local/sbin/mc-bedrock-test 90
trap - ERR; rm -rf "$snap"; log "Add-on-Updates erfolgreich."
SH
chmod 0755 /usr/local/sbin/mc-bedrock-update-addons

# Convenience status and allowlist helpers.
cat > /usr/local/sbin/mc-bedrock-status <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
printf 'BDS release: %s\n' "$(basename "$(readlink -f "$CURRENT")")"
printf 'Service:     %s\n' "$(systemctl is-active minecraft-bedrock.service || true)"
printf 'IP(s):       %s\n' "$(hostname -I 2>/dev/null || true)"
printf 'UDP port:    %s\n' "$PORT4"
echo 'Add-ons:'
jq -r '.[] | "  - \(.name): CurseForge file \(.fileId)"' "$BASE/addon-lock.json"
echo 'Active pack manifests:'
jq -r '.[] | "  - [\(.kind)] \(.addon) \(.uuid) v\(.version|join("."))"' "$STATE/active-packs.json"
SH
chmod 0755 /usr/local/sbin/mc-bedrock-status

cat > /usr/local/sbin/mc-bedrock-allowlist <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
cmd="${1:-list}"; name="${2:-}"
case "$cmd" in
 list) jq -r '.[].name' "$BASE/allowlist.json";;
 add) [[ -n "$name" ]] || { echo "Name fehlt" >&2; exit 2; }; jq --arg n "$name" 'if any(.[]; .name==$n) then . else . + [{name:$n,ignoresPlayerLimit:false}] end' "$BASE/allowlist.json" > "$BASE/allowlist.json.n"; mv "$BASE/allowlist.json.n" "$BASE/allowlist.json"; chown "$MC_USER:$MC_GROUP" "$BASE/allowlist.json"; systemctl restart minecraft-bedrock;;
 remove) [[ -n "$name" ]] || { echo "Name fehlt" >&2; exit 2; }; jq --arg n "$name" '[.[]|select(.name!=$n)]' "$BASE/allowlist.json" > "$BASE/allowlist.json.n"; mv "$BASE/allowlist.json.n" "$BASE/allowlist.json"; chown "$MC_USER:$MC_GROUP" "$BASE/allowlist.json"; systemctl restart minecraft-bedrock;;
 *) echo "Usage: $0 list | add GAMERTAG | remove GAMERTAG" >&2; exit 2;;
esac
SH
chmod 0755 /usr/local/sbin/mc-bedrock-allowlist

# Timers
cat > /etc/systemd/system/mc-bedrock-backup.service <<'EOF'
[Unit]
Description=Minecraft Bedrock daily backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mc-bedrock-backup
EOF
cat > /etc/systemd/system/mc-bedrock-backup.timer <<'EOF'
[Unit]
Description=Minecraft Bedrock daily backup timer
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=10m
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/mc-bedrock-update-bds.service <<'EOF'
[Unit]
Description=Minecraft Bedrock guarded BDS stable update
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mc-bedrock-update-bds
EOF
cat > /etc/systemd/system/mc-bedrock-update-bds.timer <<'EOF'
[Unit]
Description=Minecraft Bedrock BDS update timer
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/mc-bedrock-update-addons.service <<EOF
[Unit]
Description=Minecraft Bedrock add-on update check/apply
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mc-bedrock-update-addons${AUTO_ADDONS:+$( [[ "$AUTO_ADDONS" == y ]] && printf ' --apply' || true )}
SuccessExitStatus=10
EOF
cat > /etc/systemd/system/mc-bedrock-update-addons.timer <<'EOF'
[Unit]
Description=Minecraft Bedrock weekly add-on update timer
[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true
RandomizedDelaySec=20m
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable minecraft-bedrock.service mc-bedrock-backup.timer mc-bedrock-update-addons.timer >/dev/null
if [[ "$AUTO_BDS" == y ]]; then systemctl enable mc-bedrock-update-bds.timer >/dev/null; else systemctl disable mc-bedrock-update-bds.timer >/dev/null 2>&1 || true; fi
systemctl start mc-bedrock-backup.timer mc-bedrock-update-addons.timer
[[ "$AUTO_BDS" == y ]] && systemctl start mc-bedrock-update-bds.timer || true

log "Starte Server und führe Live-Selbsttest aus …"
systemctl enable --now minecraft-bedrock.service
/usr/local/sbin/mc-bedrock-test 120

# Confirm pack stack files are valid and all extracted UUIDs are represented.
python3 - "$STATE/active-packs.json" "$WORLD_DIR/world_behavior_packs.json" "$WORLD_DIR/world_resource_packs.json" <<'PY'
import json,sys
packs=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); r=json.load(open(sys.argv[3]))
active={(x['kind'],x['uuid']) for x in packs}
listed={('behavior',x['pack_id']) for x in b}|{('resource',x['pack_id']) for x in r}
missing=active-listed
if missing: raise SystemExit(f"Pack-Stack unvollständig: {missing}")
print(f"OK: {len(active)} Pack-Manifeste in world_*_packs.json aktiviert.")
PY

IP4="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

============================================================
Minecraft Bedrock Server ist eingerichtet und getestet.
============================================================
Adresse im LAN:   ${IP4:-<CT-IP>}:$PORT4 (UDP)
Servername:       $SERVER_NAME
Welt:             $LEVEL_NAME
BDS:              $BDS_VER
Allowlist:        $ALLOWLIST_BOOL

Installierte Add-ons:
  - Bedrock Essentials+ 1.8.3   (Release; Tree Capitator + Vein Miner)
  - Advanced Gravestone 1.3.0   (Release)
  - Lilium Dynamic Light 2.1.0  (Release)
  - Epic Machinery 3.6.5        (Release)
  - Better on Bedrock 1.2.1     (Release)

Nützliche Befehle:
  mc-bedrock-status
  mc-bedrock-test
  mc-bedrock-backup
  mc-bedrock-update-bds
  mc-bedrock-update-addons          # nur prüfen
  mc-bedrock-update-addons --apply  # Release-Updates transaktional anwenden
  mc-bedrock-allowlist list
  mc-bedrock-allowlist add "Gamertag"
  mc-bedrock-allowlist remove "Gamertag"
  journalctl -u minecraft-bedrock -f

Timer:
  systemctl list-timers 'mc-bedrock-*'

Auf dem iPad: Minecraft -> Spielen -> Server -> Server hinzufügen,
Adresse ${IP4:-<CT-IP>}, Port $PORT4.
Im gleichen LAN ist sonst nichts nötig. Für Internetzugriff muss am Router
UDP $PORT4 auf ${IP4:-die CT-IP} weitergeleitet werden.
EOF