#!/usr/bin/env bash
###############################################################################
# manage.sh  Day-2 operations helper for the OpenCTI stack
#
# Subcommands:
#   status                    Container state + health
#   logs <service> [tail]     Tail logs for one service
#   start | stop | restart    Lifecycle control
#   ps                        docker compose ps
#   backup                    Stop, tar volumes + .env + compose, restart
#   upgrade <version>         Update OPENCTI_VERSION in .env and roll
#   reset-password            Generate and apply a new admin password
#   add-connector             Print template + UUID for a manual compose connector
#   nuke                      Tear down stack and delete all data (with confirm)
#
# Run from anywhere; the script resolves the stack dir on its own.
###############################################################################

set -euo pipefail
STACK_DIR="${OPENCTI_INSTALL_DIR:-/opt/opencti}"

C_RESET="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[1;32m"; C_YEL="\033[1;33m"
log()  { printf "%b[+]%b %s\n" "$C_GRN" "$C_RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YEL" "$C_RESET" "$*"; }
err()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

need_dir() {
  [[ -d "$STACK_DIR" ]] || { err "Stack dir $STACK_DIR not found"; exit 1; }
  cd "$STACK_DIR"
}

cmd_status() {
  need_dir
  docker compose ps
  echo
  HEALTH_KEY=$(grep ^OPENCTI_HEALTHCHECK_ACCESS_KEY .env | cut -d= -f2)
  PORT=$(grep ^OPENCTI_PORT .env | cut -d= -f2)
  if curl -fsS --max-time 5 "http://localhost:${PORT}/health?health_access_key=${HEALTH_KEY}" >/dev/null 2>&1; then
    log "OpenCTI health: OK"
  else
    warn "OpenCTI health: not responding"
  fi
}

cmd_logs() {
  need_dir
  local svc="${1:-opencti}"
  local tail="${2:-200}"
  docker compose logs --tail="$tail" -f "$svc"
}

cmd_start()   { need_dir; docker compose up -d; log "Stack started"; }
cmd_stop()    { need_dir; docker compose down;  log "Stack stopped"; }
cmd_restart() { need_dir; docker compose down; docker compose up -d; log "Stack restarted"; }
cmd_ps()      { need_dir; docker compose ps; }

cmd_backup() {
  need_dir
  local stamp; stamp=$(date +%F-%H%M)
  local out="/var/backups/opencti-config-${stamp}.tgz"
  mkdir -p /var/backups

  log "Stopping stack for consistent volume snapshot"
  docker compose down

  # Build the file list of things that actually exist
  local items=()
  for f in .env docker-compose.yml docker-compose.xtm.yml xtm-composer; do
    [[ -e "$f" ]] && items+=("$f")
  done

  log "Creating config archive: $out"
  tar czf "$out" --warning=no-file-changed "${items[@]}"

  for v in $(docker volume ls -q | grep ^opencti_); do
    log "Adding volume $v"
    docker run --rm -v "$v":/src:ro -v /var/backups:/dst alpine \
      tar czf "/dst/${v}-${stamp}.tgz" -C /src .
  done

  log "Restarting stack"
  docker compose up -d
  log "Backups written to /var/backups/ with stamp ${stamp}"
  find /var/backups -maxdepth 1 -name "*${stamp}*" -printf "  %p (%s bytes)\n" || true
}

cmd_upgrade() {
  need_dir
  local target="${1:-}"
  if [[ -z "$target" ]]; then err "Usage: manage.sh upgrade <version>"; exit 2; fi

  local current; current=$(grep ^OPENCTI_VERSION .env | cut -d= -f2)
  log "Current version: $current  ->  target: $target"
  read -r -p "Read release notes between $current and $target before continuing. Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { warn "Aborted"; exit 0; }

  sed -i "s|^OPENCTI_VERSION=.*|OPENCTI_VERSION=${target}|" .env
  docker compose pull
  docker compose up -d
  log "Upgrade triggered. Tail logs with: $0 logs opencti"
}

cmd_reset_password() {
  need_dir
  local new; new=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-22)
  sed -i "s|^OPENCTI_ADMIN_PASSWORD=.*|OPENCTI_ADMIN_PASSWORD=${new}|" .env
  docker compose up -d --force-recreate opencti
  log "New admin password: ${new}"
  log "Saved in .env. Update your password manager."
}

cmd_add_connector() {
  local id; id=$(uuidgen)
  cat <<EOF

  Drop this block into the services: section of /opt/opencti/docker-compose.yml,
  edit image and connector-specific env vars, then run:
    docker compose up -d

---8<------------------------------------------------------------
  connector-CHANGE_ME:
    image: opencti/connector-CHANGE_ME:\${OPENCTI_VERSION}
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=\${OPENCTI_ADMIN_TOKEN}
      - CONNECTOR_ID=${id}
      - CONNECTOR_TYPE=EXTERNAL_IMPORT          # or INTERNAL_ENRICHMENT, STREAM, etc.
      - CONNECTOR_NAME=CHANGE_ME
      - CONNECTOR_SCOPE=CHANGE_ME
      - CONNECTOR_LOG_LEVEL=info
    restart: always
---8<------------------------------------------------------------

  Fresh CONNECTOR_ID for this connector: ${id}
  Reusing a UUID across connectors causes restart loops. Always generate a new one.

EOF
}

cmd_nuke() {
  need_dir
  warn "This will DELETE all OpenCTI data including volumes."
  read -r -p "Type DELETE to confirm: " c
  if [[ "$c" != "DELETE" ]]; then warn "Aborted"; exit 0; fi
  docker compose down -v
  log "Stack and volumes removed. $STACK_DIR is preserved (config + logs)."
}

usage() {
  sed -n '2,20p' "$0"
}

case "${1:-help}" in
  status)         shift; cmd_status "$@" ;;
  logs)           shift; cmd_logs "$@" ;;
  start)          shift; cmd_start "$@" ;;
  stop)           shift; cmd_stop "$@" ;;
  restart)        shift; cmd_restart "$@" ;;
  ps)             shift; cmd_ps "$@" ;;
  backup)         shift; cmd_backup "$@" ;;
  upgrade)        shift; cmd_upgrade "$@" ;;
  reset-password) shift; cmd_reset_password "$@" ;;
  add-connector)  shift; cmd_add_connector "$@" ;;
  nuke)           shift; cmd_nuke "$@" ;;
  help|-h|--help) usage ;;
  *) err "Unknown subcommand: $1"; usage; exit 2 ;;
esac
