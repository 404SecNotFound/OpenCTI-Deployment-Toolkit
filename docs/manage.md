# `manage.sh` - Deep Dive

Day-2 operations helper. The boring useful stuff: status, logs, lifecycle, backup, upgrade, password reset.

## Usage

```bash
sudo ./manage.sh status                       # container state + health
sudo ./manage.sh logs opencti                 # tail platform logs
sudo ./manage.sh logs worker 500              # tail worker logs, 500 lines
sudo ./manage.sh start                        # bring stack up
sudo ./manage.sh stop                         # take stack down
sudo ./manage.sh restart                      # full bounce
sudo ./manage.sh ps                           # docker compose ps
sudo ./manage.sh backup                       # stop, snapshot volumes, restart
sudo ./manage.sh upgrade 6.8.13               # bump OPENCTI_VERSION and roll
sudo ./manage.sh reset-password               # generate and apply new admin password
sudo ./manage.sh add-connector                # print template + UUID for manual paste
sudo ./manage.sh nuke                         # tear down stack and delete all data
```

## Subcommand Reference

### `status`
Runs `docker compose ps` and tests the `/health` endpoint with the access key from `.env`. Quick at-a-glance check.

### `logs <service> [tail-count]`
Tails logs for one service. Default tail count is 200 lines. Follows in real time (Ctrl+C to exit).

```bash
sudo ./manage.sh logs opencti           # 200 lines, follow
sudo ./manage.sh logs opencti 50        # last 50 lines, follow
sudo ./manage.sh logs connector-alienvault 100
```

### `start` / `stop` / `restart`
Wraps `docker compose up -d` / `down` / restart. Always operates on the full stack from `/opt/opencti`.

### `backup`
Creates a consistent point-in-time backup:

1. Stops the stack (so volumes aren't being written to during snapshot)
2. Tars the config files (`.env`, `docker-compose.yml`, `xtm-composer/`)
3. For each `opencti_*` Docker volume, runs an Alpine container that tars the volume contents
4. Restarts the stack
5. Lists the backup files in `/var/backups/`

Output looks like:

```
/var/backups/opencti-config-2026-04-30-2110.tgz       6 KB
/var/backups/opencti_amqpdata-2026-04-30-2110.tgz   400 KB
/var/backups/opencti_esdata-2026-04-30-2110.tgz     2.1 GB
/var/backups/opencti_redisdata-2026-04-30-2110.tgz   12 MB
/var/backups/opencti_rsakeys-2026-04-30-2110.tgz      4 KB
/var/backups/opencti_s3data-2026-04-30-2110.tgz     180 MB
```

**Caveat:** the backup blocks ingestion for the duration of the snapshot. For an Elasticsearch volume of 2 GB, expect 30 to 90 seconds of downtime. For production-grade backups, prefer Elasticsearch native snapshots to S3 plus MinIO mirroring.

### `upgrade <version>`
Updates `OPENCTI_VERSION` in `.env`, pulls the new images, and runs `docker compose up -d`. Prompts for confirmation first because version upgrades may include index migrations or breaking changes.

```bash
sudo ./manage.sh upgrade 6.8.13
# Asks: Read release notes between current and target before continuing. Proceed? [y/N]
```

**Always check release notes** at https://github.com/OpenCTI-Platform/opencti/releases between your current and target versions before answering yes. Major version jumps (6.x → 7.x) typically include migrations that take time and shouldn't be done casually.

### `reset-password`
Generates a fresh 22-character password, updates `OPENCTI_ADMIN_PASSWORD` in `.env`, and force-recreates the `opencti` container so the new value takes effect.

```bash
sudo ./manage.sh reset-password
# Output: New admin password: aB3kLm9PqR2sT5uV7wXy
```

The new password is also visible in `.env`. Update your password manager.

### `add-connector`
Prints a generic external-import connector template with a freshly generated UUID, ready to paste into `docker-compose.yml` if you want to add a connector by hand without using `add-connector.sh`.

This is the legacy path. Prefer `add-connector.sh --template <name>` for built-in connectors and `add-connector.sh --file <path>` for custom YAMLs.

### `nuke`
Tears down the entire stack and deletes all Docker volumes. Asks for the literal string `DELETE` to confirm.

```bash
sudo ./manage.sh nuke
# Type DELETE to confirm:
```

After running:
- All ingested CTI data is gone
- All credentials remain in `/opt/opencti/.env` (so you can reuse them)
- The stack is preserved at `/opt/opencti/`
- Re-run `docker compose up -d` to start fresh with the same config and empty volumes

This is the equivalent of "factory reset without reinstalling". Useful for testing or starting over after a bad import.

## What It Does NOT Do

- Restore from backup - intentionally manual. Restore depends on whether you want full state, just config, or selective volume restore. The README's Disaster Recovery section covers patterns
- Migrate between major OpenCTI versions - the upgrade subcommand only handles in-line image swaps, not data migrations
- Manage individual connectors - use `add-connector.sh` for that
- Health monitoring - use `health-check.sh`

## Files Touched

```
/var/backups/opencti-*.tgz                 Backup archives
/opt/opencti/.env                          Modified by upgrade and reset-password
/opt/opencti/docker-compose.yml            Read for ps/logs/lifecycle
```

## Common Workflows

### Pre-upgrade safety dance

```bash
sudo ./manage.sh backup                     # snapshot first
sudo ./manage.sh upgrade 6.8.13             # then upgrade
sudo ./manage.sh logs opencti               # watch it come up
sudo ./manage.sh status                     # confirm healthy
```

### Recover a forgotten admin password

```bash
sudo ./manage.sh reset-password
# Note the printed password
# Or read it from /opt/opencti/.env or /root/opencti-credentials.txt
```

### Check what's actually running

```bash
sudo ./manage.sh ps
sudo ./manage.sh status
```

### Fast troubleshoot loop

```bash
sudo ./manage.sh logs opencti 50
sudo ./manage.sh logs worker 50
sudo ./manage.sh logs connector-alienvault 100
```
