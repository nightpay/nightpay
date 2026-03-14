# Contributing to NightPay

Thanks for your interest in contributing to NightPay! This guide will help you
get started with the development workflow.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/nightpay/nightpay.git
cd nightpay

# The actual OpenClaw skill lives inside skills/nightpay/
# For development, work directly in that directory
ls skills/nightpay/
```

## Project Structure

```
nightpay/
  README.md                    # Project overview + quick start
  package.json                 # Package metadata
  docs/                        # Extended documentation
    OPENCLAW_ONBOARDING.md     # Step-by-step OpenClaw agent onboarding guide
    INSTALL_TROUBLESHOOTING.md # Decision tree + error table for debugging installs
    ...
  skills/
    nightpay/                  # The actual OpenClaw skill
      SKILL.md                 # Skill definition (required by OpenClaw)
      scripts/                 # Shell scripts (gateway, health checks)
      rules/                   # Business rules and validation
      ontology/                # Domain ontology files
      openclaw-fragment.json   # Config fragment for merging into openclaw.json
```

## Documentation

| Document | Purpose |
|---|---|
| `README.md` | Project overview and quick start |
| `docs/OPENCLAW_ONBOARDING.md` | Full onboarding walkthrough (written from a real install session) |
| `docs/INSTALL_TROUBLESHOOTING.md` | Decision tree, error table, and health check script |

## Development Workflow

1. **Fork** the repo and create a feature branch from `master`
2. Make your changes
3. Test locally with OpenClaw (see onboarding guide)
4. Submit a PR with a clear description of what changed and why

## Areas Where Help Is Needed

- **Installation automation** — `clawhub install` is great, but raw `git clone` installs have friction. Improvements to the flatten step or a post-clone setup script would help.
- **Non-interactive agent setup** — `openclaw agents add` requires a TUI. A `--non-interactive` flag or a setup script that writes the config entry directly would be valuable.
- **Testing** — Integration tests for the MIP-003 payment flow, gateway scripts, and ontology validation.
- **Documentation** — Always welcome. If you install NightPay and hit something not covered in the docs, please open a PR or issue.

## Reporting Issues

Found a bug or have a suggestion? [Open an issue](https://github.com/nightpay/nightpay/issues) with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, OpenClaw version, Node version)

## Code of Conduct

Be respectful, be constructive, and remember that everyone is here to build
something useful. We're all figuring this out together.

## License

By contributing, you agree that your contributions will be licensed under the
same [Apache 2.0 License](LICENSE) that covers the project.
