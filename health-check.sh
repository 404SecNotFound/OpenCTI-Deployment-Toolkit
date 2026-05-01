#!/usr/bin/env bash
###############################################################################
# health-check.sh - OpenCTI health monitor with auto-restart
#
# Runs every 15 minutes via cron. Checks:
#   1. OpenCTI platform /health endpoint
#   2. All core services (rabbitmq, redis, elasticsearch, minio) container health
#   3. All connectors are running
#   4. Worker count matches expected
#
# Actions:
#   - If unhealthy: restart the container
#   - If still unhealthy after restart: log and skip (don't loop)
#   - If platform itself unhealthy: restart whole stack
#
# Anti-loop: tracks consecutive restarts in /var/lib/opencti-health/
# A container restarted 3 times in a row gets backed off (no more restarts
# until the state file is manually cleared) so we don't thrash.
#
# Logs to: /var/log/opencti-health.log
# Install cron job:  sudo ./health-check.sh --install-cron
# Test run:          sudo ./health-check.sh
# Reset backoff:     sudo ./health-check.sh --reset
#
###############################################################################

set -uo pipefail

OPENCTI_DIR="${OPENCTI_INSTALL_DIR:-/opt/opencti}"
STATE_DIR="/var/lib/opencti-health"
LOG_FILE="/var/log/opencti-health.log"
ENV_FILE="$OPENCTI_DIR/.env"
COMPOSE_FILE="$OPENCTI_DIR/docker-compose.yml"
MAX_RESTARTS=3
EXPECTED_WORKERS=3   # matches install-opencti.sh 'standard' profile
STALL_MINUTES=240
STALL_GRACE_MINUTES=15  # don't flag a fresh connector that hasn't started yet

###############################################################################
# Logging
###############################################################################
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { echo "$(ts) [INFO]  $*"  | tee -a "$LOG_FILE"; }
warn() { echo "$(ts) [WARN]  $*"  | tee -a "$LOG_FILE"; }
err()  { echo "$(ts) [ERROR] $*"  | tee -a "$LOG_FILE" >&2; }

###############################################################################
# Argument handling
###############################################################################
case "${1:-}" in
  --install-cron)
    SELF=$(readlink -f "$0")
    LINE="*/15 * * * * root $SELF >/dev/null 2>&1"
    if grep -qF "$SELF" /etc/crontab 2>/dev/null; then
      log "Cron entry already present in /etc/crontab"
    else
      echo "$LINE" | sudo tee -a /etc/crontab >/dev/null
      log "Cron entry added: runs every 15 minutes"
    fi
    log "Verify: sudo grep opencti-health /etc/crontab"
    log "Tail logs: sudo tail -f $LOG_FILE"
    exit 0
    ;;
  --reset)
    [[ $EUID -eq 0 ]] || { err "Run as root"; exit 1; }
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    log "Restart counters cleared. Next run will retry all containers."
    exit 0
    ;;
  --status)
    [[ -d "$STATE_DIR" ]] || { echo "No state yet. Run a check first."; exit 0; }
    echo "Container restart counters:"
    for f in "$STATE_DIR"/*.count; do
      [[ -f "$f" ]] || continue
      name=$(basename "$f" .count)
      count=$(cat "$f")
      printf "  %-50s %s\n" "$name" "$count"
    done
    echo
    echo "Connector ingestion state:"
    now=$(date +%s)
    for f in "$STATE_DIR"/*.ingest; do
      [[ -f "$f" ]] || continue
      name=$(basename "$f" .ingest)
      last_work=$(sed -n '1p' "$f")
      last_check=$(sed -n '2p' "$f")
      check_age=$(( (now - last_check) / 60 ))
      if [[ -z "$last_work" ]]; then
        printf "  %-50s no_works  last_checked=%dmin ago\n" "$name" "$check_age"
      else
        work_epoch=$(date -d "$last_work" +%s 2>/dev/null || echo 0)
        work_age=$(( (now - work_epoch) / 60 ))
        printf "  %-50s last_work=%dmin ago  last_checked=%dmin ago\n" "$name" "$work_age" "$check_age"
      fi
    done
    exit 0
    ;;
  --help|-h)
    sed -n '/^# health-check/,/^###############################################################################$/p' "$0" \
      | sed 's/^# \?//'
    exit 0
    ;;
esac

###############################################################################
# Pre-flight
###############################################################################
[[ $EUID -eq 0 ]] || { err "Run as root (sudo)"; exit 1; }
[[ -f "$ENV_FILE" ]] || { err "$ENV_FILE not found"; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { err "$COMPOSE_FILE not found"; exit 1; }

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

cd "$OPENCTI_DIR" || { err "Cannot cd to $OPENCTI_DIR"; exit 1; }

###############################################################################
# Restart counter helpers (anti-loop)
###############################################################################
get_count() {
  local name="$1"
  local f="$STATE_DIR/${name}.count"
  [[ -f "$f" ]] && cat "$f" || echo 0
}

bump_count() {
  local name="$1"
  local f="$STATE_DIR/${name}.count"
  local c
  c=$(get_count "$name")
  echo $((c + 1)) > "$f"
}

clear_count() {
  rm -f "$STATE_DIR/$1.count"
}

restart_with_backoff() {
  local svc="$1" reason="$2"
  local c
  c=$(get_count "$svc")

  if (( c >= MAX_RESTARTS )); then
    err "$svc: backoff active ($c restarts). Skipping. Reason: $reason. Reset with: $(readlink -f "$0") --reset"
    return 1
  fi

  bump_count "$svc"
  warn "$svc: restarting (attempt $((c + 1))/$MAX_RESTARTS). Reason: $reason"
  if docker compose restart "$svc" >/dev/null 2>&1; then
    log "$svc: restart command issued"
  else
    err "$svc: restart command failed"
  fi
  return 0
}

###############################################################################
# Check 1: Platform health endpoint
###############################################################################
check_platform_health() {
  local key port url
  key=$(grep ^OPENCTI_HEALTHCHECK_ACCESS_KEY "$ENV_FILE" | cut -d= -f2)
  port=$(grep ^OPENCTI_PORT "$ENV_FILE" | cut -d= -f2)
  url="http://localhost:${port}/health?health_access_key=${key}"

  if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
    clear_count "opencti"
    log "platform: healthy"
    return 0
  else
    restart_with_backoff "opencti" "health endpoint not responding"
    return 1
  fi
}

###############################################################################
# Check 2: Core service container health
###############################################################################
check_core_services() {
  local svc state
  for svc in elasticsearch rabbitmq redis minio; do
    state=$(docker inspect --format='{{.State.Health.Status}}' "opencti-${svc}-1" 2>/dev/null || echo "missing")

    case "$state" in
      healthy)
        clear_count "$svc"
        log "$svc: healthy"
        ;;
      starting)
        log "$svc: starting (will recheck next run)"
        ;;
      unhealthy)
        restart_with_backoff "$svc" "container unhealthy"
        ;;
      missing)
        warn "$svc: container does not exist - bringing up"
        docker compose up -d "$svc" >/dev/null 2>&1 && log "$svc: brought up"
        ;;
      *)
        warn "$svc: unknown health state '$state'"
        ;;
    esac
  done
}

###############################################################################
# Connector ingestion stall detection
#
# Signal: most recent Work.received_time per connector. A connector pushes a
# Work entry every time it kicks off an ingestion cycle. If no Work has been
# created in STALL_MINUTES, the connector hasn't even attempted to run.
#
# State file format: /var/lib/opencti-health/<svc>.ingest
#   line 1: last_work_timestamp (ISO 8601, what we observed)
#   line 2: last_check_at (epoch seconds)
###############################################################################

# Pull display_name (CONNECTOR_NAME env var) from the running container.
get_display_name() {
  local connector_name="$1"
  docker inspect "opencti-${connector_name}-1" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)[0]
    for env in data['Config']['Env']:
        if env.startswith('CONNECTOR_NAME='):
            print(env.split('=', 1)[1])
            break
except Exception:
    pass
" 2>/dev/null
}

# Returns the most recent Work.received_time for a connector (ISO8601 string),
# or empty string if none / failure.
get_latest_work_time() {
  local display_name="$1"
  local token port
  token=$(grep ^OPENCTI_ADMIN_TOKEN "$ENV_FILE" | cut -d= -f2)
  port=$(grep ^OPENCTI_PORT "$ENV_FILE" | cut -d= -f2)

  local query
  query='{"query":"query { connectors { name works { received_time } } }"}'

  curl -fsS --max-time 10 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$query" \
    "http://localhost:${port}/graphql" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    target = '''$display_name'''
    for c in data.get('data', {}).get('connectors', []) or []:
        if c.get('name') != target:
            continue
        works = c.get('works') or []
        if not works:
            print('')
            sys.exit(0)
        # Find most recent received_time across works
        times = [w.get('received_time') for w in works if w.get('received_time')]
        if times:
            print(max(times))
        else:
            print('')
        sys.exit(0)
    print('')
except Exception:
    print('')
" 2>/dev/null
}

# Convert ISO8601 timestamp (e.g. 2026-04-30T14:52:26.976Z) to epoch seconds.
# Returns 0 on failure.
iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo 0; return; }
  date -d "$iso" +%s 2>/dev/null || echo 0
}

read_ingest_state() {
  local svc="$1"
  local f="$STATE_DIR/${svc}.ingest"
  if [[ ! -f "$f" ]]; then
    echo " 0"
    return
  fi
  local last_work last_check
  last_work=$(sed -n '1p' "$f" 2>/dev/null)
  last_check=$(sed -n '2p' "$f" 2>/dev/null)
  echo "${last_work} ${last_check:-0}"
}

write_ingest_state() {
  local svc="$1" last_work="$2" last_check="$3"
  printf "%s\n%s\n" "$last_work" "$last_check" > "$STATE_DIR/${svc}.ingest"
}

check_connector_ingestion() {
  local svc="$1"
  local now display_name latest_work latest_epoch
  now=$(date +%s)

  display_name=$(get_display_name "$svc")
  if [[ -z "$display_name" ]]; then
    return 0   # can't resolve - skip silently
  fi

  latest_work=$(get_latest_work_time "$display_name")

  # Connector has never produced a Work entry
  if [[ -z "$latest_work" ]]; then
    local prev_work prev_check
    read -r prev_work prev_check < <(read_ingest_state "$svc")

    if (( prev_check == 0 )); then
      # First time tracking this connector
      write_ingest_state "$svc" "" "$now"
      log "$svc [$display_name]: tracking started (no works yet)"
      return 0
    fi

    local age_minutes=$(( (now - prev_check) / 60 ))
    if (( age_minutes >= STALL_GRACE_MINUTES )); then
      warn "$svc [$display_name]: NO WORK ENTRIES in ${age_minutes}min - likely never started"
      restart_with_backoff "$svc" "no work entries after ${age_minutes}min"
      write_ingest_state "$svc" "" "$now"
    else
      log "$svc [$display_name]: warming up (no works yet, ${age_minutes}min in grace)"
    fi
    return 0
  fi

  latest_epoch=$(iso_to_epoch "$latest_work")
  local work_age_minutes=$(( (now - latest_epoch) / 60 ))

  local prev_work prev_check
  read -r prev_work prev_check < <(read_ingest_state "$svc")

  if [[ "$latest_work" != "$prev_work" ]]; then
    # New work since last check - connector is alive
    write_ingest_state "$svc" "$latest_work" "$now"
    log "$svc [$display_name]: active (last work ${work_age_minutes}min ago)"
    return 0
  fi

  # Same work as last time. Check how long since the work was created.
  if (( work_age_minutes >= STALL_MINUTES )); then
    warn "$svc [$display_name]: STALLED (last work ${work_age_minutes}min ago, threshold ${STALL_MINUTES}min)"
    if restart_with_backoff "$svc" "no new work for ${work_age_minutes}min"; then
      write_ingest_state "$svc" "$latest_work" "$now"
    fi
  else
    log "$svc [$display_name]: idle (last work ${work_age_minutes}min ago)"
  fi
}

###############################################################################
# Check 3: Connectors running
###############################################################################
check_connectors() {
  # All services in compose whose name starts with connector-
  local connectors
  mapfile -t connectors < <(docker compose config --services 2>/dev/null | grep '^connector-')

  if [[ ${#connectors[@]} -eq 0 ]]; then
    warn "no connectors detected in compose"
    return
  fi

  local svc state
  for svc in "${connectors[@]}"; do
    state=$(docker inspect --format='{{.State.Status}}' "opencti-${svc}-1" 2>/dev/null || echo "missing")

    case "$state" in
      running)
        clear_count "$svc"
        log "$svc: running"
        # Container is up - now check if it's actually ingesting
        check_connector_ingestion "$svc"
        ;;
      restarting)
        # Container is in restart loop (likely config error). Don't pile on.
        warn "$svc: container is restarting (probable config error - check logs)"
        ;;
      exited|dead)
        restart_with_backoff "$svc" "container $state"
        ;;
      missing)
        warn "$svc: container missing - starting"
        docker compose up -d "$svc" >/dev/null 2>&1 && log "$svc: started"
        ;;
      paused|created)
        warn "$svc: in state '$state' - starting"
        docker compose start "$svc" >/dev/null 2>&1 && log "$svc: started"
        ;;
      *)
        warn "$svc: unexpected state '$state'"
        ;;
    esac
  done
}

###############################################################################
# Check 4: Worker count
###############################################################################
check_workers() {
  local running
  running=$(docker ps --filter "name=opencti-worker" --filter "status=running" -q | wc -l)

  if (( running < EXPECTED_WORKERS )); then
    warn "workers: only $running/$EXPECTED_WORKERS running - rescaling"
    docker compose up -d --scale worker="$EXPECTED_WORKERS" >/dev/null 2>&1
    log "workers: rescaled to $EXPECTED_WORKERS"
  else
    log "workers: $running/$EXPECTED_WORKERS running"
  fi
}

###############################################################################
# Main
###############################################################################
log "=== health check start ==="

check_platform_health
check_core_services
check_connectors
check_workers

log "=== health check end ==="
exit 0
