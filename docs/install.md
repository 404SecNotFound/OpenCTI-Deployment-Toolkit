# `install-opencti.sh` - Deep Dive

The bootstrap installer. Takes a fresh Ubuntu 22.04 or 24.04 VM and produces a running OpenCTI stack with sensible defaults, strong randomized secrets, and tuned kernel parameters.

## Usage

```bash
sudo ./install-opencti.sh                              # interactive defaults
sudo ./install-opencti.sh --version 6.8.12             # pin a specific version
sudo ./install-opencti.sh --domain cti.example.com     # set external domain
sudo ./install-opencti.sh --noninteractive             # accept all defaults
```

## What It Does, In Order

### 1. Pre-flight
- Verifies root privileges
- Checks Ubuntu version (22.04 or 24.04 - warns and prompts on others)
- Tests outbound network reachability to `download.docker.com`

### 2. VM Spec Detection
Reads CPU cores, RAM, swap, and free disk on `/`. Picks one of five profiles:

| RAM band   | Profile     | ES heap | Worker replicas |
|------------|-------------|---------|-----------------|
| < 6 GB     | minimal     | 2G      | 1               |
| 6 to 12 GB | lab         | 3G      | 2               |
| 12 to 24 GB| standard    | 6G      | 3               |
| 24 to 48 GB| production  | 12G     | 4               |
| 48+ GB     | enterprise  | 16G     | 6               |

Adds a 4 GB swapfile if RAM < 8 GB and no swap exists. Warns on low CPU/disk.

### 3. Kernel Tuning
Writes `/etc/sysctl.d/99-opencti.conf`:
- `vm.max_map_count=1048575` (Elasticsearch requirement)
- `fs.file-max=2097152`
- `net.core.somaxconn=4096`
- `vm.swappiness=10`

Writes `/etc/security/limits.d/99-opencti.conf` raising nofile and nproc to 131072 / 65535 for all users.

### 4. Docker Install
Installs Docker CE and Compose v2 from Docker's official APT repo. Removes any conflicting `docker.io`, `docker-compose`, `podman-docker`, etc. Configures `/etc/docker/daemon.json` for log rotation (50 MB / 5 files), live-restore, and default ulimits.

### 5. Repo Clone
Clones `OpenCTI-Platform/docker` into `/opt/opencti` (override with `--install-dir`). Always tracks `master` because the docker compose file is updated independently of platform releases. Image versions are pinned via the `.env` file.

### 6. Secrets Generation
Generates strong randomized values:
- Admin password (22 chars, base64-derived)
- Admin token (UUID)
- Healthcheck access key (UUID)
- Encryption key (32 bytes base64)
- MinIO and RabbitMQ user/pass
- XTM Composer ID
- One UUID per `CONNECTOR_*_ID` variable referenced in the upstream compose file (auto-discovered, future-proof)

All values written to `/opt/opencti/.env` (mode 600). A backup copy goes to `/root/opencti-credentials.txt` (also mode 600).

### 7. Compose Patches
Verifies upstream compose includes RabbitMQ tuning (`max_message_size`, `consumer_timeout`) and ES `thread_pool.search.queue_size`. Warns if missing - newer upstream versions ship with these by default.

### 8. Stack Deploy
- `docker compose pull` (parallel image fetch)
- `docker compose up -d`
- Waits up to 15 minutes for the platform `/health` endpoint to respond
- After health passes, scales `worker` to the profile-specified count

### 9. XTM Composer
If upstream compose doesn't already include XTM Composer, the script adds a sidecar container with RSA keypair generation and a config file pointing at the running platform. Lets you use the EE Connector Catalog from the UI later.

## What Could Go Wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `vm.max_map_count` errors during ES startup | sysctl didn't apply | `sudo sysctl --system` then restart stack |
| `dependency opencti failed to start` on first run | Worker scaling raced platform health | Script v2+ waits for health first; on older versions, just rerun `docker compose up -d` |
| `connect ECONNREFUSED 172.18.0.X:5672` (RabbitMQ) | Connector started before RabbitMQ healthy | Restart the affected service after stack stabilizes |
| Health timeout after 15 minutes | Slow disk or insufficient RAM for the profile | Check `docker compose logs opencti` for errors; consider downgrading profile or adding RAM |
| `WARN ... CONNECTOR_X_ID not set` | Upstream added a new built-in connector | Re-run the dynamic UUID discovery: `bash -c 'grep -oE "\\\${CONNECTOR_[A-Z0-9_]+_ID" /opt/opencti/docker-compose.yml \| sort -u'` and add missing entries to `.env` |

## What It Does NOT Do

- Set up TLS - run [`harden.sh`](harden.md) for HTTPS
- Set up a firewall - run [`harden.sh`](harden.md) for UFW
- Add data sources - run [`add-connector.sh`](add-connector.md)
- Set up monitoring - run [`health-check.sh`](health-check.md)

## Files Created

```
/opt/opencti/                                Stack root
/opt/opencti/.env                            All secrets (mode 600)
/opt/opencti/docker-compose.yml              Upstream compose (patched in place)
/opt/opencti/docker-compose.yml.orig         Pre-patch backup
/opt/opencti/docker-compose.xtm.yml          XTM Composer overlay (if not in upstream)
/opt/opencti/xtm-composer/keys/              RSA keys for connector config encryption
/etc/sysctl.d/99-opencti.conf                Kernel tuning
/etc/security/limits.d/99-opencti.conf       ulimits
/etc/docker/daemon.json                      Docker daemon config
/var/log/opencti-install.log                 Install log
/root/opencti-credentials.txt                Credentials backup (mode 600)
```

## Idempotency

Most steps are safe to re-run. The script:
- Backs up an existing `.env` before regenerating (so re-running rotates credentials)
- Skips Docker install if Docker is already present and current
- Updates the cloned repo to latest `master` rather than re-cloning

Exception: re-running rotates secrets. If you need to preserve them, back up `.env` first.
