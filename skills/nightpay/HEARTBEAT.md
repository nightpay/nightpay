# NightPay heartbeat checklist

Use this file for OpenClaw heartbeat runs.

If nothing needs attention, reply exactly: `HEARTBEAT_OK`

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
