# `add-connector.sh` - Deep Dive

Connector deployment without manual YAML editing. Built-in template library plus custom YAML injection. Auto UUID generation, compose validation, log tailing.

## Usage

```bash
# Built-in templates
sudo ./add-connector.sh --template alienvault --api-key YOUR_OTX_KEY
sudo ./add-connector.sh --template threatfox  --api-key YOUR_ABUSE_CH_KEY
sudo ./add-connector.sh --template mitre

# List available built-in templates
sudo ./add-connector.sh --list

# Deploy a custom template from a YAML file
sudo ./add-connector.sh --file ./examples/mitre-atlas.yaml

# Custom template that needs an API key
sudo ./add-connector.sh --file ./my-connector.yaml --api-key SECRET

# Remove a deployed connector
sudo ./add-connector.sh --remove connector-alienvault
```

## Built-in Templates

| Template | Connector | Auth | Notes |
|---|---|---|---|
| `alienvault` | AlienVault OTX | Required | OTX API key from your account at [otx.alienvault.com](https://otx.alienvault.com/) |
| `mitre` | MITRE ATT&CK | None | Note: upstream compose may already include this - check before adding |
| `abuseipdb` | AbuseIPDB | Required | IP enrichment connector. Free tier available |
| `threatfox` | ThreatFox (abuse.ch) | Required | Auth key from [auth.abuse.ch](https://auth.abuse.ch/) - mandatory since 2024 |
| `urlhaus` | URLhaus (abuse.ch) | Required | Same auth.abuse.ch key as ThreatFox |
| `misp` | MISP feed | Required | Edit `MISP_URL` in the compose after deploy |
| `tweetfeed` | TweetFeed | None | IOCs scraped from Twitter |

## How Substitution Works

Templates contain three placeholder tokens that get replaced at deploy time:

- `__OPENCTI_TOKEN__` - read from `/opt/opencti/.env` (`OPENCTI_ADMIN_TOKEN`)
- `__UUID__` - freshly generated via `uuidgen` for each deploy
- `__API_KEY__` - passed via `--api-key` on the command line

The script:
1. Loads the template (built-in or `--file`)
2. Substitutes the tokens
3. Detects the service name (first `^  servicename:` line)
4. Refuses to proceed if the service name already exists in the compose file
5. Backs up the existing compose
6. Injects the rendered block at the end of the `services:` section
7. Validates with `docker compose config`
8. Restores the backup if validation fails
9. Starts the connector
10. Tails logs for 30 seconds so you see it register and start working

## What a Template Looks Like

Minimal external-import connector template:

```yaml
  connector-example:
    image: opencti/connector-example:6.8.12
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=__OPENCTI_TOKEN__
      - CONNECTOR_ID=__UUID__
      - CONNECTOR_TYPE=EXTERNAL_IMPORT
      - CONNECTOR_NAME=Example
      - CONNECTOR_SCOPE=example
      - CONNECTOR_LOG_LEVEL=info
      - EXAMPLE_API_KEY=__API_KEY__
      - EXAMPLE_INTERVAL_SEC=1800
    restart: always
    depends_on:
      opencti:
        condition: service_healthy
```

Two-space indentation. No `services:` wrapper - the script injects under the existing key.

## What Could Go Wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Service 'connector-X' already exists` | You're trying to add a connector that's already running | Remove first: `sudo ./add-connector.sh --remove connector-X` |
| `docker compose config validation failed` | Bad YAML indentation or syntax in the template | Script auto-restores backup; fix YAML and retry |
| Connector container in restart loop after deploy | Wrong env var, bad API key, or unsupported value | Check logs: `sudo docker compose logs connector-X` |
| `ValueError: Invalid TLP value 'TLP:WHITE'` | Some connectors expect lowercase, no prefix | Use `TLP=white` not `TLP=TLP:WHITE` (script's `alienvault` template already corrected) |
| `connect ECONNREFUSED 172.18.0.X:5672` | Connector raced RabbitMQ during startup | Restart: `sudo docker compose restart connector-X` |
| Connector says "Fetching..." for 30+ minutes | Slow upstream API (OTX with many subscribed pulses, MISP with large datasets) | Wait, or narrow the start date in the connector env vars |

## Template Validation Pattern

Before submitting a new template (see [CONTRIBUTING.md](../CONTRIBUTING.md)), run end-to-end:

```bash
# 1. Deploy
sudo ./add-connector.sh --file ./your-template.yaml --api-key TEST

# 2. Watch logs
sudo docker compose logs -f connector-yourname

# 3. Confirm it registers
# Look for: "Connector registered with ID"

# 4. Confirm it produces a Work
# In OpenCTI UI: Data > Ingestion > Connectors > Monitoring
# Should see Messages > 0 within an hour for scheduled connectors

# 5. Clean up
sudo ./add-connector.sh --remove connector-yourname
```

## Removal

`--remove` stops and deletes the container, then strips the service block from the compose file. Backs up the compose to `docker-compose.yml.pre-remove.<timestamp>.bak`.

```bash
sudo ./add-connector.sh --remove connector-alienvault
```

The connector's data already in OpenCTI is **not** removed - just the connector itself stops fetching new data. To clear ingested data, use the OpenCTI UI's bulk delete or rule-engine retention policies.

## Custom Connectors Library

See [`examples/`](../examples/) for ready-to-use custom YAMLs that aren't (yet) in the built-in template list:
- MITRE ATLAS (AI/ML threat matrix)
- CISA Known Exploited Vulnerabilities
- DISARM Framework (influence operations)

Add your own and submit a PR.
