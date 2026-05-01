# `harden.sh` - Deep Dive

Production hardening overlay. Run after `install-opencti.sh` succeeds. Adds HTTPS, restricts internal services to localhost, configures a working firewall, and applies SSH and OS hygiene baselines.

## Usage

```bash
# Internal hostname with self-signed cert
sudo ./harden.sh --hostname cti.lab.local --local-ca

# Public hostname with Let's Encrypt
sudo ./harden.sh --hostname cti.example.com --email you@example.com

# Restrict SSH to a specific CIDR
sudo ./harden.sh --hostname cti.lab.local --local-ca --ssh-from 192.168.1.0/24

# Skip fail2ban if you have your own brute-force protection
sudo ./harden.sh --hostname cti.lab.local --local-ca --no-fail2ban
```

## What It Does, In Order

### 1. Pre-flight
- Verifies root and that `/opt/opencti` exists
- Resolves the cert mode automatically:
  - `--local-ca` flag → Caddy local CA
  - Hostname matching `*.local`, `*.lan`, `*.internal`, `*.test`, or `localhost` → Caddy local CA
  - Anything else → Let's Encrypt (requires `--email`)

### 2. Compose Port Bindings
Rewrites published ports for these services to `127.0.0.1` only:
- `opencti` (UI)
- `minio` (S3 admin and API)
- `rabbitmq` (management UI)
- `redis`
- `elasticsearch`

Backs up the original to `docker-compose.yml.pre-harden.<timestamp>.bak`. Other services (workers, connectors, etc.) are left untouched.

### 3. Update `.env` for Reverse Proxy
Sets `OPENCTI_BASE_URL=https://<hostname>` so dissemination links, SSO callbacks, and webhooks resolve correctly when accessed via Caddy. **Does not** touch `OPENCTI_PORT` (which drives the host-side port binding) - that stays at 8080 internally.

### 4. Caddy Install
Installs Caddy from the official Cloudsmith APT repo. Writes a Caddyfile that:
- Reverse-proxies `https://<hostname>` to `127.0.0.1:8080`
- Adds standard security headers (HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy)
- Strips the `Server: ` header
- Compresses responses with gzip and zstd
- Logs JSON access logs to `/var/log/caddy/opencti-access.log` with rotation
- Issues a self-signed cert from Caddy's local CA, OR obtains a Let's Encrypt cert automatically, depending on cert mode

### 5. UFW + Docker Integration
- Default deny incoming, allow outgoing
- Allow SSH (22), HTTP (80), HTTPS (443 TCP and UDP for HTTP/3)
- Optional `--ssh-from <CIDR>` to restrict SSH to a specific network
- Writes the chaifeng/ufw-docker rules into `/etc/ufw/after.rules` so the `DOCKER-USER` chain enforces UFW rules on container traffic

This is the critical gap most guides miss. Without these rules, Docker bypasses UFW entirely and your container ports are reachable regardless of `ufw status`.

### 6. SSH Hardening
Drops `/etc/ssh/sshd_config.d/99-opencti-harden.conf` with:
- `PermitRootLogin no`
- `MaxAuthTries 4`
- `LoginGraceTime 30`
- `ClientAliveInterval 300` / `ClientAliveCountMax 2`
- `AllowAgentForwarding no` / `AllowTcpForwarding no`
- `X11Forwarding no`

`PasswordAuthentication` is left enabled by default. **Switch it to `no` once you confirm key-based login works** - the script reminds you in its summary output.

### 7. Unattended Security Upgrades
Installs `unattended-upgrades` and `apt-listchanges`. Configures auto-install for security-only updates (Ubuntu's default channel restriction).

### 8. fail2ban
Default jail enabled for sshd: 5 failures in 10 minutes triggers a 1-hour ban. Backed by systemd journal as the log source.

### 9. Restart and Verify
- `docker compose down` and `up -d` to apply the new bindings
- Polls Caddy's HTTPS endpoint for up to 5 minutes
- Logs success or prints debugging hints

## Caddy Local CA - How to Trust It

If you used `--local-ca`, your browsers will throw cert warnings until they trust Caddy's root. Two paths:

### Trust on Linux clients

```bash
# On the OpenCTI VM:
sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt

# Copy that PEM block, paste it into a file on your Linux client:
sudo cp caddy-root.crt /usr/local/share/ca-certificates/caddy-opencti.crt
sudo update-ca-certificates
```

### Trust on macOS

```bash
# Pull the cert via SCP, then:
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt
```

### Trust on Windows

```powershell
# As Administrator, after copying caddy-root.crt to the Windows machine:
Import-Certificate -FilePath C:\path\to\caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root
```

After trusting on each client, `https://cti.lab.local` shows a green padlock.

## What Could Go Wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Job for caddy.service failed` with permission denied on log file | Caddy user didn't exist when log dir was created | `sudo chown -R caddy:caddy /var/log/caddy && sudo systemctl start caddy` |
| `address already in use` on port 443 | Another service (Apache, nginx, or stale Caddy) is bound | `sudo ss -tlnp \| grep ':443'` to find the offender, stop it, then start Caddy |
| `failed to bind host port 0.0.0.0:443` from OpenCTI | Earlier `harden.sh` versions overwrote `OPENCTI_PORT` to 443 | Set `OPENCTI_PORT=8080` in `.env` and `OPENCTI_BASE_URL=https://<hostname>` directly |
| Caddy shows `tls.obtain: ... no matching DNS records` | Public hostname doesn't resolve to the VM's public IP | Either fix DNS or switch to `--local-ca` |
| `needrestart` blocks the script mid-install | Ubuntu 22.04 default | Script v2+ exports `NEEDRESTART_MODE=a`; if older version, run with `sudo NEEDRESTART_MODE=a bash harden.sh ...` |

## What `harden.sh` Does NOT Do

- Configure SSO (OIDC / SAML) - that's an OpenCTI UI / EE feature
- Set up off-host backups - use `manage.sh backup` as a starting point
- Forward logs to a SIEM - Caddy logs are JSON ready, hook them into your shipper
- Cluster the platform - this targets single-VM deployments
- Run a managed certificate authority - Caddy local CA is convenient, not enterprise PKI

## Files Created or Modified

```
/etc/caddy/Caddyfile                                Caddy config
/etc/ufw/after.rules                                UFW + Docker integration
/etc/ssh/sshd_config.d/99-opencti-harden.conf       SSH hardening drop-in
/etc/apt/apt.conf.d/20auto-upgrades                 Unattended security upgrades
/etc/fail2ban/jail.d/opencti.conf                   fail2ban sshd jail
/var/log/caddy/opencti-access.log                   Caddy access log (JSON)
/var/log/opencti-harden.log                         Hardening run log
/opt/opencti/.env.pre-harden.*.bak                  Pre-harden .env backup
/opt/opencti/docker-compose.yml.pre-harden.*.bak    Pre-harden compose backup
/var/lib/caddy/.local/share/caddy/pki/...           Caddy local CA root cert (when --local-ca)
```

## Re-run Safety

Idempotent on most steps. Re-running with the same args:
- Skips Caddy install (already present)
- Re-validates and reloads Caddyfile
- Re-applies UFW rules (idempotent on the kernel side)
- Skips fail2ban install if already there

Re-running with a **different** hostname or cert mode rewrites the Caddyfile and `.env` cleanly.
