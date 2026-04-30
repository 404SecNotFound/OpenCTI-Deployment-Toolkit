# OpenCTI Deployment - Lessons Learned

Real-world issues hit while deploying OpenCTI on Ubuntu and the fixes baked into these scripts.

## Install issues

| Issue | Cause | Fix in scripts |
|---|---|---|
| `dependency opencti failed to start` on first run | Workers scaled before platform health-check passed | `install-opencti.sh` waits for `/health` BEFORE scaling workers |
| Connector containers report blank `CONNECTOR_ID` | Upstream compose adds new built-in connectors over time; hardcoded UUID lists go stale | `install-opencti.sh` greps the compose file dynamically for every `CONNECTOR_*_ID` and generates UUIDs |
| `vm.max_map_count` errors blocking Elasticsearch | Kernel default too low | `install-opencti.sh` writes `/etc/sysctl.d/99-opencti.conf` |
| Default credentials left as `ChangeMe...` | Tutorials copied verbatim | All secrets generated via `openssl rand` and `uuidgen` |
| Container logs filling disk | Default Docker JSON logger unbounded | `daemon.json` sets `max-size: 50m`, `max-file: 5` |

## Hardening issues

| Issue | Cause | Fix |
|---|---|---|
| `needrestart` blocking apt mid-script | Ubuntu 22.04 default | `DEBIAN_FRONTEND=noninteractive` + `NEEDRESTART_MODE=a` exported at top of every script |
| Caddy fails on first start with permission denied | Log dir created before `caddy` user existed | `chown caddy:caddy /var/log/caddy` after install |
| Docker bypasses UFW completely | Docker manipulates iptables directly | `ufw-docker` rules written to `/etc/ufw/after.rules` (DOCKER-USER chain) |
| OpenCTI tries to bind 443 (Caddy port) | `OPENCTI_PORT` drives both BASE_URL and host port mapping | Set `OPENCTI_BASE_URL` directly without referencing `OPENCTI_PORT` |

## Connector issues

| Issue | Cause | Fix |
|---|---|---|
| AlienVault: `Invalid TLP value 'TLP:WHITE'` | Connector expects lowercase, no prefix | Use `ALIENVAULT_TLP=white` |
| URLhaus / ThreatFox: 401 Unauthorized | abuse.ch made auth keys mandatory in 2024 | Sign up at https://auth.abuse.ch/ |
| AlienVault stuck on "Fetching subscribed pulses..." | OTX paginates 50 pulses at a time; large accounts take 30+ min for first fetch | Be patient, narrow `ALIENVAULT_PULSE_START_TIMESTAMP` for testing |
| AlienVault returns 0 messages | Most likely: API key revoked/reset, or zero subscribed pulses on OTX account | Test with `curl -H "X-OTX-API-KEY: $KEY" https://otx.alienvault.com/api/v1/user/me` first |
| OTX `X-OTX-ACTIVE: 0` header | Account API access deactivated | Re-enable via OTX UI Settings |

## Detection signals (for health monitoring)

The `/health` endpoint and container `Status: healthy` are necessary but NOT sufficient. A connector container can report "running" while doing nothing. Better signals:

- **Most recent `Work.received_time` from GraphQL** - if no new work in 60 min for a scheduled connector, it's stuck
- **Stale `connector_state_timestamp`** - heartbeat indicator
- **`messages_number` in queue** is a misleading signal - 0 means either healthy (workers draining queue) or broken (nothing being pushed)

`health-check.sh` uses `Work.received_time` as the primary stall signal because it's what OpenCTI's own UI uses.

## OpenCTI behaviour caveats

- First-run platform startup can take 3-5+ minutes on a 16 GB / 8 core VM. Health timeouts shorter than that cause false failures.
- ATLAS (AI/ML threat matrix) is separate from ATT&CK - both are useful, run both.
- Built-in connectors in upstream compose include `connector-mitre`. Don't add a second MITRE ATT&CK connector via templates - they conflict.
- The Connector Catalog (UI deployment of connectors) requires Enterprise Edition. Free 30-day trial available, free NFR licenses for individual researchers and charities.
