# NightPay.dev Completion Sync Runbook (Working Path Only)

Validated on: **March 14, 2026**

Purpose: keep agent-visible job completion reliable after updates.  
Target behavior: when operator runs `gateway.sh complete`, agents polling `GET /status/<job_id>` see `internal_status: completed`.

## Scope

Use this runbook when touching:
- `skills/nightpay/scripts/mip003-server.sh`
- `skills/nightpay/scripts/gateway.sh`
- `skills/nightpay/openclaw-fragment.json`
- API/docs around completion and status auth

## Patch Order (repeat exactly)

1. In `mip003-server.sh`, ensure `do_POST` parses query params:
```python
params = parse_qs(parsed.query)
```

2. In `mip003-server.sh`, protect private job status:
- If job visibility is private/hidden, `GET /status/<job_id>` must require:
  - `Authorization: Bearer <job_token>`, or
  - operator bearer auth.
- No-auth call must return `403`.

3. In `mip003-server.sh`, add operator-only completion endpoint:
- `POST /complete_job/<job_id>` (and query variant `?job_id=...`).
- Validate `job_id`.
- Require operator bearer auth.
- Accept settlement metadata (`receiptHash`, `outputHash`, `midnightTxId`, `onChain`).
- Persist result settlement fields.
- Transition status to `completed`.
- Emit `completed` status event.

4. In `gateway.sh` `complete` command, stop localhost assumptions:
- Derive `MIP003_BASE="${MIP003_URL%/}"`.
- Replace all status/economics reads from `http://localhost:${MIP003_PORT}` to `${MIP003_BASE}`.

5. In `gateway.sh` `complete` command, sync MIP final state:
- After completion hash/bridge path, call:
```bash
POST ${MIP003_BASE}/complete_job/${JOB_ID}
Authorization: Bearer ${OPERATOR_SECRET_KEY}
```
- Send settlement payload with receipt/output hash and tx/onChain metadata.
- Return `mipStatusSync` block in gateway JSON output.

6. In `openclaw-fragment.json`, do not ship `OPERATOR_SECRET_KEY` in general worker-agent env defaults.

## Worked Verification Sequence

Run in this order.

### 1) Syntax checks

```bash
bash -n skills/nightpay/scripts/gateway.sh
bash -n skills/nightpay/scripts/mip003-server.sh
```

### 2) API behavior checks (must pass)

1. Start a private job.
2. `GET /status/<job_id>` without auth returns `403`.
3. `GET /status/<job_id>` with `Authorization: Bearer <job_token>` returns `200`.
4. `POST /provide_input?job_id=<job_id>` with job token returns `200`.
5. `POST /complete_job/<job_id>` with operator bearer returns `200`.
6. `GET /status/<job_id>` with job token returns `internal_status=completed`.

Expected pass line from focused check:
```text
CODE_HIDDEN=403 CODE_AUTH=200 CODE_QUERY=200 CODE_COMPLETE=200 INTERNAL_AFTER=completed
```

### 3) Gateway integration check (must pass)

1. Set gateway env to use API base:
```bash
export MIP003_URL="https://api.nightpay.dev"
```
2. Run:
```bash
bash skills/nightpay/scripts/gateway.sh complete <job_id> <commitment_hash>
```
3. Confirm gateway output contains:
- `mipStatusSync.ok: true`
- `mipStatusSync.state: "completed"` (or equivalent completed state)
4. Confirm API status still returns `internal_status=completed`.

Expected pass line from focused check:
```text
SYNC_OK=True FINAL=completed
```

## NightPay.dev Deploy Checklist (post-patch)

1. Deploy updated `mip003-server.sh` to `api.nightpay.dev`.
2. Deploy updated `gateway.sh` where operator automation runs.
3. Ensure operator runtime has:
- `MIP003_URL=https://api.nightpay.dev`
- `OPERATOR_SECRET_KEY=<operator-secret>`
4. Keep `OPERATOR_SECRET_KEY` out of broad OpenClaw worker-agent env.
5. Run the API and gateway integration checks above against deployed endpoints.

## Done Criteria

All must be true:
- private status auth works (`403` without token, `200` with token)
- query-mode input endpoint works (`POST /provide_input?job_id=...`)
- operator completion endpoint works (`POST /complete_job/<job_id>`)
- gateway complete reports successful MIP sync
- agent poll sees `internal_status=completed`

