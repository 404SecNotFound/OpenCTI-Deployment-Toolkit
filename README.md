# OpenCTI Deployment Toolkit

Production-grade scripts to deploy, harden, and operate OpenCTI on Ubuntu LTS.

Built and battle-tested through real deployments. Every script captures lessons from issues you'd otherwise hit yourself - see [LESSONS-LEARNED.md](LESSONS-LEARNED.md).

## What you get

| Script | Purpose |
|---|---|
| `install-opencti.sh` | Installs OpenCTI from scratch on Ubuntu 22.04/24.04. VM spec detection, profile-based tuning, kernel + ulimit hardening, Docker CE install, secrets generation, dynamic connector UUID generation. |
| `harden.sh` | Production hardening overlay. Caddy reverse proxy with auto-HTTPS, internal services bound to localhost, UFW with Docker bypass fix, SSH hardening, fail2ban, unattended security upgrades. |
| `add-connector.sh` | Deploy connectors via templates - no manual YAML editing. Built-in templates for AlienVault, MITRE, AbuseIPDB, ThreatFox, URLhaus, MISP, TweetFeed. Custom YAML support. Auto UUID generation, compose validation, log tailing. |
| `manage.sh` | Day-2 operations - status, logs, backup, upgrade, password reset, nuke. |
| `health-check.sh` | 15-minute cron health monitor. Container state + ingestion stall detection via OpenCTI GraphQL. Auto-restart with anti-loop backoff. |

## Quick start

On a fresh Ubuntu 22.04 or 24.04 VM (recommended: 16 GB RAM, 8 cores, 100+ GB disk):

```bash
# 1. Install
sudo ./install-opencti.sh

# 2. Harden with HTTPS + firewall
sudo ./harden.sh --hostname cti.lab.local --local-ca

# 3. Add data sources
sudo ./add-connector.sh --template alienvault --api-key YOUR_OTX_KEY
sudo ./add-connector.sh --template urlhaus --api-key YOUR_ABUSE_CH_KEY
sudo ./add-connector.sh --template threatfox --api-key YOUR_ABUSE_CH_KEY

# 4. Start auto health monitoring (cron every 15 min)
sudo ./health-check.sh --install-cron
```

## Profile-based VM tuning

`install-opencti.sh` detects VM specs and picks one of five tuning profiles:

| RAM | Profile | ES heap | Worker replicas |
|---|---|---|---|
| < 6 GB | minimal | 2G | 1 |
| 6 to 12 GB | lab | 3G | 2 |
| 12 to 24 GB | standard | 6G | 3 |
| 24 to 48 GB | production | 12G | 4 |
| 48+ GB | enterprise | 16G | 6 |

Override at any time via `/opt/opencti/.env`.

## Connector deployment options

Four ways to add connectors, ranked:

1. **`add-connector.sh` (recommended for community edition)** - template-driven, repeatable, no UI dependency
2. **XTM Composer + UI catalog** - Filigran's official UI deployment, requires Enterprise Edition (free trial / NFR for researchers available)
3. **Portainer / Dockge** - generic Docker UI, still YAML-based but visual
4. **Manual compose edit** - last resort

See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for trade-offs.

## Hardening details

`harden.sh` addresses the most-missed production gaps:

- **Docker + UFW bypass** - Docker manipulates iptables directly, so `ufw deny 9000` does nothing to a `-p 9000:9000` container. Script writes the chaifeng/ufw-docker rules to enforce UFW on container traffic.
- **Internal service exposure** - default install publishes MinIO console, RabbitMQ admin, ES, Redis on `0.0.0.0`. Script rebinds to `127.0.0.1`.
- **Caddy local CA for internal hostnames** - if your hostname looks internal (`*.local`, `*.lan`, etc.) Caddy issues self-signed certs from its built-in CA. Trust the root once on each client and you get HTTPS without DNS hassle.

## Health monitoring

`health-check.sh` monitors:

1. Platform `/health` endpoint
2. Core service container health (Elasticsearch, RabbitMQ, Redis, MinIO)
3. Per-connector ingestion stall detection via OpenCTI GraphQL `Work.received_time`
4. Worker replica count

Auto-restarts unhealthy or stalled containers with anti-loop backoff (max 3 retries before manual intervention required).

```bash
sudo ./health-check.sh                  # one-shot check
sudo ./health-check.sh --install-cron   # 15-min cron
sudo ./health-check.sh --status         # restart counters + ingestion state
sudo ./health-check.sh --reset          # clear backoff counters
```

## Requirements

- Ubuntu 22.04 LTS or 24.04 LTS
- Recommended: 16 GB RAM, 8 cores, 100+ GB SSD
- Minimum: 8 GB RAM, 4 cores, 50 GB disk (will be slow)
- Outbound internet access for image pulls and feed fetching

## License

MIT - use it however you want. PRs welcome.

## Credits

Built on top of the official [OpenCTI Docker repo](https://github.com/OpenCTI-Platform/docker). This toolkit wraps and extends Filigran's work with operational tooling that addresses real deployment issues.
