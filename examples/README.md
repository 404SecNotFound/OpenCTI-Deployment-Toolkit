# Custom Connector Examples

Working YAML templates for connectors not in `add-connector.sh`'s built-in list. Use them with the `--file` flag.

## Available Examples

| File | Connector | Notes |
|---|---|---|
| `mitre-atlas.yaml` | MITRE ATLAS | AI/ML adversarial threat matrix - separate from ATT&CK |
| `cisa-kev.yaml` | CISA Known Exploited Vulnerabilities | Refreshes every 2 hours, no API key needed |
| `disarm-framework.yaml` | DISARM Framework | Influence operations and disinformation TTPs |

## How to Use

```bash
sudo ./add-connector.sh --file ./examples/mitre-atlas.yaml
```

The script substitutes `__OPENCTI_TOKEN__` and `__UUID__` automatically. If the YAML has `__API_KEY__` placeholders, pass `--api-key YOUR_KEY` on the command line.

## Writing Your Own

1. Find the connector image and required env vars in [Filigran's connectors repo](https://github.com/OpenCTI-Platform/connectors)
2. Wrap with **two-space indentation** (the script injects under existing `services:`)
3. Use placeholder tokens: `__OPENCTI_TOKEN__`, `__UUID__`, `__API_KEY__`
4. Always include `restart: always` and `depends_on: opencti: condition: service_healthy`
5. Set `OPENCTI_URL=http://opencti:8080`

## Submitting

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to PR a new template.
