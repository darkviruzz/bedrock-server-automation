#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022

# Minecraft Bedrock Dedicated Server + curated add-on workflow for Ubuntu 24.04 LXC.
# Installs BDS, backups, guarded BDS updates, add-on release monitoring, Gotify
# notifications, a token-protected LAN upload endpoint, and transactional manual
# add-on imports. CurseForge add-on downloads stay browser/manual by default.

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
  - Add-ons: Browser-Download auf CurseForge, danach lokaler Upload mit 1 Befehl
  - CurseForge-API: optional; dient NUR zur Release-Erkennung, nicht zum Mod-Download
  - täglicher Add-on-Check; Gotify meldet nur neue/noch offene Updates
  - token-geschützter Upload-Endpunkt nur fürs LAN, Standard TCP 19134
  - Add-on-Reihenfolge: Essentials+ > Gravestone > Dynamic Light > Epic Machinery > Better on Bedrock
    Damit bekommt Essentials+ bei möglichen Überschneidungen die höhere Priorität.

Ein CurseForge-API-Key ist optional. Ohne Key läuft der Server trotzdem; Updates
können dann für Third-Party-API-gesperrte Projekte nicht automatisch erkannt werden.
Der API-Key wird, falls vorhanden, nur root-lesbar gespeichert. Add-on-Dateien lädt
dieses Setup bewusst nicht automatisiert von CurseForge.
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
ask UPLOAD_PORT "LAN-Port für manuellen Add-on-Upload (TCP; NICHT ins Internet forwarden)" "19134"
[[ "$UPLOAD_PORT" =~ ^[0-9]+$ ]] && (( UPLOAD_PORT >= 1024 && UPLOAD_PORT <= 65535 )) || die "Ungültiger Upload-Port."

printf 'CurseForge API-Key für Release-Erkennung (optional; Enter = später): '
IFS= read -r -s CF_API_KEY || true
printf '\n'

ask GOTIFY_URL "Gotify Basis-URL für Update-Benachrichtigungen (leer = aus)" ""
GOTIFY_TOKEN=""
if [[ -n "$GOTIFY_URL" ]]; then
  GOTIFY_URL="${GOTIFY_URL%/}"
  printf 'Gotify Application-Token (Eingabe wird nicht angezeigt): '
  IFS= read -r -s GOTIFY_TOKEN || true
  printf '\n'
  [[ -n "$GOTIFY_TOKEN" ]] || die "Gotify-URL gesetzt, aber Application-Token fehlt."
fi

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
INCOMING="$BASE/incoming"
WORLD_DIR="$BASE/worlds/$LEVEL_NAME"
CF_BASE=https://api.curseforge.com/v1
MS_DOWNLOAD_API=https://net-secondary.web.minecraft-services.net/api/v1.0/download/links

export DEBIAN_FRONTEND=noninteractive
log "Installiere Betriebssystem-Abhängigkeiten …"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq unzip rsync python3 tar zstd tzdata iproute2 procps libatomic1 openssl
ln -snf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime || true
printf '%s\n' "$TZ_NAME" > /etc/timezone

getent group "$MC_GROUP" >/dev/null || groupadd --system "$MC_GROUP"
id "$MC_USER" >/dev/null 2>&1 || useradd --system --gid "$MC_GROUP" --home-dir "$BASE" --shell /usr/sbin/nologin "$MC_USER"
install -d -m 0755 "$RELEASES" "$ETC"
install -d -o "$MC_USER" -g "$MC_GROUP" -m 0755 "$BASE" "$BASE/worlds" "$ARCHIVES" "$PACKS" "$PACKS/behavior" "$PACKS/resource" "$STATE" "$BACKUPS" "$INCOMING" "$BASE/logs" "$BASE/config"
printf '%s\n' "$CF_API_KEY" > "$ETC/curseforge.key"
chmod 0600 "$ETC/curseforge.key"
UPLOAD_TOKEN="$(openssl rand -hex 24)"
printf '%s\n' "$UPLOAD_TOKEN" > "$ETC/upload.token"
chmod 0600 "$ETC/upload.token"
cat > "$ETC/gotify.env" <<EOF
GOTIFY_URL=$(printf '%q' "$GOTIFY_URL")
GOTIFY_TOKEN=$(printf '%q' "$GOTIFY_TOKEN")
EOF
chmod 0600 "$ETC/gotify.env"

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
UPLOAD_PORT=$UPLOAD_PORT
CF_BASE=$CF_BASE
MS_DOWNLOAD_API=$MS_DOWNLOAD_API
EOF
chmod 0644 "$ETC/settings.env"

# Curated add-on catalog. seedFileId points to the verified Release used for initial
# onboarding. Downloads are intentionally performed in the user's browser so that
# they go through CurseForge's own website/app path.
# Priority: higher number = listed higher in world pack stack.
cat > "$ETC/addons.catalog.json" <<'EOF'
[
  {"slug":"bedrock-essentials","name":"Bedrock Essentials+","projectId":1285412,"seedFileId":8837761,"priority":100,"projectUrl":"https://www.curseforge.com/minecraft-bedrock/addons/bedrock-essentials"},
  {"slug":"advanced-gravestone","name":"Advanced Gravestone","projectId":1471818,"seedFileId":8893465,"priority":90,"projectUrl":"https://www.curseforge.com/minecraft-bedrock/addons/advanced-gravestone"},
  {"slug":"lilium-dynamic-light","name":"Lilium Dynamic Light","projectId":1575969,"seedFileId":8943140,"priority":80,"projectUrl":"https://www.curseforge.com/minecraft-bedrock/addons/lilium-dynamic-light"},
  {"slug":"epic-machinery","name":"Epic Machinery","projectId":1377615,"seedFileId":8671527,"priority":70,"projectUrl":"https://www.curseforge.com/minecraft-bedrock/addons/epic-machinery"},
  {"slug":"better-on-bedrock","name":"Better on Bedrock","projectId":1057117,"seedFileId":7951504,"priority":60,"projectUrl":"https://www.curseforge.com/minecraft-bedrock/addons/better-on-bedrock"}
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
GOTIFY_FILE="$ETC/gotify.env"
UPLOAD_TOKEN_FILE="$ETC/upload.token"
CATALOG="$ETC/addons.catalog.json"
RELEASES="$OPT/releases"; CURRENT="$OPT/current"; ARCHIVES="$BASE/addon_archives"; PACKS="$BASE/packs"; STATE="$BASE/state"; BACKUPS="$BASE/backups"; INCOMING="$BASE/incoming"
log(){ printf '[mc-bedrock] %s\n' "$*"; }
cf_has_key(){ [[ -s "$CF_KEY_FILE" ]] && [[ -n "$(tr -d '\r\n' < "$CF_KEY_FILE")" ]]; }
cf_key(){ tr -d '\r\n' < "$CF_KEY_FILE"; }
cf_get(){ cf_has_key || return 90; curl -fsSL --retry 2 --connect-timeout 15 -H 'Accept: application/json' -H "x-api-key: $(cf_key)" "$1"; }
cf_get_optional(){ cf_has_key || return 90; curl -sS --retry 1 --connect-timeout 15 --max-time 45 -H 'Accept: application/json' -H "x-api-key: $(cf_key)" -w '\n%{http_code}' "$1"; }
bds_url(){ curl -fsSL --retry 3 --connect-timeout 15 "$MS_DOWNLOAD_API" | jq -er '.result.links[] | select(.downloadType=="serverBedrockLinux") | .downloadUrl' | head -n1; }
bds_version_from_url(){ basename "$1" | sed -nE 's/^bedrock-server-([0-9.]+)\.zip$/\1/p'; }
mc_active(){ systemctl is-active --quiet minecraft-bedrock.service; }
stop_mc(){ systemctl stop minecraft-bedrock.service 2>/dev/null || true; }
start_mc(){ systemctl start minecraft-bedrock.service; }
addon_file_page(){ local slug="$1" fid="$2"; printf 'https://www.curseforge.com/minecraft-bedrock/addons/%s/files/%s' "$slug" "$fid"; }
addon_files_page(){ local slug="$1"; printf 'https://www.curseforge.com/minecraft-bedrock/addons/%s/files/all' "$slug"; }
notify(){
  local title="$1" message="$2" priority="${3:-5}"
  [[ -s "$GOTIFY_FILE" ]] || { log "$title: $message"; return 0; }
  # shellcheck disable=SC1090
  source "$GOTIFY_FILE"
  if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then log "$title: $message"; return 0; fi
  local payload
  payload="$(jq -nc --arg title "$title" --arg message "$message" --argjson priority "$priority" '{title:$title,message:$message,priority:$priority,extras:{"client::display":{contentType:"text/markdown"}}}')"
  curl -fsS --retry 2 --connect-timeout 10 -H 'Content-Type: application/json' -H "X-Gotify-Key: $GOTIFY_TOKEN" -d "$payload" "$GOTIFY_URL/message" >/dev/null || log "Gotify-Benachrichtigung fehlgeschlagen: $title"
}
notify_throttled(){
  local key="$1" days="$2" title="$3" message="$4" priority="${5:-5}" f="$STATE/notifications.json" now last cutoff tmp
  now="$(date +%s)"; cutoff=$((days*86400)); [[ -f "$f" ]] || printf '{}\n' > "$f"
  last="$(jq -r --arg k "$key" '.[$k] // 0' "$f" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < cutoff )); then return 0; fi
  notify "$title" "$message" "$priority"
  tmp="${f}.tmp"; jq --arg k "$key" --argjson n "$now" '.[$k]=$n' "$f" > "$tmp" && mv "$tmp" "$f"
}
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

# Start with an empty installed-add-on lock. The five desired add-ons are in the
# catalog and are installed transactionally after a normal browser download.
printf '[]\n' > "$BASE/addon-lock.json"
install -d -o "$MC_USER" -g "$MC_GROUP" "$WORLD_DIR"
/usr/local/lib/mc-bedrock-addon-manager.py build \
  --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" \
  --world "$WORLD_DIR" --lock "$BASE/addon-lock.json" --report "$STATE/active-packs.json" >/tmp/mc-bedrock-packs.json
# Initial pending list points at known stable file pages. API monitoring can replace
# these with newer Release IDs later, but never downloads the file itself.
jq '[.[] | {slug,name,projectId,priority,fileId:.seedFileId,fileName:null,fileDate:null,reason:"initial-install",apiVisible:false,projectUrl,downloadPage:(.projectUrl + "/files/" + (.seedFileId|tostring))}]' \
  "$ETC/addons.catalog.json" > "$STATE/pending-updates.json"
printf '{}\n' > "$STATE/notifications.json"
chown -R "$MC_USER:$MC_GROUP" "$ARCHIVES" "$PACKS" "$WORLD_DIR" "$STATE" "$BASE/addon-lock.json"

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
notify "Minecraft BDS Update" "BDS-Update wird installiert: **$old → $new**" 4
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
  notify "Minecraft BDS aktualisiert" "BDS **$new** läuft und hat den Healthcheck bestanden." 4
  exit 0
fi
log "BDS Update fehlgeschlagen; Rollback auf $old inklusive Weltbackup."
notify "Minecraft BDS Rollback" "Update auf **$new** ist fehlgeschlagen. Rollback auf **$old** wird ausgeführt." 8
stop_mc
ln -sfn "$RELEASES/$old" "$CURRENT"
/usr/local/sbin/mc-bedrock-restore-backup "$backup"
exit 1
SH
chmod 0755 /usr/local/sbin/mc-bedrock-update-bds

# Transactional manual add-on importer. The browser download happens outside the
# server; this command validates and installs the supplied archive.
cat > /usr/local/sbin/mc-bedrock-import-addon <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
[[ $# -ge 2 ]] || { echo "Usage: $0 SLUG ARCHIVE [CURSEFORGE_FILE_ID]" >&2; exit 2; }
slug="$1"; src="$2"; requested_fid="${3:-}"
[[ -f "$src" ]] || { echo "Datei fehlt: $src" >&2; exit 2; }
catalog_entry="$(jq -ce --arg s "$slug" '.[] | select(.slug==$s)' "$CATALOG")" || { echo "Unbekanntes Add-on: $slug" >&2; exit 2; }
name="$(jq -r '.name' <<<"$catalog_entry")"
pid="$(jq -r '.projectId' <<<"$catalog_entry")"
# Prefer the File ID recorded by the update checker. For an initial/manual install
# without API metadata we keep the known onboarding ID if supplied by pending state.
if [[ -z "$requested_fid" && -f "$STATE/pending-updates.json" ]]; then
  requested_fid="$(jq -r --arg s "$slug" '.[] | select(.slug==$s) | .fileId // empty' "$STATE/pending-updates.json" | head -n1)"
fi
if [[ -n "$requested_fid" && ! "$requested_fid" =~ ^[0-9]+$ ]]; then requested_fid=""; fi
# If the update was discovered through the API, verify that the browser-downloaded
# bytes are exactly the expected CurseForge file before recording its File ID.
if [[ -n "$requested_fid" ]] && cf_has_key; then
  meta="$(cf_get "$CF_BASE/mods/$pid/files/$requested_fid" || true)"
  if [[ -n "$meta" ]]; then
    want_sha1="$(jq -r '.data.hashes[]? | select(.algo==1) | .value' <<<"$meta" | head -n1)"
    want_md5="$(jq -r '.data.hashes[]? | select(.algo==2) | .value' <<<"$meta" | head -n1)"
    if [[ -n "$want_sha1" ]]; then
      got="$(sha1sum "$src" | awk '{print $1}')"; [[ "${got,,}" == "${want_sha1,,}" ]] || { echo "Datei entspricht nicht dem erwarteten CurseForge File $requested_fid (SHA1)." >&2; exit 3; }
    elif [[ -n "$want_md5" ]]; then
      got="$(md5sum "$src" | awk '{print $1}')"; [[ "${got,,}" == "${want_md5,,}" ]] || { echo "Datei entspricht nicht dem erwarteten CurseForge File $requested_fid (MD5)." >&2; exit 3; }
    fi
  fi
fi
was_active=0; mc_active && was_active=1
backup=""; [[ $was_active -eq 1 ]] && backup="$(/usr/local/sbin/mc-bedrock-backup --leave-stopped)" || stop_mc
snap="$(mktemp -d)"; trap 'rm -rf "$snap"' EXIT
cp -a "$ARCHIVES" "$snap/archives"
cp -a "$BASE/addon-lock.json" "$snap/lock.json"
rollback(){
  local rc="${1:-1}"
  set +e
  stop_mc
  rm -rf "$ARCHIVES"; cp -a "$snap/archives" "$ARCHIVES"
  cp -a "$snap/lock.json" "$BASE/addon-lock.json"
  /usr/local/lib/mc-bedrock-addon-manager.py build --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" --world "$BASE/worlds/$LEVEL_NAME" --lock "$BASE/addon-lock.json" --report "$STATE/active-packs.json" >/dev/null 2>&1 || true
  if [[ -e "$CURRENT" ]]; then release_link_persistent "$CURRENT" || true; fi
  if [[ -n "$backup" && -f "$backup" ]]; then /usr/local/sbin/mc-bedrock-restore-backup "$backup" >/dev/null 2>&1 || true
  elif [[ $was_active -eq 1 ]]; then start_mc || true
  fi
  notify "Minecraft Add-on Rollback" "Installation von **$name** ist fehlgeschlagen; vorheriger Stand wurde wiederhergestellt." 8
  exit "$rc"
}
trap 'rollback $?' ERR
# Basic archive sanity before replacing the active copy.
python3 - "$src" <<'PY'
import sys, zipfile
p=sys.argv[1]
if not zipfile.is_zipfile(p): raise SystemExit(f"Kein gültiges ZIP/mcaddon/mcpack: {p}")
with zipfile.ZipFile(p) as z:
    if len(z.infolist()) > 20000: raise SystemExit("Archiv enthält ungewöhnlich viele Dateien")
    total=sum(i.file_size for i in z.infolist())
    if total > 1024*1024*1024: raise SystemExit("Entpackte Archivgröße > 1 GiB abgelehnt")
PY
cp -f "$src" "$ARCHIVES/$slug.mcaddon"
# Replace/add lock entry using catalog metadata; fileId is nullable for purely manual installs.
new_entry="$(jq -c --argjson c "$catalog_entry" --arg fid "$requested_fid" --arg now "$(date -Is)" '$c + {fileId:(if $fid=="" then null else ($fid|tonumber) end),installedAt:$now,source:"manual-browser-download"}' <<< '{}')"
tmp_lock="$(mktemp)"
jq --arg s "$slug" --argjson e "$new_entry" '[.[]|select(.slug!=$s)] + [$e] | sort_by(.priority) | reverse' "$BASE/addon-lock.json" > "$tmp_lock"
mv "$tmp_lock" "$BASE/addon-lock.json"
/usr/local/lib/mc-bedrock-addon-manager.py build --archives "$ARCHIVES" --behavior "$PACKS/behavior" --resource "$PACKS/resource" --world "$BASE/worlds/$LEVEL_NAME" --lock "$BASE/addon-lock.json" --report "$STATE/active-packs.json" >/dev/null
chown -R "$MC_USER:$MC_GROUP" "$ARCHIVES" "$PACKS" "$BASE/worlds/$LEVEL_NAME" "$STATE" "$BASE/addon-lock.json"
release_link_persistent "$CURRENT"
start_mc
/usr/local/sbin/mc-bedrock-test 120
# Remove only this pending item. A later API check may add it again if a newer ID exists.
if [[ -f "$STATE/pending-updates.json" ]]; then
  jq --arg s "$slug" '[.[]|select(.slug!=$s)]' "$STATE/pending-updates.json" > "$STATE/pending-updates.json.n" && mv "$STATE/pending-updates.json.n" "$STATE/pending-updates.json"
fi
trap - ERR
notify "Minecraft Add-on installiert" "**$name** wurde validiert, installiert und der Server-Healthcheck ist erfolgreich." 5
echo "OK: $name installiert."
SH
chmod 0755 /usr/local/sbin/mc-bedrock-import-addon

# API key can be added/replaced later without rerunning the setup.
cat > /usr/local/sbin/mc-bedrock-set-curseforge-key <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
printf 'CurseForge API-Key: '
IFS= read -r -s key
printf '\n'
[[ -n "$key" ]] || { echo "Kein Key eingegeben." >&2; exit 2; }
printf '%s\n' "$key" > "$CF_KEY_FILE"
chmod 0600 "$CF_KEY_FILE"
if cf_get "$CF_BASE/games" >/dev/null; then
  echo "API-Key akzeptiert. Starte sofortigen Add-on-Check."
  /usr/local/sbin/mc-bedrock-update-addons || true
else
  echo "API-Key gespeichert, Testaufruf war jedoch nicht erfolgreich." >&2
  exit 1
fi
SH
chmod 0755 /usr/local/sbin/mc-bedrock-set-curseforge-key

# Add-on release checker. It NEVER downloads mod files. Where the author's
# distribution setting permits API visibility, it detects the latest Release and
# sends a clickable CurseForge file-page link. If API visibility is blocked, the
# official API cannot be used even for release metadata; we send a throttled
# manual-check reminder instead of scraping the website.
cat > /usr/local/sbin/mc-bedrock-update-addons <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
lock="$BASE/addon-lock.json"; pending_tmp="$(mktemp)"; trap 'rm -f "$pending_tmp"' EXIT
printf '[]\n' > "$pending_tmp"
api_key=0; cf_has_key && api_key=1
while IFS=$'\t' read -r slug name pid seedfid project_url; do
  installed_fid="$(jq -r --arg s "$slug" '.[]|select(.slug==$s)|.fileId // empty' "$lock" | head -n1)"
  installed="$(jq -r --arg s "$slug" 'any(.[]; .slug==$s)' "$lock")"
  if [[ $api_key -eq 0 ]]; then
    if [[ "$installed" != true ]]; then
      page="$(addon_file_page "$slug" "$seedfid")"
      jq --arg s "$slug" --arg n "$name" --argjson p "$pid" --argjson f "$seedfid" --arg u "$project_url" --arg d "$page" '. + [{slug:$s,name:$n,projectId:$p,fileId:$f,reason:"initial-install",apiVisible:false,projectUrl:$u,downloadPage:$d}]' "$pending_tmp" > "$pending_tmp.n" && mv "$pending_tmp.n" "$pending_tmp"
    fi
    continue
  fi

  response="$(cf_get_optional "$CF_BASE/mods/$pid/files?pageSize=50" || true)"
  code="$(tail -n1 <<<"$response")"; body="$(sed '$d' <<<"$response")"
  if [[ "$code" != 200 ]]; then
    # CurseForge explicitly hides projects/files from the third-party API when
    # the author disables third-party distribution. Do not scrape around it.
    if [[ "$installed" != true ]]; then
      seedpage="$(addon_file_page "$slug" "$seedfid")"
      jq --arg s "$slug" --arg n "$name" --argjson p "$pid" --argjson f "$seedfid" --arg u "$project_url" --arg d "$seedpage" '. + [{slug:$s,name:$n,projectId:$p,fileId:$f,reason:"initial-install-api-unavailable",apiVisible:false,projectUrl:$u,downloadPage:$d}]' "$pending_tmp" > "$pending_tmp.n" && mv "$pending_tmp.n" "$pending_tmp"
    fi
    msg="**$name** kann über die CurseForge-Third-Party-API nicht überwacht werden (HTTP $code).\n\n[Projekt/Dateien manuell prüfen]($(addon_files_page "$slug"))\n\nDas ist nur ein Erinnerungslink; der Server lädt nichts automatisch herunter."
    notify_throttled "api-unavailable-$slug" 30 "Minecraft Add-on: manueller Check" "$msg" 4
    continue
  fi
  latest="$(jq -c '[.data[] | select(.releaseType==1 and (.isEarlyAccessContent != true))] | sort_by(.fileDate) | last // empty' <<<"$body" 2>/dev/null || true)"
  [[ -n "$latest" ]] || continue
  fid="$(jq -r '.id' <<<"$latest")"; fname="$(jq -r '.fileName' <<<"$latest")"; fdate="$(jq -r '.fileDate' <<<"$latest")"
  # A file installed manually while no API key was available has fileId=null. If
  # its hash matches the current API-visible Release, reconcile the lock silently.
  if [[ "$installed" == true && -z "$installed_fid" && -f "$ARCHIVES/$slug.mcaddon" ]]; then
    want_sha1="$(jq -r '.hashes[]? | select(.algo==1) | .value' <<<"$latest" | head -n1)"
    want_md5="$(jq -r '.hashes[]? | select(.algo==2) | .value' <<<"$latest" | head -n1)"
    matched=0
    if [[ -n "$want_sha1" ]]; then got="$(sha1sum "$ARCHIVES/$slug.mcaddon" | awk '{print $1}')"; [[ "${got,,}" == "${want_sha1,,}" ]] && matched=1
    elif [[ -n "$want_md5" ]]; then got="$(md5sum "$ARCHIVES/$slug.mcaddon" | awk '{print $1}')"; [[ "${got,,}" == "${want_md5,,}" ]] && matched=1
    fi
    if [[ $matched -eq 1 ]]; then
      jq --arg s "$slug" --argjson f "$fid" 'map(if .slug==$s then .fileId=$f else . end)' "$lock" > "$lock.n" && mv "$lock.n" "$lock"
      installed_fid="$fid"
    fi
  fi
  if [[ "$installed" != true || "$fid" != "$installed_fid" ]]; then
    page="$(addon_file_page "$slug" "$fid")"
    reason="update"; [[ "$installed" != true ]] && reason="initial-install"
    jq --arg s "$slug" --arg n "$name" --argjson p "$pid" --argjson f "$fid" --arg fn "$fname" --arg fd "$fdate" --arg r "$reason" --arg u "$project_url" --arg d "$page" '. + [{slug:$s,name:$n,projectId:$p,fileId:$f,fileName:$fn,fileDate:$fd,reason:$r,apiVisible:true,projectUrl:$u,downloadPage:$d}]' "$pending_tmp" > "$pending_tmp.n" && mv "$pending_tmp.n" "$pending_tmp"
    old="${installed_fid:-nicht installiert}"
    msg="**$name**: CurseForge Release verfügbar.\n\nInstalliert: \`$old\`  →  verfügbar: \`$fid\`\nDatei: \`$fname\`\n\n[Download auf CurseForge öffnen]($page)\n\nDanach lokal aus dem Repo ausführen:\n\`./client/upload-addon.sh $slug /Pfad/zur/Datei.mcaddon\`\noder Windows:\n\`.\client\upload-addon.ps1 -Slug $slug -File C:\\Pfad\\Datei.mcaddon\`"
    notify_throttled "release-$slug-$fid" 7 "Minecraft Add-on Update" "$msg" 7
  fi
done < <(jq -r '.[]|[.slug,.name,.projectId,.seedFileId,.projectUrl]|@tsv' "$CATALOG")
mv "$pending_tmp" "$STATE/pending-updates.json"
chown "$MC_USER:$MC_GROUP" "$STATE/pending-updates.json"
count="$(jq 'length' "$STATE/pending-updates.json")"
echo "$count manuelle Add-on-Aktion(en) offen."
[[ $api_key -eq 1 ]] || notify_throttled "no-cf-api-key" 14 "Minecraft: CurseForge API-Key fehlt" "Der Server läuft, aber Add-on-Releases können ohne API-Key nicht automatisch abgefragt werden. Sobald der Key genehmigt ist: \`sudo mc-bedrock-set-curseforge-key\`." 3
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
echo 'Installierte Add-ons:'
jq -r '.[] | "  - \(.name): CurseForge file \(.fileId // \"manuell/unbekannt\")"' "$BASE/addon-lock.json"
echo 'Offene manuelle Aktionen:'
if [[ -f "$STATE/pending-updates.json" ]]; then jq -r '.[] | "  - \(.name): \(.downloadPage // .projectUrl)"' "$STATE/pending-updates.json"; else echo '  - keine'; fi
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

# Token-authenticated LAN upload endpoint. It accepts only one of the five known
# slugs and hands the archive to the transactional importer. Do not forward this
# TCP port from the Internet; it is intended for the local/VPN network only.
cat > /usr/local/lib/mc-bedrock-upload-server.py <<'PY'
#!/usr/bin/env python3
import json, os, re, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

BASE=Path('/srv/minecraft-bedrock')
ETC=Path('/etc/minecraft-bedrock')
CATALOG=ETC/'addons.catalog.json'
PENDING=BASE/'state'/'pending-updates.json'
TOKEN_FILE=ETC/'upload.token'
MAX_SIZE=256*1024*1024
PORT=int(os.environ.get('MC_UPLOAD_PORT','19134'))

def load_json(path, default):
    try: return json.loads(path.read_text(encoding='utf-8'))
    except Exception: return default

def token():
    return TOKEN_FILE.read_text(encoding='utf-8').strip()

def allowed_slug(slug):
    return any(x.get('slug')==slug for x in load_json(CATALOG,[]))

def pending_file_id(slug):
    for x in load_json(PENDING,[]):
        if x.get('slug')==slug and x.get('apiVisible') is True and isinstance(x.get('fileId'),int): return str(x['fileId'])
    return ''

class H(BaseHTTPRequestHandler):
    server_version='mc-bedrock-upload/1.0'
    def log_message(self, fmt, *args):
        print('%s - %s' % (self.address_string(), fmt%args), flush=True)
    def auth(self):
        h=self.headers.get('Authorization','')
        return h.startswith('Bearer ') and h[7:]==token()
    def send_json(self, code, obj):
        data=json.dumps(obj,ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path=urlparse(self.path).path
        if path=='/health': return self.send_json(200,{'ok':True})
        if not self.auth(): return self.send_json(401,{'ok':False,'error':'unauthorized'})
        if path=='/pending': return self.send_json(200,load_json(PENDING,[]))
        if path=='/catalog': return self.send_json(200,load_json(CATALOG,[]))
        return self.send_json(404,{'ok':False,'error':'not found'})
    def do_PUT(self):
        path=urlparse(self.path).path
        if not self.auth(): return self.send_json(401,{'ok':False,'error':'unauthorized'})
        m=re.fullmatch(r'/upload/([a-z0-9-]+)',path)
        if not m: return self.send_json(404,{'ok':False,'error':'unknown endpoint'})
        slug=m.group(1)
        if not allowed_slug(slug): return self.send_json(400,{'ok':False,'error':'unknown addon slug'})
        try: n=int(self.headers.get('Content-Length','0'))
        except ValueError: n=0
        if n<=0 or n>MAX_SIZE: return self.send_json(413,{'ok':False,'error':'invalid/too large Content-Length','maxBytes':MAX_SIZE})
        BASE.joinpath('incoming').mkdir(parents=True,exist_ok=True)
        fd,tmp=tempfile.mkstemp(prefix=slug+'-',suffix='.mcaddon',dir=BASE/'incoming')
        try:
            with os.fdopen(fd,'wb') as f:
                left=n
                while left:
                    chunk=self.rfile.read(min(left,1024*1024))
                    if not chunk: raise RuntimeError('connection ended before Content-Length')
                    f.write(chunk); left-=len(chunk)
            fid=pending_file_id(slug)
            cmd=['/usr/local/sbin/mc-bedrock-import-addon',slug,tmp]
            if fid: cmd.append(fid)
            cp=subprocess.run(cmd,text=True,capture_output=True,timeout=300)
            if cp.returncode:
                return self.send_json(400,{'ok':False,'slug':slug,'stdout':cp.stdout[-8000:],'stderr':cp.stderr[-8000:]})
            return self.send_json(200,{'ok':True,'slug':slug,'message':cp.stdout.strip()})
        except subprocess.TimeoutExpired:
            return self.send_json(504,{'ok':False,'error':'import timeout'})
        except Exception as e:
            return self.send_json(500,{'ok':False,'error':str(e)})
        finally:
            try: os.unlink(tmp)
            except OSError: pass

ThreadingHTTPServer(('0.0.0.0',PORT),H).serve_forever()
PY
chmod 0755 /usr/local/lib/mc-bedrock-upload-server.py

cat > /etc/systemd/system/mc-bedrock-upload.service <<EOF
[Unit]
Description=Minecraft Bedrock local add-on upload endpoint
After=network-online.target minecraft-bedrock.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=MC_UPLOAD_PORT=$UPLOAD_PORT
ExecStart=/usr/bin/python3 /usr/local/lib/mc-bedrock-upload-server.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$BASE $OPT
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/mc-bedrock-upload-info <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/mc-bedrock-common.sh
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf 'Server URL: http://%s:%s\n' "${ip:-<CT-IP>}" "$UPLOAD_PORT"
printf 'Upload token: %s\n' "$(cat "$UPLOAD_TOKEN_FILE")"
printf 'Pending:\n'
[[ -f "$STATE/pending-updates.json" ]] && jq -r '.[] | "  - \(.slug): \(.downloadPage // .projectUrl)"' "$STATE/pending-updates.json" || true
SH
chmod 0750 /usr/local/sbin/mc-bedrock-upload-info

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

cat > /etc/systemd/system/mc-bedrock-update-addons.service <<'EOF'
[Unit]
Description=Minecraft Bedrock add-on Release metadata check
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mc-bedrock-update-addons
EOF
cat > /etc/systemd/system/mc-bedrock-update-addons.timer <<'EOF'
[Unit]
Description=Minecraft Bedrock daily add-on Release metadata check
[Timer]
OnCalendar=*-*-* 08:15:00
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable minecraft-bedrock.service mc-bedrock-upload.service mc-bedrock-backup.timer mc-bedrock-update-addons.timer >/dev/null
if [[ "$AUTO_BDS" == y ]]; then systemctl enable mc-bedrock-update-bds.timer >/dev/null; else systemctl disable mc-bedrock-update-bds.timer >/dev/null 2>&1 || true; fi
systemctl start mc-bedrock-backup.timer mc-bedrock-update-addons.timer
[[ "$AUTO_BDS" == y ]] && systemctl start mc-bedrock-update-bds.timer || true

log "Starte Server und führe Live-Selbsttest aus …"
systemctl enable --now minecraft-bedrock.service
/usr/local/sbin/mc-bedrock-test 120
systemctl enable --now mc-bedrock-upload.service
for _ in {1..20}; do curl -fsS "http://127.0.0.1:$UPLOAD_PORT/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$UPLOAD_PORT/health" >/dev/null || die "Lokaler Add-on-Uploaddienst ist nicht erreichbar."

# Populate/refresh pending metadata and send a first notification when configured.
/usr/local/sbin/mc-bedrock-update-addons || true
if [[ -s "$STATE/pending-updates.json" ]] && [[ "$(jq 'length' "$STATE/pending-updates.json")" -gt 0 ]]; then
  links="$(jq -r '.[] | "- [\(.name)](\(.downloadPage // .projectUrl)) — Slug: `\(.slug)`"' "$STATE/pending-updates.json")"
  notify_throttled "initial-addon-onboarding" 3650 "Minecraft Add-ons: Download erforderlich" "Die gewünschten Add-ons werden über CurseForge im Browser geladen.\n\n$links\n\nNach jedem Download den lokalen `client/upload-addon`-Helper verwenden; der CT erledigt danach Installation und Test automatisch." 6
fi

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

Add-ons:
  Die fünf gewünschten Add-ons werden bewusst über die normalen CurseForge-
  Downloadseiten bezogen. Nach dem Download übernimmt der lokale Uploader
  Installation, Backup, Prüfung und Rollback automatisch.

Lokaler Upload-Dienst (NICHT am Router ins Internet weiterleiten):
  URL:           http://${IP4:-<CT-IP>}:$UPLOAD_PORT
  Upload-Token:  $UPLOAD_TOKEN

Nützliche Befehle:
  mc-bedrock-status
  mc-bedrock-test