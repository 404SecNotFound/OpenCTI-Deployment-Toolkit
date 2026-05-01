# Security Policy

## Reporting a Vulnerability

If you discover a security issue in any script or example in this repository, please report it privately rather than opening a public issue.

**Contact:** 404securitynotfound@protonmail.ch

When reporting, include:

- A clear description of the vulnerability and its impact
- Steps to reproduce, or proof-of-concept code if relevant
- Affected scripts, file paths, or configuration files
- The OpenCTI version, Ubuntu version, and Docker version where the issue was observed
- Whether you would like public credit in the fix announcement

You should expect an acknowledgement within 5 working days. Substantive triage and a fix timeline within 14 days for most reports.

## Scope

In scope:
- Bash scripts in this repository (`*.sh`)
- Compose templates and example YAMLs
- Documentation that could lead a reader to a misconfigured or insecure deployment

Out of scope:
- Vulnerabilities in OpenCTI itself - report those to [Filigran](https://github.com/OpenCTI-Platform/opencti/security/policy)
- Vulnerabilities in upstream Docker images (Elasticsearch, RabbitMQ, MinIO, Redis, etc.) - report to those projects directly
- Issues that require pre-existing root access on the target VM

## Disclosure Approach

I follow coordinated disclosure. After a fix is available, the issue will be summarised in the changelog or release notes. Security-sensitive reporters who request anonymity will be credited generically as "an external researcher" unless they prefer otherwise.

If a vulnerability has a CVE assigned upstream (in OpenCTI, Docker, or any dependency), the relevant CVE will be referenced in the fix commit and release notes.

## Operational Security Notes for Users

These scripts are designed for lab and small-team deployments. If you adapt them for production:

- Rotate all secrets in `/opt/opencti/.env` and `/root/opencti-credentials.txt` immediately after install. The scripts generate strong randomized values, but that file should not be the single source of truth long-term.
- Replace the Caddy local CA with a real PKI before exposing the service beyond a trusted LAN.
- Review `harden.sh`'s SSH hardening and decide whether to disable password authentication entirely once key-based access is confirmed working.
- The default UFW rules allow SSH from anywhere. Tighten with `--ssh-from <CIDR>` or post-install `ufw delete <rule_number>` for your environment.
- The connector template library logs API keys to disk in `/opt/opencti/docker-compose.yml`. That file is mode 644 by default. Consider tightening to 600 if multi-user access is a concern: `sudo chmod 600 /opt/opencti/docker-compose.yml`.

## Things You Should Never Do

- Commit the `.env` file or `/root/opencti-credentials.txt` to a public repo. The included `.gitignore` covers the common filenames but does not guarantee safety if you stage by hand.
- Reuse `CONNECTOR_ID` UUIDs across connectors. The scripts auto-generate unique UUIDs - if you copy a YAML by hand, generate a fresh UUID with `uuidgen`.
- Paste raw API keys into chat windows, issue threads, or PR descriptions when asking for help. Redact before sharing.
