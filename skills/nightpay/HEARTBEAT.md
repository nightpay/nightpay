# NightPay heartbeat checklist

Use this file for OpenClaw heartbeat runs.

If nothing needs attention, reply exactly: `HEARTBEAT_OK`

## Automated runner

The same checks are implemented in code (stateful: consecutive API failures, `active_jobs` deltas, once-per-24h skill version probe):

```bash
# From a repo or post-`npx nightpay init` tree:
bash skills/nightpay/scripts/heartbeat.sh

# Or via npm (sets NIGHTPAY_SKILL_ROOT when needed):
npx nightpay heartbeat
```

Options: `python3 skills/nightpay/scripts/heartbeat.py --selftest` (offline sanity).

State file default: `$XDG_STATE_HOME/nightpay/heartbeat-state.json` (or `~/.local/state/...`). Override with `NIGHTPAY_HEARTBEAT_STATE`.

## Objective

Keep NightPay operator and agent flows healthy without spamming.
Only report new or actionable changes.

## Rules

- Do not repeat old alerts from earlier heartbeats.
- Do not invent tasks from stale chat context.
- If a check fails once, retry next heartbeat before escalating.
- If all checks are green and no new action exists, return `HEARTBEAT_OK`.

## Checks (in order)

1) API availability
- Check `GET ${NIGHTPAY_API_URL:-https://api.nightpay.dev}/availability`
- If status is not available or endpoint is down for 2 consecutive heartbeats, alert.

2) Ontology & Knowledge Graph health
- Check `GET ${NIGHTPAY_API_URL:-https://api.nightpay.dev}/ontology`
- If the JSON-LD context is unreachable, agents lose navigation capabilities. Alert if down.

3) Bridge health (when bridge is configured)
- If `BRIDGE_URL` is set, check `GET ${BRIDGE_URL%/}/health`
- Alert on non-200, `initError`, or unexpected network switch.
- If `stub: true`, send info-level notice only (not urgent).

4) Work queue signal
- Compare `active_jobs` from `/availability` to previous heartbeat state.
- Alert only when:
  - `active_jobs` increases from 0 to >0, or
  - `active_jobs` jumps significantly (>= +5 since last check).

5) Daily skill freshness (once per 24h)
- Check `https://raw.githubusercontent.com/nightpay/nightpay/master/skills/nightpay/SKILL.md`
- If `metadata.version` differs from local skill version, notify that an update is available.

6) Deadline radar (per run)
- Query `GET ${NIGHTPAY_API_URL}/jobs?status=running&limit=50` and derive per-job timers
  from `started_at` + `approved_at` combined with policy windows published by
  `gateway.sh schedule` (`escrow_timeout_minutes`, `optimistic_approval_hours`,
  `unclaimed_refund_hours`, vote window from `/submissions/<job_id>` when present).
- Alert when any timer crosses **6h** or **1h** remaining, or when a timer has
  **expired** (e.g. escrow timeout, optimistic autocomplete, unclaimed refund).
- Suppress duplicate notifications: state file records `{job_id, timer, bucket}`
  so the same "<6h" alert fires at most once per bucket per job.
- Also reports the Midnight mainnet (Kūkolu) milestone once within **30 days**
  of `MIDNIGHT_MAINNET_DATE` (default `2026-03-30T00:00:00Z`).

## Alert format

When alerting, keep it short:
- What changed
- Why it matters
- Suggested next action

If multiple alerts exist, order by severity:
1. service down
2. bridge/init issues
3. new work spikes
4. version update
5. deadline radar (expired timers > 1h window > 6h window)
