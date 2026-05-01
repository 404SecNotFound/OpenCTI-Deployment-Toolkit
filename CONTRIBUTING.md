# Contributing

Thanks for considering a contribution. This toolkit gets better when practitioners share what breaks for them and what they had to fix.

## Ways to Contribute

- **Report a bug** - open an Issue with reproduction steps, OpenCTI version, Ubuntu version, and the script output
- **Add a new connector template** - the highest-impact contribution; see [Adding a Connector Template](#adding-a-connector-template) below
- **Fix documentation** - typos, broken links, outdated commands, missing context
- **Improve script logic** - edge cases, better error handling, broader OS support
- **Share a Lessons-Learned entry** - if you hit a deployment issue not in [LESSONS-LEARNED.md](LESSONS-LEARNED.md), a PR adding it helps the next person

## Before You Open a PR

1. Run your changed scripts on a fresh Ubuntu 22.04 or 24.04 VM end-to-end
2. Run `shellcheck` on any modified shell scripts and fix all warnings
3. Update [README.md](README.md) and [LESSONS-LEARNED.md](LESSONS-LEARNED.md) if behaviour changed
4. Keep commits focused. One logical change per PR. Easier to review, easier to revert if needed

## Style Guidelines

### Bash

- `set -euo pipefail` at the top of every script (or `set -uo pipefail` if you need to allow non-zero exits with explicit handling)
- Functions named in `snake_case`
- Variables in `UPPER_CASE` for globals, `lower_case` for locals
- Use `local` for all function-scope variables
- Quote all variable expansions: `"$var"` not `$var`
- Prefer `[[ ... ]]` over `[ ... ]` for tests
- Use `printf` over `echo -e` for portability

### Comments

- Block comments at the top of every function explain what it does and why
- Inline comments only when the code itself doesn't make intent obvious
- No commented-out code in committed files

### Output

- Use the existing `log`, `warn`, `err`, `info` helpers - don't invent new ones
- One log line per logical event
- No emoji in script output (some terminals mangle them)

## Adding a Connector Template

The most useful PRs add new connector templates to `add-connector.sh`.

To add a template:

1. Find the connector's official Docker image and required env vars in [Filigran's connector list](https://github.com/OpenCTI-Platform/connectors)
2. Open `add-connector.sh` and find the `get_template()` function
3. Add a new `case` block following the existing pattern. Use `__OPENCTI_TOKEN__`, `__UUID__`, and `__API_KEY__` as placeholders - the script substitutes them automatically
4. Add the template name to the `--list` output earlier in the script
5. Test it end-to-end: `sudo ./add-connector.sh --template your_new_one --api-key TEST_KEY`
6. Confirm the connector appears in OpenCTI UI under Data → Ingestion → Connectors and produces a Work entry
7. Document any quirks in [LESSONS-LEARNED.md](LESSONS-LEARNED.md) under "Connector issues" - especially things like TLP value formats, mandatory auth, rate limits

## Pull Request Process

1. Fork the repo
2. Create a branch from `main` with a descriptive name: `add-recordedfuture-connector`, `fix-rabbitmq-healthcheck-race`, etc.
3. Make your changes
4. Push to your fork and open a PR against `main`
5. Fill out the PR description: what changed, why, how it was tested
6. Be ready to iterate on review feedback

## Issue Etiquette

When opening an issue:

- **Bug reports:** include the script you ran, the exact command, the full output, and the OpenCTI/Ubuntu/Docker versions
- **Feature requests:** describe the problem you're trying to solve, not just the feature you want
- **Questions:** check [LESSONS-LEARNED.md](LESSONS-LEARNED.md) first; it covers most common stumbles

Avoid:

- Vague reports ("doesn't work")
- Pasting raw API keys, tokens, or credentials into issue threads (redact first)
- Using issues for general OpenCTI questions - those belong on [OpenCTI's own issue tracker](https://github.com/OpenCTI-Platform/opencti/issues) or community channels

## Code of Conduct

Be civil. Disagree about technical things, not people. Assume good faith from the other side. If you see harassment, report it via the email in [SECURITY.md](SECURITY.md).

## License of Contributions

By submitting a PR, you agree your contribution is licensed under the same MIT license as the rest of the repository.
