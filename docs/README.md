# Documentation

Per-script deep dives, design rationale, and operational notes.

## Scripts

| Doc | Covers |
|---|---|
| [install.md](install.md) | `install-opencti.sh` - bootstrap installer, VM profiles, tuning, secrets generation |
| [harden.md](harden.md) | `harden.sh` - HTTPS via Caddy, UFW + Docker integration, SSH and OS hygiene |
| [add-connector.md](add-connector.md) | `add-connector.sh` - template-driven connector deployment, custom YAMLs |
| [manage.md](manage.md) | `manage.sh` - day-2 ops: status, logs, backup, upgrade, password reset |
| [health-check.md](health-check.md) | `health-check.sh` - cron health monitor, GraphQL ingestion stall detection |

## Design Topics

- [LESSONS-LEARNED.md](../LESSONS-LEARNED.md) - real deployment issues and the fixes baked into the scripts
- [README.md](../README.md) - overview, quick start, audience signal

## See Also

- [examples/](../examples/) - custom connector YAMLs
- [SECURITY.md](../SECURITY.md) - vulnerability reporting policy
- [CONTRIBUTING.md](../CONTRIBUTING.md) - how to contribute
- [CHANGELOG.md](../CHANGELOG.md) - version history
