# `health-check.sh` - Deep Dive

Cron-driven health monitor with auto-restart and anti-loop backoff. Designed to run every 15 minutes and Just Work.

## Usage

```bash
# One-shot check (writes to /var/log/opencti-health.log)
sudo ./health-check.sh

# Install the 15-minute cron entry
sudo ./health-check.sh --install-cron

# View current restart counters and ingestion state
sudo ./health-check.sh --status

# Reset counters (do this after manually fixing an issue that hit the backoff cap)
sudo ./health-check.sh --reset
```

## What It Checks

### 1. Platform
Hits `/health?health_access_key=<key>` from `/opt/opencti/.env`. If it doesn't respond within 10 seconds, restarts the `opencti` container.

### 2. Core Services
Checks Docker container health for `elasticsearch`, `rabbitmq`, `redis`, `minio`. Possible states:

| State | Action |
|---|---|
| `healthy` | Clear restart counter, log success |
| `starting` | Log and recheck next run |
| `unhealthy` | Restart with backoff |
| `missing` (container doesn't exist) | Bring up via `docker compose up -d` |

### 3. Connector Container State
For every service whose name starts with `connector-`, checks Docker state:

| State | Action |
|---|---|
| `running` | Proceed to ingestion check |
| `restarting` | Log warning (container is in its own restart loop, probably bad config - don't pile on) |
| `exited` / `dead` | Restart with backoff |
| `missing` | Bring up |

### 4. Connector Ingestion (the smart bit)
For each running connector, queries the OpenCTI GraphQL API for the connector's most recent `Work.received_time`:

```graphql
query {
  connectors {
    name
    works {
      received_time
    }
  }
}
```

State stored in `/var/lib/opencti-health/<service>.ingest`:
- Line 1: ISO 8601 timestamp of the most recent Work seen
- Line 2: Epoch seconds when this script last checked

Decision tree:
- **New Work since last check** → connector is alive, log "active"
- **Same Work as last time, but Work is recent (< 60 min old)** → connector is idle but not dead, log "idle"
- **Same Work, Work is old (≥ 60 min)** → connector is STALLED, restart with backoff
- **No Works at all, beyond grace period** → connector hasn't started a single fetch cycle, restart with backoff

### 5. Worker Replicas
Checks how many `opencti-worker` containers are running. If less than the expected count (default 3, configurable in the script), rescales:

```bash
docker compose up -d --scale worker=3
```

## Why `Work.received_time` Is the Right Signal

Container state alone isn't enough. A connector container can report `Status: running` while doing nothing - stuck on a slow upstream API, blocked on auth, or wedged in a pagination loop. We saw this in real deployments with AlienVault OTX after an API key reset: container running, zero data ingested for hours.

`/health` endpoint isn't enough either. It only tells you the platform is up.

`messages_count` (queue depth) is misleading. Healthy connectors with fast workers show 0 (queue drained). Broken connectors that aren't pushing also show 0. Same observable, different states.

`Work.received_time` is what the OpenCTI UI uses on the connector detail page. It's the receipt that the connector successfully kicked off an ingestion cycle - regardless of how long the cycle takes to process. If a scheduled connector hasn't created a new Work entry in an hour, something is wrong.

## Anti-Loop Backoff

After 3 consecutive auto-restarts of the same container, the script gives up:

```
[ERROR] connector-alienvault: backoff active (3 restarts). Skipping.
        Reason: ingestion stalled for 75min.
        Reset with: /home/user/health-check.sh --reset
```

The container stays in its current state until you intervene. Why: thrashing a misconfigured connector every 15 minutes wastes resources and obscures the real problem. The backoff forces you to look at it.

To clear after fixing the root cause:

```bash
sudo ./health-check.sh --reset
```

## Tuning

Top of the script:

```bash
MAX_RESTARTS=3            # Backoff after this many consecutive restarts
EXPECTED_WORKERS=3        # Match your install profile
STALL_MINUTES=60          # Flag as stalled after this many minutes of no new Work
STALL_GRACE_MINUTES=15    # Grace period for newly-deployed connectors
```

Adjust if 60 minutes is too aggressive (some connectors run on hours- or days-long cycles - MITRE Datasets, for example, has a 7-day default interval). For long-cycle connectors, either:
- Set `STALL_MINUTES=10080` (a week) globally
- Or modify the script to whitelist long-cycle connectors from the stall check

## Status Output

```
$ sudo ./health-check.sh --status

Container restart counters:

Connector ingestion state:
  connector-alienvault            last_work=15min ago   last_checked=0min ago
  connector-mitre-atlas           last_work=47min ago   last_checked=0min ago
  connector-opencti               last_work=143min ago  last_checked=0min ago
  connector-threatfox             last_work=60min ago   last_checked=0min ago
  connector-urlhaus               last_work=62min ago   last_checked=0min ago
  connector-import-document       no_works  last_checked=0min ago
```

Empty restart counters = nothing has gone wrong. `last_work` ages tell you which connectors are scheduled (have works) vs event-driven (no works because they're triggered by user actions).

## What It Does NOT Do

- Read connector logs for error patterns - log parsing is fragile and version-dependent. The Work-based signal works regardless of log format
- Send alerts to Slack / email / PagerDuty - keep `health-check.sh --status` in a dashboard or pipe `/var/log/opencti-health.log` into your alerting pipeline
- Distinguish event-driven from scheduled connectors automatically - some internal connectors (export-file-*, import-document) are user-triggered and never produce scheduled Works. They show as `no_works` and won't get auto-restarted unless they actually break

## Files Used

```
/var/lib/opencti-health/<service>.count     Restart counter per service
/var/lib/opencti-health/<service>.ingest    Ingestion state per connector
/var/log/opencti-health.log                 Run log (per-cron-cycle output)
/etc/crontab                                Cron entry (after --install-cron)
```

## Cron Entry Format

`--install-cron` adds this line to `/etc/crontab`:

```
*/15 * * * * root /path/to/health-check.sh >/dev/null 2>&1
```

Stdout/stderr go to `/dev/null` because the script writes everything to its own log file. Verify with:

```bash
sudo grep opencti-health /etc/crontab
sudo tail -f /var/log/opencti-health.log
```
