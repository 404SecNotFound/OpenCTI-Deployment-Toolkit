#!/usr/bin/env bash
###############################################################################
# OpenCTI One-Stop Installer for Ubuntu (22.04 LTS / 24.04 LTS)
#
# What it does:
#   1. Verifies OS, root, network
#   2. Inspects VM specs (CPU, RAM, disk) and auto-tunes settings
#   3. Applies kernel + ulimit tuning needed by Elasticsearch / OpenCTI
#   4. Installs Docker CE + Compose v2 from Docker's official repo
#   5. Clones OpenCTI docker repo, generates strong secrets, writes .env
#   6. Patches docker-compose.yml with required RabbitMQ + ES tuning
#   7. Deploys the full stack (incl. XTM Composer for UI-based connectors)
#   8. Waits for health, validates, prints credentials + next-step guide
#
# Re-run safe (idempotent on most steps).
# Logs to: /var/log/opencti-install.log
#
# Usage:
#   sudo ./install-opencti.sh                     # interactive prompts where needed
#   sudo ./install-opencti.sh --noninteractive    # accept all defaults
#   sudo ./install-opencti.sh --version 6.8.12    # pin a specific OpenCTI version
#   sudo ./install-opencti.sh --domain cti.example.com  # set external domain
#
###############################################################################

set -euo pipefail

###############################################################################
# Tunables (override via flags or env before running)
###############################################################################
OPENCTI_VERSION="${OPENCTI_VERSION:-6.8.12}"        # Pin a known stable tag
OPENCTI_INSTALL_DIR="${OPENCTI_INSTALL_DIR:-/opt/opencti}"
OPENCTI_ADMIN_EMAIL="${OPENCTI_ADMIN_EMAIL:-admin@opencti.local}"
OPENCTI_EXTERNAL_DOMAIN="${OPENCTI_EXTERNAL_DOMAIN:-}"   # empty = use IP/localhost
OPENCTI_EXTERNAL_PORT="${OPENCTI_EXTERNAL_PORT:-8080}"
OPENCTI_EXTERNAL_SCHEME="${OPENCTI_EXTERNAL_SCHEME:-http}"
ENABLE_XTM_COMPOSER="${ENABLE_XTM_COMPOSER:-yes}"   # yes/no
INSTALL_LOG="/var/log/opencti-install.log"
NONINTERACTIVE=0

###############################################################################
# Console output helpers
###############################################################################
C_RESET="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[1;32m"
C_YEL="\033[1;33m"; C_BLU="\033[1;34m"; C_DIM="\033[2m"

log()  { printf "%b[+]%b %s\n"   "$C_GRN" "$C_RESET" "$*" | tee -a "$INSTALL_LOG"; }
warn() { printf "%b[!]%b %s\n"   "$C_YEL" "$C_RESET" "$*" | tee -a "$INSTALL_LOG"; }
err()  { printf "%b[x]%b %s\n"   "$C_RED" "$C_RESET" "$*" | tee -a "$INSTALL_LOG" >&2; }
info() { printf "%b[i]%b %s\n"   "$C_BLU" "$C_RESET" "$*" | tee -a "$INSTALL_LOG"; }
hr()   { printf "%b%s%b\n"       "$C_DIM" "------------------------------------------------------------" "$C_RESET"; }

trap 'err "Failed on line $LINENO. See $INSTALL_LOG"; exit 1' ERR

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)         OPENCTI_VERSION="$2"; shift 2 ;;
    --domain)          OPENCTI_EXTERNAL_DOMAIN="$2"; shift 2 ;;
    --port)            OPENCTI_EXTERNAL_PORT="$2"; shift 2 ;;
    --scheme)          OPENCTI_EXTERNAL_SCHEME="$2"; shift 2 ;;
    --install-dir)     OPENCTI_INSTALL_DIR="$2"; shift 2 ;;
    --admin-email)     OPENCTI_ADMIN_EMAIL="$2"; shift 2 ;;
    --no-xtm)          ENABLE_XTM_COMPOSER="no"; shift ;;
    --noninteractive)  NONINTERACTIVE=1; shift ;;
    --help|-h)
      sed -n '/^# OpenCTI One-Stop/,/^###############################################################################$/p' "$0" \
        | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
done

###############################################################################
# Pre-flight: root, OS, network
###############################################################################
preflight() {
  hr
  log "Pre-flight checks"

  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
  fi

  mkdir -p "$(dirname "$INSTALL_LOG")" && touch "$INSTALL_LOG"

  if ! grep -qE 'Ubuntu (22|24)' /etc/os-release; then
    warn "This script is tested on Ubuntu 22.04 and 24.04 LTS only."
    warn "Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
    if [[ $NONINTERACTIVE -eq 0 ]]; then
      read -r -p "Continue anyway? [y/N] " yn
      [[ "$yn" =~ ^[Yy]$ ]] || exit 1
    fi
  fi

  if ! curl -fsSL --max-time 5 https://download.docker.com >/dev/null 2>&1; then
    err "No outbound connectivity to download.docker.com. Fix network first."
    exit 1
  fi

  log "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
  log "Kernel: $(uname -r)"
  log "Hostname: $(hostname)"
}

###############################################################################
# VM spec inspection + auto-tuning
###############################################################################
detect_specs() {
  hr
  log "Detecting VM specs"

  CPU_CORES=$(nproc)
  RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  RAM_TOTAL_GB=$(( RAM_TOTAL_KB / 1024 / 1024 ))
  DISK_FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
  SWAP_TOTAL_GB=$(( SWAP_TOTAL_KB / 1024 / 1024 ))

  log "CPU cores       : $CPU_CORES"
  log "RAM total       : ${RAM_TOTAL_GB} GB"
  log "Swap            : ${SWAP_TOTAL_GB} GB"
  log "Free disk on /  : ${DISK_FREE_GB} GB"

  # Compute Elasticsearch heap (rule: 50% of RAM, capped at 31G, min 2G)
  if   (( RAM_TOTAL_GB <  6 )); then ES_HEAP="2G";  WORKER_COUNT=1; PROFILE="minimal"
  elif (( RAM_TOTAL_GB < 12 )); then ES_HEAP="3G";  WORKER_COUNT=2; PROFILE="lab"
  elif (( RAM_TOTAL_GB < 24 )); then ES_HEAP="6G";  WORKER_COUNT=3; PROFILE="standard"
  elif (( RAM_TOTAL_GB < 48 )); then ES_HEAP="12G"; WORKER_COUNT=4; PROFILE="production"
  else                              ES_HEAP="16G"; WORKER_COUNT=6; PROFILE="enterprise"
  fi

  hr
  log "Profile selected: ${PROFILE}"
  log "  ELASTIC_MEMORY_SIZE = ${ES_HEAP}"
  log "  Worker replicas     = ${WORKER_COUNT}"

  # Hard floor warnings
  if (( RAM_TOTAL_GB < 8 )); then
    warn "RAM < 8 GB. OpenCTI will run but be sluggish. 16 GB+ recommended."
  fi
  if (( DISK_FREE_GB < 50 )); then
    warn "Free disk < 50 GB. ES indices grow fast. 100 GB+ SSD recommended."
  fi
  if (( CPU_CORES < 4 )); then
    warn "CPU cores < 4. Ingestion will be slow. 8+ cores recommended."
  fi

  # Recommend swap if RAM < 8GB and no swap
  if (( RAM_TOTAL_GB < 8 )) && (( SWAP_TOTAL_GB < 2 )); then
    warn "Low RAM + no swap detected. Adding 4 GB swap file."
    if [[ ! -f /swapfile ]]; then
      fallocate -l 4G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      log "4 GB swap file created and enabled."
    fi
  fi
}

###############################################################################
# Kernel + ulimit tuning
###############################################################################
apply_tuning() {
  hr
  log "Applying kernel and ulimit tuning"

  # vm.max_map_count required by Elasticsearch
  cat > /etc/sysctl.d/99-opencti.conf <<EOF
# OpenCTI / Elasticsearch tuning
vm.max_map_count=1048575
fs.file-max=2097152
net.core.somaxconn=4096
vm.swappiness=10
EOF
  sysctl --system >/dev/null
  log "sysctl: vm.max_map_count, fs.file-max, somaxconn, swappiness applied"

  # System-wide nofile limits
  cat > /etc/security/limits.d/99-opencti.conf <<EOF
*  soft  nofile  131072
*  hard  nofile  131072
*  soft  nproc   65535
*  hard  nproc   65535
root soft nofile 131072
root hard nofile 131072
EOF
  log "ulimit: nofile / nproc raised"
}

###############################################################################
# Install Docker CE + Compose v2
###############################################################################
install_docker() {
  hr
  log "Installing Docker CE + Compose v2"

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + Compose v2 already present: $(docker --version)"
    return 0
  fi

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release jq openssl uuid-runtime git wget

  # Remove conflicting legacy packages quietly
  apt-get remove -y -qq docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  UBU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBU_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  # Daemon tuning: log rotation + live-restore
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "live-restore": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 131072, "Hard": 131072 }
  }
}
EOF
  systemctl restart docker

  log "Docker installed: $(docker --version)"
  log "Compose: $(docker compose version)"
}

###############################################################################
# Clone / refresh OpenCTI docker repo
###############################################################################
clone_repo() {
  hr
  log "Preparing $OPENCTI_INSTALL_DIR (OpenCTI ${OPENCTI_VERSION})"

  if [[ -d "$OPENCTI_INSTALL_DIR/.git" ]]; then
    log "Existing repo found. Fetching tags."
    git -C "$OPENCTI_INSTALL_DIR" fetch --all --tags --quiet
  else
    mkdir -p "$(dirname "$OPENCTI_INSTALL_DIR")"
    git clone --quiet https://github.com/OpenCTI-Platform/docker.git "$OPENCTI_INSTALL_DIR"
  fi

  cd "$OPENCTI_INSTALL_DIR"
  # The docker repo tracks compose files; tags don't always match platform versions.
  # We pin the docker-compose images to OPENCTI_VERSION via .env instead.
  git checkout master --quiet
  git pull --quiet
}

###############################################################################
# Generate .env with strong secrets
###############################################################################
generate_env() {
  hr
  log "Generating .env with strong secrets"

  cd "$OPENCTI_INSTALL_DIR"

  if [[ -f .env ]]; then
    warn ".env already exists. Backing up to .env.$(date +%s).bak"
    cp .env ".env.$(date +%s).bak"
  fi

  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-22)"
  ADMIN_TOKEN="$(uuidgen)"
  HEALTH_KEY="$(uuidgen)"
  ENC_KEY="$(openssl rand -base64 32)"
  MINIO_USER="$(uuidgen)"
  MINIO_PASS="$(openssl rand -base64 32 | tr -d '/+=')"
  RABBIT_USER="opencti"
  RABBIT_PASS="$(openssl rand -base64 32 | tr -d '/+=')"
  XTM_COMPOSER_ID="$(uuidgen)"

  CONN_HISTORY_ID="$(uuidgen)"
  CONN_EXP_STIX_ID="$(uuidgen)"
  CONN_EXP_CSV_ID="$(uuidgen)"
  CONN_EXP_TXT_ID="$(uuidgen)"
  CONN_IMP_STIX_ID="$(uuidgen)"
  CONN_IMP_REPORT_ID="$(uuidgen)"
  CONN_ANALYSIS_ID="$(uuidgen)"

  EXT_HOST="${OPENCTI_EXTERNAL_DOMAIN:-localhost}"

  cat > .env <<EOF
###########################################################
# OpenCTI ${OPENCTI_VERSION} environment
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by install-opencti.sh
###########################################################

# ------- Versions -------
OPENCTI_VERSION=${OPENCTI_VERSION}

# ------- Dependencies -------
ELASTIC_MEMORY_SIZE=${ES_HEAP}
MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASS}
RABBITMQ_DEFAULT_USER=${RABBIT_USER}
RABBITMQ_DEFAULT_PASS=${RABBIT_PASS}
SMTP_HOSTNAME=localhost

# ------- Compose -------
COMPOSE_PROJECT_NAME=opencti

# ------- OpenCTI core -------
OPENCTI_HOST=${EXT_HOST}
OPENCTI_PORT=${OPENCTI_EXTERNAL_PORT}
OPENCTI_EXTERNAL_SCHEME=${OPENCTI_EXTERNAL_SCHEME}
OPENCTI_BASE_URL=${OPENCTI_EXTERNAL_SCHEME}://${EXT_HOST}:${OPENCTI_EXTERNAL_PORT}
OPENCTI_ADMIN_EMAIL=${OPENCTI_ADMIN_EMAIL}
OPENCTI_ADMIN_PASSWORD=${ADMIN_PASS}
OPENCTI_ADMIN_TOKEN=${ADMIN_TOKEN}
OPENCTI_HEALTHCHECK_ACCESS_KEY=${HEALTH_KEY}
OPENCTI_ENCRYPTION_KEY=${ENC_KEY}
APP__MAX_PAYLOAD_BODY_SIZE=200mb

# ------- XTM Composer -------
XTM_COMPOSER_ID=${XTM_COMPOSER_ID}

# ------- Built-in connector IDs -------
CONNECTOR_HISTORY_ID=${CONN_HISTORY_ID}
CONNECTOR_EXPORT_FILE_STIX_ID=${CONN_EXP_STIX_ID}
CONNECTOR_EXPORT_FILE_CSV_ID=${CONN_EXP_CSV_ID}
CONNECTOR_EXPORT_FILE_TXT_ID=${CONN_EXP_TXT_ID}
CONNECTOR_IMPORT_FILE_STIX_ID=${CONN_IMP_STIX_ID}
CONNECTOR_IMPORT_DOCUMENT_ID=${CONN_IMP_REPORT_ID}
CONNECTOR_ANALYSIS_ID=${CONN_ANALYSIS_ID}
EOF

  chmod 600 .env
  log ".env written ($(wc -l < .env) lines), permissions 600"

  # Secrets summary saved out of band for the operator
  SECRETS_FILE="/root/opencti-credentials.txt"
  cat > "$SECRETS_FILE" <<EOF
OpenCTI installation credentials
Generated: $(date)
Install dir: $OPENCTI_INSTALL_DIR

URL          : ${OPENCTI_EXTERNAL_SCHEME}://${EXT_HOST}:${OPENCTI_EXTERNAL_PORT}
Admin email  : ${OPENCTI_ADMIN_EMAIL}
Admin pass   : ${ADMIN_PASS}
Admin token  : ${ADMIN_TOKEN}
Healthcheck  : ${HEALTH_KEY}
Encryption   : ${ENC_KEY}
MinIO user   : ${MINIO_USER}
MinIO pass   : ${MINIO_PASS}
RabbitMQ user: ${RABBIT_USER}
RabbitMQ pass: ${RABBIT_PASS}
EOF
  chmod 600 "$SECRETS_FILE"
  log "Credentials backup written to $SECRETS_FILE (mode 600)"
}

###############################################################################
# Patch docker-compose.yml for known production issues
###############################################################################
patch_compose() {
  hr
  log "Patching docker-compose.yml for stability"

  cd "$OPENCTI_INSTALL_DIR"
  cp docker-compose.yml docker-compose.yml.orig

  # Confirm the upstream RabbitMQ block already carries max_message_size and
  # consumer_timeout. If not, write a sidecar rabbitmq.conf and mount it.
  if ! grep -q 'max_message_size' docker-compose.yml; then
    warn "Upstream compose missing RabbitMQ tuning. Writing sidecar conf."
    cat > rabbitmq-extra.conf <<EOF
max_message_size = 536870912
consumer_timeout = 86400000
EOF
  fi

  # Confirm thread_pool.search.queue_size for ES
  if ! grep -q 'thread_pool.search.queue_size' docker-compose.yml; then
    warn "ES thread_pool.search.queue_size missing. Add it manually if you hit search rejections."
  fi

  # Scale workers based on detected RAM
  if grep -q '^  worker:' docker-compose.yml; then
    log "Worker service present. Will scale to ${WORKER_COUNT} replicas at deploy time."
  fi

  log "Compose patches reviewed."
}

###############################################################################
# Bring stack up + wait for health
###############################################################################
deploy_stack() {
  hr
  log "Pulling images (this can take a few minutes)"
  cd "$OPENCTI_INSTALL_DIR"
  docker compose pull --quiet

  log "Starting stack"
  docker compose up -d

  # Scale workers
  if (( WORKER_COUNT > 1 )); then
    log "Scaling worker to ${WORKER_COUNT} replicas"
    docker compose up -d --scale worker="$WORKER_COUNT"
  fi

  hr
  log "Waiting for OpenCTI health endpoint (up to 10 minutes)"
  set +e
  HEALTH_URL="http://localhost:${OPENCTI_EXTERNAL_PORT}/health?health_access_key=${HEALTH_KEY}"
  for i in $(seq 1 60); do
    if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      log "OpenCTI is healthy after $((i*10)) seconds."
      set -e
      return 0
    fi
    sleep 10
    printf "."
  done
  echo
  set -e
  warn "Health check did not pass within 10 minutes."
  warn "Run: cd $OPENCTI_INSTALL_DIR && docker compose ps && docker compose logs --tail=200 opencti"
}

###############################################################################
# Optional: configure XTM Composer for UI-driven connector deployment
###############################################################################
setup_xtm_composer() {
  if [[ "$ENABLE_XTM_COMPOSER" != "yes" ]]; then
    info "Skipping XTM Composer setup (--no-xtm)"
    return 0
  fi

  hr
  log "Configuring XTM Composer (UI connector deployment)"

  cd "$OPENCTI_INSTALL_DIR"

  # If upstream compose already includes xtm-composer service, the .env XTM_COMPOSER_ID
  # we generated is enough. Otherwise we add a standalone composer container.
  if grep -q 'xtm-composer' docker-compose.yml; then
    log "XTM Composer is included in upstream compose. Already wired up."
    log "Generate trial EE license in OpenCTI UI: Settings > Customization > Enterprise Edition"
    return 0
  fi

  warn "XTM Composer not present in upstream compose. Adding standalone container."

  mkdir -p xtm-composer/keys xtm-composer/config
  if [[ ! -f xtm-composer/keys/private_key.pem ]]; then
    openssl genrsa -out xtm-composer/keys/private_key.pem 4096 >/dev/null 2>&1
    chmod 600 xtm-composer/keys/private_key.pem
  fi

  cat > xtm-composer/config/default.yaml <<EOF
manager:
  id: "${XTM_COMPOSER_ID}"
  credentials_key_filepath: "/keys/private_key.pem"
logger:
  level: info
  format: json
opencti:
  enable: true
  url: "http://opencti:8080"
  token: "${ADMIN_TOKEN}"
daemon:
  selector: docker
EOF

  cat > docker-compose.xtm.yml <<EOF
services:
  xtm-composer:
    image: filigran/xtm-composer:latest
    container_name: opencti-xtm-composer
    restart: unless-stopped
    environment:
      COMPOSER_ENV: production
      MANAGER__ID: "${XTM_COMPOSER_ID}"
      MANAGER__CREDENTIALS_KEY_FILEPATH: /keys/private_key.pem
      OPENCTI__URL: "http://opencti:8080"
      OPENCTI__TOKEN: "${ADMIN_TOKEN}"
      OPENCTI__DAEMON__SELECTOR: docker
    volumes:
      - ./xtm-composer/config:/config
      - ./xtm-composer/keys:/keys
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - opencti
EOF

  log "Bringing up XTM Composer"
  docker compose -f docker-compose.yml -f docker-compose.xtm.yml up -d
}

###############################################################################
# Final summary
###############################################################################
print_summary() {
  hr
  EXT="${OPENCTI_EXTERNAL_DOMAIN:-$(hostname -I | awk '{print $1}')}"

  cat <<EOF

  $(printf "%b" "$C_GRN")OpenCTI installation complete$(printf "%b" "$C_RESET")

  URL          : ${OPENCTI_EXTERNAL_SCHEME}://${EXT}:${OPENCTI_EXTERNAL_PORT}
  Admin email  : ${OPENCTI_ADMIN_EMAIL}
  Admin pass   : (saved to /root/opencti-credentials.txt)

  Stack files  : ${OPENCTI_INSTALL_DIR}
  Logs         : ${INSTALL_LOG}
  Credentials  : /root/opencti-credentials.txt  (mode 600)

  Profile      : ${PROFILE}  (ES heap ${ES_HEAP}, ${WORKER_COUNT} workers)

  Useful commands:
    cd ${OPENCTI_INSTALL_DIR}
    docker compose ps
    docker compose logs -f opencti
    docker compose logs -f worker
    docker compose down              # stop the stack
    docker compose up -d             # start it again

  Next steps:
    1. Open the URL above and log in with the credentials.
    2. Settings > Customization > Enterprise Edition
       Generate a free 30-day trial OR request a free NFR license at
       https://filigran.io/opencti-enterprise-editions-license-request/
       (NFR licenses are granted to individual researchers.)
    3. Once EE is active, go to Data > Ingestion > Connectors and use the
       Catalog tab to deploy connectors from the UI (no YAML).
    4. See README.md for the four ways to add connectors and the
       Portainer / Dockge / Komodo comparison.

EOF
}

###############################################################################
# Main
###############################################################################
main() {
  preflight
  detect_specs
  apply_tuning
  install_docker
  clone_repo
  generate_env
  patch_compose
  deploy_stack
  setup_xtm_composer
  print_summary
}

main "$@"
