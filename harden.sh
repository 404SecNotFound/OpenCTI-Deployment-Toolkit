#!/usr/bin/env bash
###############################################################################
# OpenCTI Production Hardening Script
#
# Run this AFTER install-opencti.sh has succeeded and the stack is healthy.
#
# What it does:
#   1. Installs Caddy (auto HTTPS reverse proxy)
#   2. Binds internal services (ES, Redis, RabbitMQ, MinIO) to localhost only
#   3. Configures UFW with the Docker bypass fix (DOCKER-USER chain)
#   4. Sets up SSH hardening basics
#   5. Enables unattended security upgrades
#   6. Optional: installs fail2ban for SSH brute force protection
#   7. Updates OPENCTI_BASE_URL so links/SSO work behind the proxy
#   8. Restarts stack with new bindings
#
# Re-run safe.
#
# Usage:
#   sudo ./harden.sh                                # interactive
#   sudo ./harden.sh --hostname cti.example.com --email me@example.com
#   sudo ./harden.sh --hostname cti.lan --local-ca  # internal cert, no Let's Encrypt
#   sudo ./harden.sh --no-fail2ban
#
###############################################################################

set -euo pipefail

###############################################################################
# Tunables
###############################################################################
OPENCTI_INSTALL_DIR="${OPENCTI_INSTALL_DIR:-/opt/opencti}"
HARDEN_LOG="/var/log/opencti-harden.log"
HOSTNAME_FQDN=""
ACME_EMAIL=""
USE_LOCAL_CA=0
INSTALL_FAIL2BAN=1
ALLOWED_SSH_FROM=""   # CIDR; empty = anywhere
NONINTERACTIVE=0

###############################################################################
# Console helpers
###############################################################################
C_RESET="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[1;32m"
C_YEL="\033[1;33m"; C_BLU="\033[1;34m"; C_DIM="\033[2m"

log()  { printf "%b[+]%b %s\n" "$C_GRN" "$C_RESET" "$*" | tee -a "$HARDEN_LOG"; }
warn() { printf "%b[!]%b %s\n" "$C_YEL" "$C_RESET" "$*" | tee -a "$HARDEN_LOG"; }
err()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" | tee -a "$HARDEN_LOG" >&2; }
info() { printf "%b[i]%b %s\n" "$C_BLU" "$C_RESET" "$*" | tee -a "$HARDEN_LOG"; }
hr()   { printf "%b%s%b\n"     "$C_DIM" "------------------------------------------------------------" "$C_RESET"; }

trap 'err "Failed on line $LINENO. See $HARDEN_LOG"; exit 1' ERR

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)        HOSTNAME_FQDN="$2"; shift 2 ;;
    --email)           ACME_EMAIL="$2"; shift 2 ;;
    --local-ca)        USE_LOCAL_CA=1; shift ;;
    --no-fail2ban)     INSTALL_FAIL2BAN=0; shift ;;
    --ssh-from)        ALLOWED_SSH_FROM="$2"; shift 2 ;;
    --install-dir)     OPENCTI_INSTALL_DIR="$2"; shift 2 ;;
    --noninteractive)  NONINTERACTIVE=1; shift ;;
    --help|-h)
      sed -n '/^# OpenCTI Production/,/^###############################################################################$/p' "$0" \
        | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 2 ;;
  esac
done

###############################################################################
# Pre-flight
###############################################################################
preflight() {
  hr
  log "Pre-flight checks"

  [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
  mkdir -p "$(dirname "$HARDEN_LOG")" && touch "$HARDEN_LOG"

  if [[ ! -d "$OPENCTI_INSTALL_DIR" ]]; then
    err "$OPENCTI_INSTALL_DIR not found. Run install-opencti.sh first."
    exit 1
  fi
  if [[ ! -f "$OPENCTI_INSTALL_DIR/.env" ]]; then
    err "$OPENCTI_INSTALL_DIR/.env not found. Run install-opencti.sh first."
    exit 1
  fi

  cd "$OPENCTI_INSTALL_DIR"
  if ! docker compose ps --status running 2>/dev/null | grep -q opencti; then
    warn "OpenCTI containers do not look running. Start them first: docker compose up -d"
  fi

  # Prompt for hostname if not provided
  if [[ -z "$HOSTNAME_FQDN" ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      err "Hostname required. Use --hostname <fqdn>"
      exit 2
    fi
    echo
    info "Enter the hostname users will use to reach OpenCTI."
    info "  Public domain (e.g. cti.example.com) = real Let's Encrypt cert"
    info "  Internal name  (e.g. cti.lab.local)  = Caddy local CA self-signed cert"
    read -r -p "Hostname: " HOSTNAME_FQDN
    [[ -n "$HOSTNAME_FQDN" ]] || { err "Hostname is required"; exit 2; }
  fi

  # Decide cert mode if not forced
  if [[ $USE_LOCAL_CA -eq 0 ]]; then
    case "$HOSTNAME_FQDN" in
      *.local|*.lan|*.localhost|*.internal|*.test|localhost)
        warn "Hostname '$HOSTNAME_FQDN' looks internal. Using Caddy local CA."
        USE_LOCAL_CA=1
        ;;
    esac
  fi

  # Email needed for public ACME
  if [[ $USE_LOCAL_CA -eq 0 && -z "$ACME_EMAIL" ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      err "ACME email required for public certs. Use --email <addr>"
      exit 2
    fi
    read -r -p "Email for Let's Encrypt notifications: " ACME_EMAIL
  fi

  log "Hostname     : $HOSTNAME_FQDN"
  if [[ $USE_LOCAL_CA -eq 1 ]]; then
    log "Cert mode    : Caddy local CA (self-signed, internal use)"
  else
    log "Cert mode    : Let's Encrypt via Caddy"
    log "ACME email   : $ACME_EMAIL"
  fi
}

###############################################################################
# Bind internal services to localhost only
###############################################################################
patch_compose_bindings() {
  hr
  log "Binding internal services to 127.0.0.1 (no LAN exposure)"

  cd "$OPENCTI_INSTALL_DIR"
  cp docker-compose.yml "docker-compose.yml.pre-harden.$(date +%s).bak"

  # The upstream compose typically publishes:
  #   - opencti:8080  (we want Caddy to reach this; bind to 127.0.0.1)
  #   - minio:9000    (admin only; bind to 127.0.0.1)
  #   - rabbitmq mgmt 15672 (admin only; bind to 127.0.0.1)
  # ES and Redis are usually internal-only already, but we make sure.
  #
  # We rewrite "ports: - PORT:PORT" entries to "127.0.0.1:PORT:PORT"
  # only for the services we want to lock down.

  python3 - <<'PY'
import re, sys
from pathlib import Path

p = Path("docker-compose.yml")
text = p.read_text()

# Services whose published ports should bind to localhost only.
# Anything else stays as-is.
LOCK_SERVICES = {"opencti", "minio", "rabbitmq", "redis", "elasticsearch"}

lines = text.splitlines()
out = []
current_service = None
in_services = False
service_indent = None

for i, line in enumerate(lines):
    stripped = line.strip()

    # Track top-level "services:" block
    if re.match(r"^services:\s*$", line):
        in_services = True
        out.append(line)
        continue

    # Detect a service definition (2-space indent under services:)
    m = re.match(r"^(\s{2})([\w\-]+):\s*$", line)
    if in_services and m:
        current_service = m.group(2)
        service_indent = m.group(1)
        out.append(line)
        continue

    # Within a locked service, rewrite "    - 8080:8080" -> "    - 127.0.0.1:8080:8080"
    if current_service in LOCK_SERVICES:
        # Only rewrite "- HOST:CONTAINER" or "- "HOST:CONTAINER""
        m2 = re.match(r'^(\s+-\s+)"?(\d+):(\d+)"?\s*$', line)
        if m2:
            prefix, host, container = m2.group(1), m2.group(2), m2.group(3)
            new_line = f'{prefix}"127.0.0.1:{host}:{container}"'
            out.append(new_line)
            continue
        # Skip "- HOST_IP:HOST:CONTAINER" if already bound
        m3 = re.match(r'^(\s+-\s+)"?([\d\.]+):(\d+):(\d+)"?\s*$', line)
        if m3:
            ip = m3.group(2)
            if ip != "127.0.0.1":
                prefix, _, host, container = m3.group(1), m3.group(2), m3.group(3), m3.group(4)
                new_line = f'{prefix}"127.0.0.1:{host}:{container}"'
                out.append(new_line)
                continue

    out.append(line)

p.write_text("\n".join(out) + "\n")
print("rewrote bindings")
PY

  log "Service port bindings restricted to 127.0.0.1"
  log "Backup: docker-compose.yml.pre-harden.*.bak"
}

###############################################################################
# Update OPENCTI_BASE_URL so the platform knows its public hostname
###############################################################################
update_env_for_proxy() {
  hr
  log "Updating .env for reverse-proxy operation"

  cd "$OPENCTI_INSTALL_DIR"
  cp .env ".env.pre-harden.$(date +%s).bak"
  chmod 600 ".env.pre-harden."*.bak 2>/dev/null || true

  # Behind Caddy users hit https://hostname (port 443 implicit)
  sed -i \
    -e "s|^OPENCTI_HOST=.*|OPENCTI_HOST=${HOSTNAME_FQDN}|" \
    -e "s|^OPENCTI_PORT=.*|OPENCTI_PORT=443|" \
    -e "s|^OPENCTI_EXTERNAL_SCHEME=.*|OPENCTI_EXTERNAL_SCHEME=https|" \
    -e "s|^OPENCTI_BASE_URL=.*|OPENCTI_BASE_URL=https://${HOSTNAME_FQDN}|" \
    .env

  log "OPENCTI_BASE_URL set to https://${HOSTNAME_FQDN}"
}

###############################################################################
# Install Caddy from official repo
###############################################################################
install_caddy() {
  hr
  log "Installing Caddy"

  if command -v caddy >/dev/null 2>&1; then
    log "Caddy already installed: $(caddy version)"
    return 0
  fi

  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy

  log "Caddy installed: $(caddy version)"
}

###############################################################################
# Write Caddyfile
###############################################################################
configure_caddy() {
  hr
  log "Writing Caddyfile"

  if [[ $USE_LOCAL_CA -eq 1 ]]; then
    cat > /etc/caddy/Caddyfile <<EOF
# OpenCTI reverse proxy (internal hostname, Caddy local CA)
# Trust the root CA at: /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt

{
    # Issue self-signed certs from Caddy's local CA for internal hostnames
    local_certs
}

${HOSTNAME_FQDN} {
    encode gzip zstd

    # Security headers (sane defaults)
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "SAMEORIGIN"
        Referrer-Policy           "strict-origin-when-cross-origin"
        -Server
    }

    # Health check passthrough (no auth)
    @health path /health*
    handle @health {
        reverse_proxy 127.0.0.1:8080
    }

    # Main app + GraphQL + websockets
    reverse_proxy 127.0.0.1:8080 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
        flush_interval -1
    }

    # Access log
    log {
        output file /var/log/caddy/opencti-access.log {
            roll_size 100mb
            roll_keep 10
        }
        format json
    }
}

# Optional: redirect bare hostname http -> https (Caddy does this by default)
EOF
  else
    cat > /etc/caddy/Caddyfile <<EOF
# OpenCTI reverse proxy (public hostname, Let's Encrypt)

{
    email ${ACME_EMAIL}
}

${HOSTNAME_FQDN} {
    encode gzip zstd

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "SAMEORIGIN"
        Referrer-Policy           "strict-origin-when-cross-origin"
        -Server
    }

    @health path /health*
    handle @health {
        reverse_proxy 127.0.0.1:8080
    }

    reverse_proxy 127.0.0.1:8080 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
        flush_interval -1
    }

    log {
        output file /var/log/caddy/opencti-access.log {
            roll_size 100mb
            roll_keep 10
        }
        format json
    }
}
EOF
  fi

  mkdir -p /var/log/caddy
  chown caddy:caddy /var/log/caddy 2>/dev/null || true

  caddy validate --config /etc/caddy/Caddyfile >/dev/null
  systemctl enable --now caddy
  systemctl restart caddy
  log "Caddy reloaded with new Caddyfile"

  if [[ $USE_LOCAL_CA -eq 1 ]]; then
    info "To trust Caddy's local CA on client machines, copy this file to them:"
    info "  /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    info "Or run on the server:  caddy trust"
  fi
}

###############################################################################
# UFW with Docker fix (DOCKER-USER chain)
###############################################################################
configure_ufw() {
  hr
  log "Configuring UFW + Docker DOCKER-USER chain fix"

  apt-get install -y -qq ufw

  # Default policies
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing

  # SSH
  if [[ -n "$ALLOWED_SSH_FROM" ]]; then
    ufw allow from "$ALLOWED_SSH_FROM" to any port 22 proto tcp comment 'SSH (restricted)'
    log "SSH allowed only from $ALLOWED_SSH_FROM"
  else
    ufw allow 22/tcp comment 'SSH'
    warn "SSH allowed from anywhere. Consider --ssh-from <CIDR>"
  fi

  # HTTP/S
  ufw allow 80/tcp  comment 'HTTP (Caddy ACME + redirect)'
  ufw allow 443/tcp comment 'HTTPS (Caddy)'
  ufw allow 443/udp comment 'HTTPS/3 QUIC (Caddy)'

  # Docker bypasses UFW INPUT chain. Fix by routing DOCKER-USER through UFW.
  # Reference: https://github.com/chaifeng/ufw-docker
  if ! grep -q 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules; then
    cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m conntrack --ctstate NEW --ctorigdstport 22  -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m conntrack --ctstate NEW --ctorigdstport 22  -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m conntrack --ctstate NEW --ctorigdstport 22  -d 10.0.0.0/8

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
    log "Inserted ufw-docker rules into /etc/ufw/after.rules"
  else
    log "ufw-docker rules already present"
  fi

  ufw --force enable
  ufw reload
  systemctl restart docker
  log "UFW active. Status:"
  ufw status numbered | tee -a "$HARDEN_LOG"
}

###############################################################################
# SSH hardening
###############################################################################
harden_ssh() {
  hr
  log "Applying SSH hardening (conservative; preserves password auth)"

  # Drop a sshd config snippet rather than editing the main file
  cat > /etc/ssh/sshd_config.d/99-opencti-harden.conf <<'EOF'
# OpenCTI host SSH hardening (conservative)
PermitRootLogin no
PasswordAuthentication yes        # change to "no" once you have keys deployed
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding no
AllowTcpForwarding no
Banner none
EOF

  if sshd -t 2>/tmp/sshd-test.err; then
    systemctl reload ssh || systemctl reload sshd || true
    log "SSH config validated and reloaded"
  else
    err "SSH config test failed:"
    cat /tmp/sshd-test.err >&2
    warn "Reverting SSH hardening"
    rm -f /etc/ssh/sshd_config.d/99-opencti-harden.conf
  fi

  warn "Password auth still enabled. Once you confirm key login works, change:"
  warn "  PasswordAuthentication no"
  warn "  in /etc/ssh/sshd_config.d/99-opencti-harden.conf and reload sshd."
}

###############################################################################
# Unattended security upgrades
###############################################################################
configure_auto_upgrades() {
  hr
  log "Enabling unattended security upgrades"

  apt-get install -y -qq unattended-upgrades apt-listchanges

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

  # Default config restricts to security; that is what we want
  log "Unattended security upgrades enabled"
}

###############################################################################
# Optional: fail2ban for SSH
###############################################################################
install_fail2ban() {
  if [[ $INSTALL_FAIL2BAN -ne 1 ]]; then
    info "Skipping fail2ban (--no-fail2ban)"
    return 0
  fi

  hr
  log "Installing fail2ban"

  apt-get install -y -qq fail2ban

  cat > /etc/fail2ban/jail.d/opencti.conf <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
backend = systemd
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
  log "fail2ban active for sshd"
}

###############################################################################
# Restart stack with new bindings + verify
###############################################################################
restart_and_verify() {
  hr
  log "Restarting OpenCTI stack with new bindings"

  cd "$OPENCTI_INSTALL_DIR"
  docker compose down
  docker compose up -d

  log "Waiting for OpenCTI to be healthy through Caddy..."
  set +e
  for i in $(seq 1 60); do
    # Test through Caddy locally (skip cert verify for local CA case)
    if curl -fsSk --max-time 5 --resolve "${HOSTNAME_FQDN}:443:127.0.0.1" \
        "https://${HOSTNAME_FQDN}/" -o /dev/null 2>/dev/null; then
      log "OpenCTI reachable through HTTPS after $((i*5))s"
      set -e
      return 0
    fi
    sleep 5
  done
  set -e
  warn "Could not verify HTTPS reachability automatically."
  warn "Check manually: curl -kv https://${HOSTNAME_FQDN}/"
  warn "Caddy logs: journalctl -u caddy -n 100"
}

###############################################################################
# Final summary
###############################################################################
print_summary() {
  hr
  cat <<EOF

  $(printf "%b" "$C_GRN")OpenCTI hardening complete$(printf "%b" "$C_RESET")

  Public URL    : https://${HOSTNAME_FQDN}
  Admin email   : $(grep ^OPENCTI_ADMIN_EMAIL "$OPENCTI_INSTALL_DIR/.env" | cut -d= -f2)

  What changed:
    Internal services bound to 127.0.0.1 (no LAN exposure):
      - opencti:8080
      - minio:9000
      - rabbitmq:15672
      - redis:6379
      - elasticsearch:9200
    Caddy reverse proxy on :80/:443 (auto HTTPS)
    UFW default-deny + Docker DOCKER-USER fix
    SSH hardening (root login disabled, no X11/agent forward)
    Unattended security upgrades enabled
$(if [[ $INSTALL_FAIL2BAN -eq 1 ]]; then echo "    fail2ban active on sshd"; fi)

  Files:
    /etc/caddy/Caddyfile               Caddy config
    /etc/ufw/after.rules               UFW + Docker integration
    /etc/ssh/sshd_config.d/99-opencti-harden.conf
    /var/log/caddy/opencti-access.log  Access log
    ${OPENCTI_INSTALL_DIR}/.env.pre-harden.*.bak       Pre-harden .env backup
    ${OPENCTI_INSTALL_DIR}/docker-compose.yml.pre-harden.*.bak

  Next steps:
EOF
  if [[ $USE_LOCAL_CA -eq 1 ]]; then
    cat <<EOF
    1. Copy Caddy's local CA root cert to your client machines and trust it:
         scp ${HOSTNAME_FQDN}:/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ~/
         (Then import into your OS / browser trust store.)
    2. Add ${HOSTNAME_FQDN} to your local DNS or /etc/hosts pointing at this VM's IP.
EOF
  else
    cat <<EOF
    1. Confirm DNS for ${HOSTNAME_FQDN} points at this VM's public IP.
    2. Caddy obtained a Let's Encrypt cert automatically. Verify with:
         curl -I https://${HOSTNAME_FQDN}/
EOF
  fi
  cat <<EOF
    3. Switch SSH to key-only auth: edit /etc/ssh/sshd_config.d/99-opencti-harden.conf
       set PasswordAuthentication no, then: systemctl reload ssh
    4. Review UFW: ufw status numbered
    5. Tail Caddy:  journalctl -u caddy -f

EOF
}

###############################################################################
# Main
###############################################################################
main() {
  preflight
  patch_compose_bindings
  update_env_for_proxy
  install_caddy
  configure_caddy
  configure_ufw
  harden_ssh
  configure_auto_upgrades
  install_fail2ban
  restart_and_verify
  print_summary
}

main "$@"
