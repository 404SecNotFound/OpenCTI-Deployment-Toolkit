#!/usr/bin/env bash
###############################################################################
# add-connector.sh - Add an OpenCTI connector via docker-compose injection
#
# What it does:
#   1. Loads a connector template (built-in or custom YAML file)
#   2. Substitutes placeholders (UUID, OPENCTI_TOKEN, API keys, etc.)
#   3. Injects the rendered block into /opt/opencti/docker-compose.yml
#   4. Adds any new env vars to .env
#   5. Starts the connector
#   6. Tails logs so you see it working
#
# Built-in templates (use --template <name>):
#   alienvault    AlienVault OTX pulses
#   mitre         MITRE ATT&CK datasets
#   abuseipdb     AbuseIPDB IP reputation
#   threatfox     ThreatFox IOCs from abuse.ch
#   urlhaus       URLhaus malicious URLs
#   misp          MISP feed import (needs MISP URL + key)
#   tweetfeed     TweetFeed IOCs from Twitter
#
# Custom: --file path/to/your-connector.yaml
#
# Usage examples:
#   sudo ./add-connector.sh --template alienvault --api-key YOUR_OTX_KEY
#   sudo ./add-connector.sh --template abuseipdb --api-key YOUR_KEY
#   sudo ./add-connector.sh --template threatfox        # no API key needed
#   sudo ./add-connector.sh --file ./my-custom-connector.yaml
#   sudo ./add-connector.sh --list                       # show built-in templates
#   sudo ./add-connector.sh --remove connector-alienvault
#
###############################################################################

set -euo pipefail

OPENCTI_DIR="${OPENCTI_INSTALL_DIR:-/opt/opencti}"
COMPOSE_FILE="$OPENCTI_DIR/docker-compose.yml"
ENV_FILE="$OPENCTI_DIR/.env"

C_RESET="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[1;32m"; C_YEL="\033[1;33m"
log()  { printf "%b[+]%b %s\n" "$C_GRN" "$C_RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YEL" "$C_RESET" "$*"; }
err()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

###############################################################################
# Argument parsing
###############################################################################
TEMPLATE=""
CUSTOM_FILE=""
API_KEY=""
ACTION="add"
REMOVE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)  TEMPLATE="$2"; shift 2 ;;
    --file)      CUSTOM_FILE="$2"; shift 2 ;;
    --api-key)   API_KEY="$2"; shift 2 ;;
    --list)      ACTION="list"; shift ;;
    --remove)    ACTION="remove"; REMOVE_NAME="$2"; shift 2 ;;
    --help|-h)
      sed -n '/^# add-connector/,/^###############################################################################$/p' "$0" \
        | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { err "Run as root (sudo)"; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { err "$COMPOSE_FILE not found"; exit 1; }
[[ -f "$ENV_FILE" ]] || { err "$ENV_FILE not found"; exit 1; }

###############################################################################
# List built-in templates
###############################################################################
if [[ "$ACTION" == "list" ]]; then
  cat <<EOF

Built-in connector templates:

  alienvault    AlienVault OTX (requires --api-key)
  mitre         MITRE ATT&CK (no key needed)
  abuseipdb     AbuseIPDB (requires --api-key)
  threatfox     ThreatFox / abuse.ch (no key needed)
  urlhaus       URLhaus / abuse.ch (no key needed)
  misp          MISP feed (requires --api-key, edit MISP_URL inline)
  tweetfeed     TweetFeed (no key needed)

Use:  sudo ./add-connector.sh --template <name> [--api-key <key>]

For anything else, write your own YAML and use --file.

EOF
  exit 0
fi

###############################################################################
# Remove a connector
###############################################################################
if [[ "$ACTION" == "remove" ]]; then
  [[ -n "$REMOVE_NAME" ]] || { err "--remove needs a service name"; exit 2; }

  log "Stopping $REMOVE_NAME"
  cd "$OPENCTI_DIR"
  docker compose stop "$REMOVE_NAME" 2>/dev/null || true
  docker compose rm -f "$REMOVE_NAME" 2>/dev/null || true

  log "Removing $REMOVE_NAME from $COMPOSE_FILE"
  cp "$COMPOSE_FILE" "${COMPOSE_FILE}.pre-remove.$(date +%s).bak"

  python3 - "$COMPOSE_FILE" "$REMOVE_NAME" <<'PY'
import sys, re
from pathlib import Path
path, name = sys.argv[1], sys.argv[2]
text = Path(path).read_text()
lines = text.splitlines()
out, skip = [], False
for line in lines:
    m = re.match(r'^(\s{2})([\w\-]+):\s*$', line)
    if m and m.group(2) == name:
        skip = True; continue
    if skip and re.match(r'^\s{2}[\w\-]+:\s*$', line):
        skip = False
    if not skip:
        out.append(line)
Path(path).write_text("\n".join(out) + "\n")
print(f"removed service {name}")
PY

  log "Done. Container stopped and removed from compose."
  exit 0
fi

###############################################################################
# Resolve template content
###############################################################################
get_template() {
  local name="$1"
  case "$name" in
    alienvault)
      cat <<'TEMPLATE'
  connector-alienvault:
    image: opencti/connector-alienvault:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=AlienVault
      - CONNECTOR_SCOPE=alienvault
      - CONNECTOR_LOG_LEVEL=info
      - CONNECTOR_DURATION_PERIOD=PT30M
      - ALIENVAULT_BASE_URL=https://otx.alienvault.com
      - ALIENVAULT_API_KEY=__API_KEY__
      - ALIENVAULT_TLP=TLP:WHITE
      - ALIENVAULT_CREATE_OBSERVABLES=true
      - ALIENVAULT_CREATE_INDICATORS=true
      - ALIENVAULT_PULSE_START_TIMESTAMP=2024-01-01T00:00:00
      - ALIENVAULT_REPORT_TYPE=threat-report
      - ALIENVAULT_REPORT_STATUS=New
      - ALIENVAULT_GUESS_MALWARE=false
      - ALIENVAULT_GUESS_CVE=false
      - ALIENVAULT_EXCLUDED_PULSE_INDICATOR_TYPES=FileHash-MD5,FileHash-SHA1
      - ALIENVAULT_INTERVAL_SEC=1800
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    mitre)
      cat <<'TEMPLATE'
  connector-mitre-attack:
    image: opencti/connector-mitre:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=MITRE Datasets
      - CONNECTOR_SCOPE=tool,report,malware,identity,campaign,intrusion-set,attack-pattern,course-of-action,x-mitre-data-source,x-mitre-data-component,x-mitre-matrix,x-mitre-tactic,x-mitre-collection
      - CONNECTOR_RUN_AND_TERMINATE=false
      - CONNECTOR_LOG_LEVEL=info
      - MITRE_REMOVE_STATEMENT_MARKING=true
      - MITRE_INTERVAL=7
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    abuseipdb)
      cat <<'TEMPLATE'
  connector-abuseipdb:
    image: opencti/connector-abuseipdb:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=INTERNAL_ENRICHMENT
      - CONNECTOR_NAME=AbuseIPDB
      - CONNECTOR_SCOPE=IPv4-Addr
      - CONNECTOR_AUTO=true
      - CONNECTOR_LOG_LEVEL=info
      - ABUSEIPDB_API_KEY=__API_KEY__
      - ABUSEIPDB_MAX_TLP=TLP:AMBER
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    threatfox)
      cat <<'TEMPLATE'
  connector-threatfox:
    image: opencti/connector-threatfox:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=ThreatFox
      - CONNECTOR_SCOPE=threatfox
      - CONNECTOR_LOG_LEVEL=info
      - THREATFOX_CSV_URL=https://threatfox.abuse.ch/export/csv/recent/
      - THREATFOX_IMPORT_OFFLINE=true
      - THREATFOX_CREATE_INDICATORS=true
      - THREATFOX_DEFAULT_X_OPENCTI_SCORE=50
      - THREATFOX_INTERVAL=3
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    urlhaus)
      cat <<'TEMPLATE'
  connector-urlhaus:
    image: opencti/connector-urlhaus:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=URLhaus
      - CONNECTOR_SCOPE=urlhaus
      - CONNECTOR_LOG_LEVEL=info
      - URLHAUS_CSV_URL=https://urlhaus.abuse.ch/downloads/csv_recent/
      - URLHAUS_IMPORT_OFFLINE=true
      - URLHAUS_CREATE_INDICATORS=true
      - URLHAUS_THREATS_FROM_LABELS=true
      - URLHAUS_INTERVAL=3
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    misp)
      cat <<'TEMPLATE'
  connector-misp:
    image: opencti/connector-misp:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=MISP
      - CONNECTOR_SCOPE=misp
      - CONNECTOR_LOG_LEVEL=info
      - MISP_URL=https://CHANGE_ME_TO_YOUR_MISP_URL
      - MISP_REFERENCE_URL=
      - MISP_KEY=__API_KEY__
      - MISP_SSL_VERIFY=False
      - MISP_DATETIME_ATTRIBUTE=timestamp
      - MISP_CREATE_REPORTS=true
      - MISP_CREATE_INDICATORS=true
      - MISP_CREATE_OBSERVABLES=true
      - MISP_REPORT_TYPE=misp-event
      - MISP_IMPORT_FROM_DATE=2024-01-01
      - MISP_INTERVAL=5
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    tweetfeed)
      cat <<'TEMPLATE'
  connector-tweetfeed:
    image: opencti/connector-tweetfeed:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=TweetFeed
      - CONNECTOR_SCOPE=tweetfeed
      - CONNECTOR_LOG_LEVEL=info
      - TWEETFEED_INTERVAL=5
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
TEMPLATE
      ;;
    *)
      err "Unknown template: $name"
      err "Run with --list to see available templates"
      exit 2
      ;;
  esac
}

###############################################################################
# Main: render and inject
###############################################################################
if [[ -n "$CUSTOM_FILE" ]]; then
  [[ -f "$CUSTOM_FILE" ]] || { err "$CUSTOM_FILE not found"; exit 1; }
  TEMPLATE_CONTENT=$(cat "$CUSTOM_FILE")
  log "Using custom template: $CUSTOM_FILE"
elif [[ -n "$TEMPLATE" ]]; then
  TEMPLATE_CONTENT=$(get_template "$TEMPLATE")
  log "Using built-in template: $TEMPLATE"
else
  err "Specify --template <name>, --file <yaml>, --list, or --remove <name>"
  exit 2
fi

# Pull values needed for substitution
OPENCTI_TOKEN=$(grep ^OPENCTI_ADMIN_TOKEN "$ENV_FILE" | cut -d= -f2)
NEW_UUID=$(uuidgen)

# Check if API key required by template but missing
if echo "$TEMPLATE_CONTENT" | grep -q '__API_KEY__' && [[ -z "$API_KEY" ]]; then
  err "This template requires --api-key <key>"
  exit 2
fi

# Substitute placeholders
RENDERED=$(echo "$TEMPLATE_CONTENT" \
  | sed "s|__OPENCTI_TOKEN__|${OPENCTI_TOKEN}|g" \
  | sed "s|__UUID__|${NEW_UUID}|g" \
  | sed "s|__API_KEY__|${API_KEY}|g")

# Extract service name from rendered template (first line that looks like "  servicename:")
SERVICE_NAME=$(echo "$RENDERED" | grep -m1 -oP '^\s{2}\K[\w\-]+(?=:)')
[[ -n "$SERVICE_NAME" ]] || { err "Could not detect service name in template"; exit 1; }

log "Service name : $SERVICE_NAME"
log "Connector ID : $NEW_UUID"

# Already present? Refuse and tell user.
if grep -qE "^\s{2}${SERVICE_NAME}:\s*$" "$COMPOSE_FILE"; then
  err "Service '$SERVICE_NAME' already exists in $COMPOSE_FILE"
  err "Remove it first:  sudo $0 --remove $SERVICE_NAME"
  exit 1
fi

# Backup compose
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.pre-connector.$(date +%s).bak"

# Append the new service block to the end of the services: section.
# We find the last line that starts with two-space indent (a service) and
# append after that service's block. Simpler approach: append at end of file
# and let docker compose figure it out (compose accepts services anywhere
# under the top-level services: key).
#
# Robust approach: find the line "^services:" and append our block right
# before any top-level key that follows (volumes:, networks:, etc.).

python3 - "$COMPOSE_FILE" <<PY
import sys, re
from pathlib import Path

path = sys.argv[1]
new_block = """${RENDERED}
"""
text = Path(path).read_text()
lines = text.splitlines(keepends=False)

# Find end of services: block (next top-level key OR end of file)
in_services = False
insert_at = len(lines)
for i, line in enumerate(lines):
    if re.match(r'^services:\s*$', line):
        in_services = True
        continue
    if in_services and re.match(r'^[a-zA-Z]', line):
        # Top-level key found (volumes:, networks:, etc.)
        insert_at = i
        break

new_lines = lines[:insert_at] + new_block.splitlines() + [""] + lines[insert_at:]
Path(path).write_text("\n".join(new_lines) + "\n")
print(f"injected at line {insert_at}")
PY

log "Block injected into $COMPOSE_FILE"

# Validate compose syntax
cd "$OPENCTI_DIR"
if ! docker compose config >/dev/null 2>&1; then
  err "docker compose config validation failed!"
  err "Restoring backup..."
  cp "${COMPOSE_FILE}.pre-connector."*.bak "$COMPOSE_FILE"
  exit 1
fi
log "docker compose config validated"

# Start it
log "Starting $SERVICE_NAME"
docker compose up -d "$SERVICE_NAME"

# Tail logs briefly so user sees it working
log "Following logs for 30 seconds (Ctrl+C to stop and exit)"
sleep 2
timeout 30 docker compose logs -f "$SERVICE_NAME" || true

echo
log "Done. Manage with:"
log "  docker compose logs -f $SERVICE_NAME"
log "  docker compose restart $SERVICE_NAME"
log "  sudo $0 --remove $SERVICE_NAME"
