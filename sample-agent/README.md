# sample-agent

Minimal NightPay operator agent in a separate local environment.

This folder is isolated from `.agent-playground.env` and uses only `sample-agent/.env`.
It validates the three integration surfaces before posting:

- `Lace/Midnight operator wiring`: `GET /operator-address` from bridge and compare to `OPERATOR_ADDRESS`
- `Midnight bridge`: `GET /health`
- `Cardano settlement path via Masumi`: payment and registry health endpoints

## Quick start

```bash
# one-click onboarding (auto-import envs, start Masumi if possible,
# sync/deploy addresses, then run doctor)
bash sample-agent/agent.sh onboard

# optional: keep onboarding read-only
bash sample-agent/agent.sh onboard --no-start-masumi --no-start-bridge --no-deploy
```

Manual flow is still available:

```bash
bash sample-agent/agent.sh init
bash sample-agent/agent.sh sync-addresses
bash sample-agent/agent.sh doctor
```

If your bridge does not expose contract address in `/health`, use:

```bash
bash sample-agent/agent.sh sync-addresses --deploy-if-missing
```

That calls `POST /deploy` (requires `BRIDGE_ADMIN_TOKEN`) and writes the returned contract address into `sample-agent/.env`.

## Post a bounty

```bash
# safer: provide description via stdin prompt (not in shell history)
bash sample-agent/agent.sh post 250000

# or explicit
bash sample-agent/agent.sh post 250000 --desc "Review CIP draft and summarize risks"

# run full readiness checks (bridge + operator address + Masumi) before posting
bash sample-agent/agent.sh post-checked 250000
```

This command calls `skills/nightpay/scripts/gateway.sh post-bounty` using the isolated env.
