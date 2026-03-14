# Installation Troubleshooting

Quick reference for NightPay installation issues. For the full onboarding guide,
see [OPENCLAW_ONBOARDING.md](./OPENCLAW_ONBOARDING.md).

## Decision Tree

```
Is SKILL.md at workspace/skills/nightpay/SKILL.md?
  NO  --> Did you git clone? --> Flatten: cp -r skills/nightpay/* .
  YES --> Is \`openclaw config validate\` passing?
            NO  --> Check JSON syntax, restore from .bak if needed
            YES --> Are env vars set to real values (not placeholders)?
                      NO  --> openclaw config set skills.entries.nightpay.env.<KEY> <VALUE>
                      YES --> Is the agent bound to a channel?
                                NO  --> openclaw agents bind nightpay <channel> <target>
                                YES --> Check gateway logs: openclaw logs --follow
```

## Error → Fix Table

| Symptom | Likely Cause | Fix |
|---|---|---|
| Skill does not activate on "bounty" keyword | SKILL.md not at expected path | Flatten step (see onboarding guide) |
| \`openclaw config validate\` fails after adding agent | Malformed JSON from manual edit | Restore backup, re-add carefully |
| Scripts return "permission denied" | Not chmod'd after clone | \`chmod +x scripts/*.sh\` |
| Agent sends placeholder text instead of calling API | Env vars still set to key names | Replace all 9 env vars with real values |
| \`openclaw agents add\` freezes in CI | Interactive-only TUI | Add agent via JSON (see onboarding guide) |
| gateway.sh returns "connection refused" | NIGHTPAY_API_URL pointing to localhost | Set to deployed URL (https://api.nightpay.dev) |
| "Unknown agent" in Masumi | Not registered via MIP-003 | Run \`scripts/mip003-server.sh\` and register |
| Bridge health check fails | BRIDGE_URL not set or wrong | Verify with \`curl $BRIDGE_URL/health\` |
| ZK receipt verification fails | Wrong RECEIPT_CONTRACT_ADDRESS | Check operator for correct 64-char hex |
| Double-flatten creates duplicate dirs | Ran cp -r twice | Safe — idempotent, just overwrites |

## Quick Health Check Script

```bash
#!/usr/bin/env bash
# nightpay-health.sh — run after installation to verify everything
set -euo pipefail

WORKSPACE="${1:-\$HOME/.openclaw/workspace-nightpay}"
SKILL_DIR="\$WORKSPACE/skills/nightpay"
ERRORS=0

check() {
  if eval "\$2" >/dev/null 2>&1; then
    echo "  PASS  \$1"
  else
    echo "  FAIL  \$1"
    ((ERRORS++))
  fi
}

echo "NightPay Installation Health Check"
echo "==================================="
echo ""

check "SKILL.md exists"        "test -f \$SKILL_DIR/SKILL.md"
check "gateway.sh executable"  "test -x \$SKILL_DIR/scripts/gateway.sh"
check "openclaw config valid"  "openclaw config validate"
check "nightpay agent exists"  "openclaw agents list --json | python3 -c 'import sys,json; assert any(a[\"id\"]==\"nightpay\" for a in json.load(sys.stdin))'"
check "skill entry in config"  "openclaw config get skills.entries.nightpay.enabled | grep -q true"
check "ontology files present" "test -f \$SKILL_DIR/ontology/ontology.jsonld"
check "rules files present"    "test -f \$SKILL_DIR/rules/privacy-first.md"

echo ""
if [ "\$ERRORS" -eq 0 ]; then
  echo "All checks passed. NightPay is ready."
else
  echo "\$ERRORS check(s) failed. See docs/OPENCLAW_ONBOARDING.md for fixes."
fi
exit \$ERRORS
```

Save as \`scripts/nightpay-health.sh\` and run:

```bash
chmod +x scripts/nightpay-health.sh
./scripts/nightpay-health.sh
```
