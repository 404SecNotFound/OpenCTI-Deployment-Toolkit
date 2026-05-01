# OpenCTI Deployment Toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/shell-bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![OpenCTI](https://img.shields.io/badge/OpenCTI-6.8.x-blue.svg)](https://github.com/OpenCTI-Platform/opencti)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange.svg)](https://ubuntu.com/)
[![Status](https://img.shields.io/badge/status-actively%20maintained-brightgreen.svg)](#status)

OpenCTI's official Docker repo gets you a running platform. It does not get you a production-ready one. **This toolkit closes the gap.**

Five Bash scripts that take a fresh Ubuntu VM to a hardened, monitored, connector-loaded OpenCTI deployment in under 30 minutes - including the fixes for issues you would otherwise hit on day one: RabbitMQ tuning, Docker-UFW firewall bypass, connector UUID drift, TLP value bugs, ingestion stalls, needrestart blocking, port collisions, and more.

Built from real deployment scars. See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for the full incident log.

---

## Why this matters for detection engineers

If you build detection content - SIEM rules, hunt queries, threat models - you need a fast way to spin up a CTI lab loaded with real feeds (AlienVault OTX, abuse.ch, MITRE ATT&CK, MITRE ATLAS) without spending a day fighting Compose files. This toolkit gives you that lab in under 30 minutes, hardened with HTTPS and a firewall, and keeps it healthy via a 15-minute cron health check that auto-restarts stalled connectors.

The connector template library is intentionally extensible. Add your own template once, deploy it across every customer engagement after that with a single command.

---

## What you get

| Script | Purpose |
|---|---|
| `install-opencti.sh` | Bootstrap install on Ubuntu 22.04 / 24.04. VM spec detection, profile-based tuning, kernel + ulimit hardening, Docker CE install, secrets generation, dynamic connector UUID generation. |
| `harden.sh` | Production hardening overlay. Caddy reverse proxy with auto-HTTPS, internal services bound to localhost, UFW with Docker bypass fix, SSH hardening, fail2ban, unattended security upgrades. |
| `add-connector.sh` | Deploy connectors via templates - no manual YAML editing. Built-in templates for AlienVault, MITRE, AbuseIPDB, ThreatFox, URLhaus, MISP, TweetFeed. Custom YAML support. Auto UUID generation, compose validation, log tailing. |
| `manage.sh` | Day-2 operations - status, logs, backup, upgrade, password reset, nuke. |
| `health-check.sh` | 15-minute cron health monitor. Container state + ingestion stall detection via OpenCTI GraphQL. Auto-restart with anti-loop backoff. |

---

## What success looks like

After the install + harden + connectors run, `health-check.sh --status` looks like this on a working stack:

```
Container restart counters:
Connector ingestion state:
  connector-alienvault            last_work=15min ago   last_checked=0min ago
  connector-mitre-atlas           last_work=47min ago   last_checked=0min ago
  connector-opencti               last_work=143min ago  last_checked=0min ago
  connector-threatfox             last_work=60min ago   last_checked=0min ago
  connector-urlhaus               last_work=62min ago   last_checked=0min ago
```

Empty restart counters mean nothing has gone wrong. `last_work` timestamps confirm each connector is producing real ingestion cycles.

---

## Quick start

On a fresh Ubuntu 22.04 or 24.04 VM (recommended: 16 GB RAM, 8 cores, 100+ GB SSD):

### Step 1 - Install (8 to 12 minutes)

```bash
sudo ./install-opencti.sh
```

Most of the time is image pulls (OpenCTI, Elasticsearch, RabbitMQ, MinIO, Redis, connectors). On a 16 GB VM, the platform itself takes 3 to 5 minutes to pass its first health check after containers come up. The script waits for it.

**Verify:**
```bash
sudo docker compose ps                # all containers healthy or running
curl -fsS "http://localhost:8080/health?health_access_key=$(sudo grep ^OPENCTI_HEALTHCHECK_ACCESS_KEY /opt/opencti/.env | cut -d= -f2)"
```

Credentials are saved to `/root/opencti-credentials.txt` (mode 600).

### Step 2 - Harden with HTTPS + firewall (3 to 5 minutes)

```bash
sudo ./harden.sh --hostname cti.lab.local --local-ca
```

For internal hostnames (`*.local`, `*.lan`, `*.internal`), Caddy issues a self-signed cert from its built-in local CA. For public hostnames, add `--email you@example.com` to get a real Let's Encrypt cert.

**Verify:**
```bash
curl -kI https://cti.lab.local/      # expect HTTP/2 200
sudo ufw status numbered             # expect: 22/80/443 allowed, all else denied
```

Then add `cti.lab.local` to your laptop's hosts file pointing at the VM's IP and browse to it.

### Step 3 - Add data sources (1 to 2 minutes per connector)

```bash
sudo ./add-connector.sh --template alienvault --api-key YOUR_OTX_KEY
sudo ./add-connector.sh --template urlhaus    --api-key YOUR_ABUSE_CH_KEY
sudo ./add-connector.sh --template threatfox  --api-key YOUR_ABUSE_CH_KEY
sudo ./add-connector.sh --template mitre
```

Each connector takes about 60 to 90 seconds to deploy and start. The script tails logs for 30 seconds so you see the connector register and start fetching.

**Verify:**
```bash
sudo ./add-connector.sh --list       # see all built-in templates
sudo docker compose ps connector-alienvault   # expect: Up
```

Then in the OpenCTI UI: **Data → Ingestion → Connectors → Monitoring** to see message counts grow over the next hour.

### Step 4 - Auto health monitoring (instant)

```bash
sudo ./health-check.sh --install-cron
```

That's it. Runs every 15 minutes from cron. Logs to `/var/log/opencti-health.log`. Restarts unhealthy or stalled containers automatically with anti-loop backoff.

**Verify:**
```bash
sudo grep opencti-health /etc/crontab           # expect: */15 * * * * line
sudo ./health-check.sh                          # one-shot run
sudo ./health-check.sh --status                 # connector ingestion state
```

---

## Profile-based VM tuning

`install-opencti.sh` detects VM specs and picks one of five tuning profiles automatically:

| RAM        | Profile     | Elasticsearch heap | Worker replicas |
|------------|-------------|--------------------|-----------------|
| < 6 GB     | minimal     | 2G                 | 1               |
| 6 to 12 GB | lab         | 3G                 | 2               |
| 12 to 24 GB| standard    | 6G                 | 3               |
| 24 to 48 GB| production  | 12G                | 4               |
| 48+ GB     | enterprise  | 16G                | 6               |

Override at any time by editing `/opt/opencti/.env` and running `docker compose up -d`.

---

## Connector deployment options

Four ways to add connectors, ranked by trade-off:

1. **`add-connector.sh`** *(recommended for community edition)* - template-driven, repeatable, idempotent, no UI dependency. Built-in templates plus custom YAML support.

2. **XTM Composer + UI catalog** - Filigran's official UI-driven deployment. **Requires Enterprise Edition.** Free 30-day trial available in-app. Free non-revenue (NFR) licenses available for individual researchers and registered charities. Apply at [filigran.io](https://filigran.io/opencti-enterprise-editions-license-request/).

3. **Portainer / Dockge** - generic Docker compose UIs. Visual but still YAML-based. Useful if you already manage other Docker workloads on the same host.

4. **Manual compose edit** - last resort. Edit `/opt/opencti/docker-compose.yml` directly, generate a fresh UUID per connector with `uuidgen`. Easy to make mistakes, especially around UUID reuse and indentation.

See [LESSONS-LEARNED.md](LESSONS-LEARNED.md) for the trade-offs in detail.

---

## Hardening: the gaps most guides miss

`harden.sh` addresses three real production exposures that out-of-the-box installs leave behind.

### The Docker + UFW bypass

Out of the box, `ufw deny 9000` does nothing to a container started with `-p 9000:9000`. Docker manipulates iptables directly and bypasses UFW's INPUT chain entirely. This is documented Docker behaviour, not a bug. Most OpenCTI guides leave MinIO, RabbitMQ admin, Elasticsearch, and Redis exposed on `0.0.0.0` while the operator believes UFW is protecting them.

`harden.sh` fixes both halves: rebinds those internal services to `127.0.0.1` so they are never reachable on the LAN, and writes the standard ufw-docker rules into `/etc/ufw/after.rules` so UFW actually applies to container traffic going forward.

### TLS without DNS hassle

For internal hostnames (`*.local`, `*.lan`, `*.internal`, `*.test`), Caddy issues a self-signed certificate from its built-in local CA. Trust the root CA cert once on each client machine and you get a green padlock for `https://cti.lab.local` without buying a domain or running an internal PKI.

For public hostnames, add `--email you@example.com` and Caddy obtains a real Let's Encrypt certificate automatically. Same Caddyfile, same script, different cert source.

### SSH and OS hygiene

Adds conservative SSH hardening (root login disabled, max 4 retries, no agent or X11 forwarding), enables unattended security upgrades, and installs fail2ban with a 1-hour ban after 5 failed SSH attempts in 10 minutes. None of this is novel - it is just consistently missed in lab deployments that drift into production use.

---

## Health monitoring: signals that actually work

`health-check.sh` monitors four layers:

1. **Platform** - `/health` endpoint with the access key
2. **Core services** - container health for Elasticsearch, RabbitMQ, Redis, MinIO
3. **Connectors** - container state plus ingestion stall detection
4. **Workers** - replica count matches the profile

The connector check uses the **OpenCTI GraphQL API** to look up each connector's most recent `Work.received_time` - the same field OpenCTI's UI uses on the connector detail page. If a scheduled connector hasn't produced a new Work entry in 60 minutes while running, the script flags it as stalled and restarts it.

**Why not just check container state?** Because a connector container can report "running" while doing nothing - stuck on an OTX API call with a revoked key, blocked on a slow upstream, or wedged in a pagination loop. Container state is necessary but not sufficient. `Work.received_time` is the receipt that the connector is actually doing its job.

**Anti-loop backoff:** after 3 consecutive auto-restarts of the same container, the script gives up and waits for human intervention. Reset with `--reset` after fixing the root cause.

```bash
sudo ./health-check.sh                  # one-shot check
sudo ./health-check.sh --install-cron   # install 15-min cron
sudo ./health-check.sh --status         # restart counters + ingestion state
sudo ./health-check.sh --reset          # clear backoff counters
```

---

## Requirements

- **OS:** Ubuntu 22.04 LTS or 24.04 LTS
- **Recommended:** 16 GB RAM, 8 cores, 100+ GB SSD, bridged networking
- **Minimum:** 8 GB RAM, 4 cores, 50 GB disk *(installs and runs but slow)*
- **Network:** outbound internet for image pulls and feed fetching
- **Privileges:** root (via `sudo`)

---

## Tested against

- OpenCTI platform: **6.8.x** *(default pin: 6.8.12)*
- Ubuntu: **22.04 LTS** and **24.04 LTS**
- Docker: **CE from Docker's official APT repo** (current stable)
- Caddy: **2.11.x**
- VMware Workstation, ProxmoxVE, AWS EC2 *(all tested)*

Other configurations should work but are not validated. PRs adding test coverage for other distros (Debian, RHEL, Rocky) are welcome.

---

## Status

This toolkit is **actively maintained** as part of an ongoing OpenCTI deployment workflow. Issues and PRs are reviewed.

**What "actively maintained" means here:**
- Bugs reported via Issues will be triaged within reasonable time
- New connector templates added on demand
- Compatibility tracked against current OpenCTI 6.8.x and 7.x LTS releases as they ship
- No SLA - this is community work, not a commercial product

**When NOT to use this toolkit:**
- You need air-gapped or fully offline deployment *(scripts assume internet access)*
- You're standing up a multi-node OpenCTI cluster *(this targets single-VM deployments)*
- You require formal vendor support *(use Filigran's commercial offering)*
- You need RHEL/Rocky/CentOS support today *(Ubuntu only as of now)*

---

## Documentation

- [Lessons learned](LESSONS-LEARNED.md) - real issues encountered during deployment and the fixes baked into the scripts
- [Contributing](CONTRIBUTING.md) - how to submit issues, PRs, and new connector templates
- [Security policy](SECURITY.md) - how to report vulnerabilities responsibly
- [Examples](examples/) - custom connector YAMLs you can adapt

---

## License

MIT - use, modify, redistribute, sell. See [LICENSE](LICENSE).

## Credits

Built on top of the official [OpenCTI Docker repo](https://github.com/OpenCTI-Platform/docker) by [Filigran](https://filigran.io). This toolkit wraps and extends Filigran's work with operational tooling that addresses real deployment issues. All upstream credit belongs to the OpenCTI maintainers.

Hardening patterns adapted from [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker) (Docker + UFW integration).

---

## Acknowledgement

If this toolkit saves you a day of deployment pain, the cheapest way to say thanks is to ⭐ the repo so other practitioners find it. PRs and issue reports help even more.
