# Troubleshooting

Symptom-driven lookup table with diagnostic commands and fixes for the most common OpenCTI deployment issues.

For background on why these issues exist, see [LESSONS-LEARNED.md](LESSONS-LEARNED.md).

## Quick Diagnostics

Run these first to get an at-a-glance picture of the stack:

```bash
# Container state
sudo docker compose ps

# Platform health
HEALTH=$(sudo grep ^OPENCTI_HEALTHCHECK_ACCESS_KEY /opt/opencti/.env | cut -d= -f2)
PORT=$(sudo grep ^OPENCTI_PORT /opt/opencti/.env | cut -d= -f2)
curl -fsS "http://localhost:${PORT}/health?health_access_key=${HEALTH}" && echo "OK"

# Health monitor status
sudo /home/<user>/health-check.sh --status

# Resource use
docker stats --no-stream

# Disk
df -h /opt/opencti
```

## Index by Symptom

- [Stack won't start](#stack-wont-start)
- [Platform unhealthy or unreachable](#platform-unhealthy-or-unreachable)
- [Connector container in restart loop](#connector-container-in-restart-loop)
- [Connector running but no data ingested](#connector-running-but-no-data-ingested)
- [Caddy / HTTPS issues](#caddy--https-issues)
- [Firewall and network issues](#firewall-and-network-issues)
- [Storage and performance](#storage-and-performance)
- [Authentication and credentials](#authentication-and-credentials)
- [Upgrades and migrations](#upgrades-and-migrations)

---

## Stack won't start

### `vm.max_map_count is too low for Elasticsearch`

**Symptom:** Elasticsearch container exits immediately. `docker compose logs elasticsearch` shows max_map_count error.

**Diagnose:**
```bash
sysctl vm.max_map_count
```

**Fix:**
```bash
sudo sysctl -w vm.max_map_count=1048575
echo 'vm.max_map_count=1048575' | sudo tee /etc/sysctl.d/99-opencti.conf
sudo sysctl --system
sudo docker compose up -d
```

### `dependency rabbitmq failed to start: container is unhealthy`

**Symptom:** When deploying a connector, you see this error but `docker compose ps` shows rabbitmq as healthy seconds later.

**Cause:** RabbitMQ healthcheck flapping during restart. Transient.

**Fix:** Just retry the command:
```bash
sudo docker compose up -d <service>
```

### `dependency opencti failed to start: container is unhealthy` (during install)

**Symptom:** First-run install fails with this when worker scaling happens before platform health passes.

**Cause:** Workers tried to register before the platform finished its 3-5 minute first-run startup.

**Diagnose:**
```bash
sudo docker compose logs --tail=100 opencti
```

**Fix:** Wait, then re-run:
```bash
# Wait until the platform is healthy
sudo docker compose ps opencti

# Then bring everything up
sudo docker compose up -d
```

The current `install-opencti.sh` waits for health BEFORE scaling workers - this issue only affects older script versions.

### `WARN The "CONNECTOR_X_ID" variable is not set. Defaulting to a blank string.`

**Symptom:** Compose warnings on every command. Eventually causes connector conflicts because multiple containers register with empty IDs.

**Diagnose:**
```bash
# Find all expected connector IDs
grep -oE '\$\{CONNECTOR_[A-Z0-9_]+_ID' /opt/opencti/docker-compose.yml | sort -u

# Find what you actually have
grep ^CONNECTOR_ /opt/opencti/.env | sort
```

**Fix:** Add missing UUIDs:
```bash
cd /opt/opencti
for v in $(grep -oE '\$\{CONNECTOR_[A-Z0-9_]+_ID' docker-compose.yml | sed 's/\${//' | sort -u); do
  if ! sudo grep -q "^${v}=" .env; then
    echo "${v}=$(uuidgen)" | sudo tee -a .env >/dev/null
    echo "Added: $v"
  fi
done

sudo docker compose up -d
```

---

## Platform unhealthy or unreachable

### `/health` returns 503 or times out

**Diagnose:**
```bash
sudo docker compose logs --tail=100 opencti
sudo docker compose logs --tail=100 elasticsearch
sudo docker compose ps
```

**Common causes and fixes:**

| Log message | Fix |
|---|---|
| `connect ECONNREFUSED 172.X.X.X:9200` (Elasticsearch) | ES not ready yet. Wait or restart: `sudo docker compose restart elasticsearch opencti` |
| `connect ECONNREFUSED 172.X.X.X:5672` (RabbitMQ) | RabbitMQ flapping. `sudo docker compose restart rabbitmq` then retry |
| `Out of memory` in opencti logs | Bump platform memory limits in compose. Try downgrading profile |
| `JavaScript heap out of memory` | Same as above |
| Stuck on "Waiting for ElasticSearch" for >10 min | ES likely OOM. Check `docker stats` and increase `ELASTIC_MEMORY_SIZE` in `.env` |

### Platform shows healthy but UI is slow

**Diagnose:**
```bash
# ES cluster status
sudo docker compose exec elasticsearch curl -s localhost:9200/_cluster/health?pretty

# Worker queue depth
sudo docker compose exec rabbitmq rabbitmqctl list_queues name messages messages_ready

# Are workers keeping up?
sudo docker compose ps worker
```

**Common fixes:**
- ES status `yellow` is fine for single-node. `red` means trouble - check ES logs
- Big queue depth → scale workers: `sudo docker compose up -d --scale worker=6`
- Disk near full → free space or add storage

---

## Connector container in restart loop

### Generic diagnostic
```bash
sudo docker compose ps connector-<name>
sudo docker compose logs --tail=50 connector-<name>
```

Look for the first `ERROR` or `Traceback` line. Common patterns below.

### `ValueError: Invalid TLP value 'TLP:WHITE'` (or similar)

**Symptom:** Connector starts then immediately exits with TLP value error.

**Cause:** Connector expects lowercase TLP without the `TLP:` prefix.

**Fix:**
```bash
# Open the compose file
sudo nano /opt/opencti/docker-compose.yml

# Find ALIENVAULT_TLP=TLP:WHITE (or similar) and change to:
# ALIENVAULT_TLP=white

sudo docker compose up -d --force-recreate connector-<name>
```

### `connect ECONNREFUSED 172.X.X.X:5672`

**Cause:** Connector raced RabbitMQ during startup or RabbitMQ briefly unhealthy.

**Fix:**
```bash
sudo docker compose restart connector-<name>
```

### `Authentication required` from upstream API

**Diagnose:**
```bash
# Get the API key the connector is using
sudo docker compose exec connector-<name> env | grep API_KEY

# Test the key directly against the upstream API
# AlienVault example:
curl -H "X-OTX-API-KEY: PASTE_KEY" https://otx.alienvault.com/api/v1/user/me
```

**Fix:**
- If response shows `X-OTX-ACTIVE: 0` → key revoked. Reset in upstream account settings
- If `Anonymous` user → key invalid. Generate fresh one
- Update the key in `/opt/opencti/docker-compose.yml`:
  ```bash
  sudo nano /opt/opencti/docker-compose.yml
  # Update <SERVICE>_API_KEY=...
  sudo docker compose up -d --force-recreate connector-<name>
  ```

### `failed to bind host port 0.0.0.0:443/tcp: address already in use`

**Cause:** OpenCTI tried to bind to a port already used by Caddy (or vice versa). Earlier `harden.sh` versions overwrote `OPENCTI_PORT`.

**Fix:**
```bash
sudo sed -i \
  -e 's|^OPENCTI_PORT=.*|OPENCTI_PORT=8080|' \
  -e 's|^OPENCTI_BASE_URL=.*|OPENCTI_BASE_URL=https://YOUR_HOSTNAME|' \
  /opt/opencti/.env

cd /opt/opencti
sudo docker compose up -d
```

### Connector says "running" but does nothing

See [Connector running but no data ingested](#connector-running-but-no-data-ingested) below.

---

## Connector running but no data ingested

The container shows `Up` for hours but message count stays at 0. Most common with AlienVault and MISP.

### Step 1 - Confirm with health monitor
```bash
sudo /home/<user>/health-check.sh --status
```

If `last_work` is unchanged for >60 minutes, the connector is stalled.

### Step 2 - Read the logs
```bash
sudo docker compose logs --tail=50 connector-<name>
```

Look for:
- `Fetching subscribed pulses...` with no follow-up = connector waiting on slow upstream API
- `Authentication required` = key issue (see auth section above)
- Tracebacks = config error
- Nothing in logs at all = connector hung; restart it

### Step 3 - Test upstream API directly

For AlienVault OTX:
```bash
KEY="your_otx_key"
curl -s -H "X-OTX-API-KEY: $KEY" \
  "https://otx.alienvault.com/api/v1/pulses/subscribed?limit=1" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Total:', d.get('count'))"
```

If count is 0 or low, the connector is doing its job - you just have nothing to fetch. Subscribe to more pulses in OTX.

For abuse.ch (URLhaus / ThreatFox):
```bash
curl -I -H "Auth-Key: YOUR_AUTH_KEY" "https://urlhaus.abuse.ch/downloads/csv_recent/"
```

If 401, key is invalid. Get a new one at [auth.abuse.ch](https://auth.abuse.ch/).

### Step 4 - Narrow the date range for big backfills

For OTX accounts with hundreds of thousands of subscribed pulses, the initial fetch can take hours. Narrow `ALIENVAULT_PULSE_START_TIMESTAMP` to a recent date for testing:

```bash
sudo nano /opt/opencti/docker-compose.yml
# Change ALIENVAULT_PULSE_START_TIMESTAMP=2024-01-01T00:00:00
# To:     ALIENVAULT_PULSE_START_TIMESTAMP=2026-04-01T00:00:00

sudo docker compose up -d --force-recreate connector-alienvault
```

### Step 5 - If all else fails, restart and watch
```bash
sudo docker compose restart connector-<name>
sudo docker compose logs -f connector-<name>
```

Wait 5-10 minutes. If still no data, redeploy fresh:
```bash
sudo /home/<user>/add-connector.sh --remove connector-<name>
sudo /home/<user>/add-connector.sh --template <name> --api-key <KEY>
```

---

## Caddy / HTTPS issues

### `Job for caddy.service failed`

**Diagnose:**
```bash
sudo journalctl -xeu caddy.service --no-pager | tail -30
```

**Common causes:**

| Log says | Fix |
|---|---|
| `permission denied: /var/log/caddy/...` | `sudo chown -R caddy:caddy /var/log/caddy && sudo systemctl start caddy` |
| `address already in use` | Another service has port 80 or 443. `sudo ss -tlnp \| grep -E ':80\|:443'` to find it |
| `tls.obtain: ... no matching DNS records` | Public hostname doesn't resolve. Use `--local-ca` or fix DNS |
| `cannot validate Caddyfile` | Syntax error. `sudo caddy validate --config /etc/caddy/Caddyfile` to see details |

### Browser shows certificate warning

**For local CA (self-signed) hostnames:**

The Caddy local CA root cert isn't trusted on your client machine yet. Options:

1. **Accept the warning** for testing
2. **Trust the root CA** properly - get the cert and import it:
   ```bash
   # On the OpenCTI VM:
   sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
   ```
   Copy the PEM block, paste into a file on your client machine, then trust it:
   - **Linux:** `sudo cp caddy-root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`
   - **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt`
   - **Windows (PowerShell as admin):** `Import-Certificate -FilePath caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root`

**For Let's Encrypt hostnames:**

If you used `--email` and a public hostname, Caddy should issue a real cert automatically. If it didn't:
```bash
sudo journalctl -u caddy --no-pager | grep -E 'tls|acme|certificate' | tail -20
```

Look for rate limit errors (Let's Encrypt has weekly issuance limits per domain) or DNS validation failures.

### `cti.djr.lab DNS address could not be found`

**Cause:** Hostname not in your client's hosts file or DNS.

**Fix on client:**

- **Linux/macOS:** `sudo nano /etc/hosts` and add `192.168.X.X cti.djr.lab`
- **Windows (PowerShell as admin):** `Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "192.168.X.X cti.djr.lab"`

Verify: `ping cti.djr.lab` should resolve to your VM's IP.

---

## Firewall and network issues

### Container ports reachable from LAN despite UFW rules

**Cause:** Docker bypasses UFW's INPUT chain. Standard Docker behavior.

**Diagnose:**
```bash
# From another machine on the LAN
nmap -p 8080,9000,15672 VM_IP
```

If those ports respond despite `ufw status` showing them denied, you have the bypass issue.

**Fix:** Ensure two things are in place:

1. Internal services bound to 127.0.0.1 in compose (search for `ports:` blocks)
2. ufw-docker rules in `/etc/ufw/after.rules`:
   ```bash
   sudo grep 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules
   ```

If either is missing, re-run `harden.sh`. If you want manual control:
```bash
# Add ufw-docker rules manually (chaifeng/ufw-docker pattern)
# See harden.sh for the exact rule block
```

### Cannot SSH after running harden.sh

**Cause:** SSH hardening combined with `--ssh-from <CIDR>` excluded your IP.

**Fix from console (not SSH):**
```bash
# Disable SSH hardening
sudo rm /etc/ssh/sshd_config.d/99-opencti-harden.conf
sudo systemctl reload ssh

# Open UFW for SSH from anywhere
sudo ufw allow 22/tcp
```

Then re-run `harden.sh` with the correct CIDR.

---

## Storage and performance

### Elasticsearch heap pressure

**Symptom:** ES container restarting, slow queries, `circuit_breaking_exception` in logs.

**Diagnose:**
```bash
# Heap usage
sudo docker compose exec elasticsearch curl -s 'localhost:9200/_cat/nodes?v&h=heap.percent,heap.current,heap.max'

# Free up via index management (delete old indices)
sudo docker compose exec elasticsearch curl -s 'localhost:9200/_cat/indices?v&s=store.size:desc' | head -10
```

**Fix:** Increase heap in `.env`:
```bash
sudo sed -i 's|^ELASTIC_MEMORY_SIZE=.*|ELASTIC_MEMORY_SIZE=8G|' /opt/opencti/.env
sudo docker compose up -d elasticsearch
```

Don't go above 50% of total RAM. If you're already at the limit, set retention policies in OpenCTI: Settings → Customization → Retention policies.

### Disk filling up

**Diagnose:**
```bash
df -h /opt/opencti
sudo du -sh /var/lib/docker/volumes/opencti_*
```

**Common offenders:**
- `opencti_esdata` - ES indices grow with ingestion. Apply retention policies
- `opencti_s3data` - MinIO files. Old import files accumulate
- Container logs - should be capped at 50MB × 5 by `daemon.json` but verify:
  ```bash
  sudo cat /etc/docker/daemon.json
  ```

**Cleanup:**
```bash
# Prune dangling Docker resources
sudo docker system prune -a --volumes
# WARNING: --volumes deletes unused volumes. Verify first with:
# sudo docker volume ls -f dangling=true
```

### Worker queue backlog growing

**Diagnose:**
```bash
sudo docker compose exec rabbitmq rabbitmqctl list_queues name messages messages_ready consumers
```

If messages > workers can process, scale workers:
```bash
sudo docker compose up -d --scale worker=6
```

Or upgrade VM resources to support a higher profile.

---

## Authentication and credentials

### Forgot admin password

```bash
sudo /home/<user>/manage.sh reset-password
```

Or read it directly:
```bash
sudo cat /root/opencti-credentials.txt
```

### Token rotation

To rotate the admin token (e.g., after suspected exposure):
```bash
NEW_TOKEN=$(uuidgen)
sudo sed -i "s|^OPENCTI_ADMIN_TOKEN=.*|OPENCTI_ADMIN_TOKEN=${NEW_TOKEN}|" /opt/opencti/.env
sudo docker compose up -d --force-recreate opencti
echo "New token: ${NEW_TOKEN}"
```

**Note:** every connector and worker uses this token. They'll reconnect automatically because they read it from `.env` on container start. Just make sure containers restart cleanly after the change.

### API key compromised

If a connector's API key (OTX, abuse.ch, etc.) leaked:

1. Reset/rotate the key in the upstream service immediately
2. Update the value in compose:
   ```bash
   sudo nano /opt/opencti/docker-compose.yml
   # Update the relevant <SERVICE>_API_KEY=...
   ```
3. Force recreate the connector:
   ```bash
   sudo docker compose up -d --force-recreate connector-<name>
   ```

---

## Upgrades and migrations

### Upgrade OpenCTI version

```bash
# Always backup first
sudo /home/<user>/manage.sh backup

# Then upgrade
sudo /home/<user>/manage.sh upgrade 6.8.13

# Watch
sudo /home/<user>/manage.sh logs opencti
```

Read the release notes between your current and target versions on [OpenCTI's GitHub releases](https://github.com/OpenCTI-Platform/opencti/releases) before doing major version jumps. Some upgrades include index migrations that take time.

### Roll back an upgrade

```bash
# Revert OPENCTI_VERSION in .env to previous value
sudo nano /opt/opencti/.env

# Restart with old images
cd /opt/opencti
sudo docker compose pull
sudo docker compose up -d

# Watch for errors - some forward migrations are not reversible
sudo docker compose logs -f opencti
```

If the upgrade ran an index migration, rolling back may leave the platform unusable. Restore from backup if so.

### Restore from backup

```bash
# Find your backup
ls -lh /var/backups/opencti-*

# Stop the stack
cd /opt/opencti
sudo docker compose down

# Restore config
cd /opt/opencti
sudo tar xzf /var/backups/opencti-config-YYYY-MM-DD-HHMM.tgz

# Restore each volume
for v in esdata amqpdata rsakeys s3data redisdata; do
  echo "Restoring opencti_${v}..."
  sudo docker volume rm opencti_${v} 2>/dev/null || true
  sudo docker volume create opencti_${v}
  sudo docker run --rm -v opencti_${v}:/dst -v /var/backups:/src alpine \
    tar xzf "/src/opencti_${v}-YYYY-MM-DD-HHMM.tgz" -C /dst
done

# Restart
sudo docker compose up -d
```

Replace `YYYY-MM-DD-HHMM` with the actual backup timestamp.

---

## When to ask for help

After working through the above, if you're still stuck:

1. Open a GitHub Issue with:
   - The script and command you ran
   - Full output (with API keys redacted)
   - OpenCTI version: `grep ^OPENCTI_VERSION /opt/opencti/.env`
   - Ubuntu version: `lsb_release -a`
   - Docker version: `docker --version && docker compose version`
2. Search the [OpenCTI Slack](https://community.filigran.io/) for similar issues
3. Check [OpenCTI's own issue tracker](https://github.com/OpenCTI-Platform/opencti/issues)

For toolkit-specific bugs, the GitHub Issues here is the right venue. For OpenCTI platform bugs, escalate upstream.
