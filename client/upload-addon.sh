#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mc-bedrock-uploader"
CONFIG_FILE="$CONFIG_DIR/config"

usage(){
  cat <<'EOF'
Usage:
  upload-addon.sh SLUG /path/to/file.mcaddon
  upload-addon.sh /path/to/file.mcaddon        # asks for add-on
  upload-addon.sh                              # asks/selects both
  upload-addon.sh --reset                      # forget server URL/token

Known slugs:
  bedrock-essentials
  advanced-gravestone
  lilium-dynamic-light
  epic-machinery
  better-on-bedrock
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--reset" ]]; then rm -f "$CONFIG_FILE"; echo "Uploader-Konfiguration gelöscht."; exit 0; fi

SERVER_URL="${MC_BEDROCK_URL:-}"
UPLOAD_TOKEN="${MC_BEDROCK_TOKEN:-}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

if [[ -z "${SERVER_URL:-}" ]]; then
  read -r -p "Minecraft Upload-URL (z.B. http://192.168.20.50:19134): " SERVER_URL
fi
SERVER_URL="${SERVER_URL%/}"
[[ "$SERVER_URL" =~ ^https?:// ]] || { echo "Ungültige URL: $SERVER_URL" >&2; exit 2; }
if [[ -z "${UPLOAD_TOKEN:-}" ]]; then
  read -r -s -p "Upload-Token: " UPLOAD_TOKEN; printf '\n'
fi
[[ -n "$UPLOAD_TOKEN" ]] || { echo "Upload-Token fehlt." >&2; exit 2; }

mkdir -p "$CONFIG_DIR"
umask 077
printf 'SERVER_URL=%q\nUPLOAD_TOKEN=%q\n' "$SERVER_URL" "$UPLOAD_TOKEN" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

SLUG="${1:-}"
FILE="${2:-}"
if [[ -n "$SLUG" && -f "$SLUG" && -z "$FILE" ]]; then FILE="$SLUG"; SLUG=""; fi

choose_slug(){
  local items=(bedrock-essentials advanced-gravestone lilium-dynamic-light epic-machinery better-on-bedrock)
  local labels=("Bedrock Essentials+" "Advanced Gravestone" "Lilium Dynamic Light" "Epic Machinery" "Better on Bedrock")
  echo "Add-on auswählen:"
  local i
  for i in "${!items[@]}"; do printf '  %d) %s [%s]\n' "$((i+1))" "${labels[$i]}" "${items[$i]}"; done
  local n; read -r -p "Nummer: " n
  [[ "$n" =~ ^[1-5]$ ]] || { echo "Ungültige Auswahl." >&2; exit 2; }
  SLUG="${items[$((n-1))]}"
}

case "$SLUG" in
  bedrock-essentials|advanced-gravestone|lilium-dynamic-light|epic-machinery|better-on-bedrock) ;;
  "") choose_slug ;;
  *) echo "Unbekannter Slug: $SLUG" >&2; usage; exit 2 ;;
esac

if [[ -z "$FILE" ]]; then
  FILE="$(ls -t "$HOME/Downloads"/*.mcaddon "$HOME/Downloads"/*.mcpack "$HOME/Downloads"/*.zip 2>/dev/null | head -n1 || true)"
  if [[ -n "$FILE" ]]; then
    read -r -p "Neueste Add-on-Datei verwenden: $FILE ? [Y/n] " ans
    case "${ans:-y}" in y|Y|j|J|yes|YES|ja|JA) ;; *) FILE="";; esac
  fi
  if [[ -z "$FILE" ]]; then read -r -p "Pfad zur heruntergeladenen .mcaddon/.mcpack/.zip-Datei: " FILE; fi
fi
[[ -f "$FILE" ]] || { echo "Datei nicht gefunden: $FILE" >&2; exit 2; }

printf 'Prüfe Upload-Dienst … '
curl -fsS --connect-timeout 5 "$SERVER_URL/health" >/dev/null
echo "OK"

echo "Lade $(basename "$FILE") als $SLUG hoch. Der CT erstellt Backup, validiert, installiert und testet anschließend automatisch."
response="$(curl -sS --fail-with-body --connect-timeout 10 --max-time 360   -X PUT -H "Authorization: Bearer $UPLOAD_TOKEN" -H 'Content-Type: application/octet-stream'   --data-binary "@$FILE" "$SERVER_URL/upload/$SLUG")" || {
    rc=$?; echo "$response" >&2; exit "$rc";
  }
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool <<<"$response" 2>/dev/null || printf '%s\n' "$response"
else
  printf '%s\n' "$response"
fi
