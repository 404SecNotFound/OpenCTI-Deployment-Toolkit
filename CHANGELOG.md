# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-30

### Added
- `install-opencti.sh` - bootstrap installer with profile-based VM tuning
- `harden.sh` - production hardening overlay (Caddy, UFW, SSH, fail2ban)
- `add-connector.sh` - template-driven connector deployment with built-in library
- `manage.sh` - day-2 operations helper
- `health-check.sh` - cron-driven health monitor with ingestion stall detection
- Built-in connector templates: AlienVault, MITRE ATT&CK, AbuseIPDB, ThreatFox, URLhaus, MISP, TweetFeed
- Example custom connectors: MITRE ATLAS, CISA KEV, DISARM Framework
- Documentation: README, LESSONS-LEARNED, per-script deep dives in `docs/`
- `SECURITY.md`, `CONTRIBUTING.md`, `LICENSE`

### Fixed (vs upstream defaults)
- Connector UUID drift: scripts auto-discover all `CONNECTOR_*_ID` references and generate fresh UUIDs
- Worker scaling race: install waits for platform health before scaling workers
- Docker-UFW bypass: hardening writes ufw-docker rules to `/etc/ufw/after.rules`
- Internal service exposure: hardening rebinds MinIO, RabbitMQ, ES, Redis to `127.0.0.1`
- Caddy port collision: `harden.sh` doesn't overwrite `OPENCTI_PORT`, only sets `OPENCTI_BASE_URL`
- needrestart blocking: all scripts export `NEEDRESTART_MODE=a` and `DEBIAN_FRONTEND=noninteractive`
- AlienVault TLP value: template uses lowercase `white` (connector rejects `TLP:WHITE` and `TLP:CLEAR`)

[Unreleased]: https://github.com/404SecNotFound/OpenCTI-Deployment-Toolkit/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/404SecNotFound/OpenCTI-Deployment-Toolkit/releases/tag/v1.0.0
