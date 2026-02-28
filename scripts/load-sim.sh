#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/load-sim.sh [options]

Options:
  --base-url <url>                 MIP-003 base URL (default: http://127.0.0.1:8090)
  --jobs-per-round <n>             Jobs created per round (default: 100)
  --rounds <n>                     Number of rounds (default: 1, ignored with --continuous)
  --continuous                     Run rounds forever until interrupted
  --sleep-seconds <n>              Sleep between rounds (default: 2)
  --job-workers <n>                Parallel workers processing jobs (default: 20)
  --task-agent-count <n>           Logical task-generator agents (default: 100)
  --worker-agent-count <n>         Logical worker agents (default: 300)
  --voter-agent-count <n>          Logical voter agents (default: 300)
  --claim-attempts-per-job <n>     Claim attempts per job (default: 12)
  --max-agents-per-job <n>         Contest claim cap per job (default: 5)
  --min-votes-to-select <n>        Minimum votes required to select winner (default: 3)
  --votes-per-submission <n>       Votes cast per submission (default: 3)
  --amount-specks <n>              Job amount for economics (default: 50000)
  --timeout-seconds <n>            HTTP timeout per request (default: 10)
  --seed <n>                       Deterministic seed (default: random)
  -h, --help                       Show this help

Examples:
  bash scripts/load-sim.sh
  bash scripts/load-sim.sh --continuous --sleep-seconds 1
  bash scripts/load-sim.sh --jobs-per-round 200 --job-workers 40 --max-agents-per-job 5
EOF
}

BASE_URL="http://127.0.0.1:8090"
JOBS_PER_ROUND=100
ROUNDS=1
CONTINUOUS=0
SLEEP_SECONDS=2
JOB_WORKERS=20
TASK_AGENT_COUNT=100
WORKER_AGENT_COUNT=300
VOTER_AGENT_COUNT=300
CLAIM_ATTEMPTS_PER_JOB=12
MAX_AGENTS_PER_JOB=5
MIN_VOTES_TO_SELECT=3
VOTES_PER_SUBMISSION=3
AMOUNT_SPECKS=50000
TIMEOUT_SECONDS=10
SEED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --jobs-per-round) JOBS_PER_ROUND="${2:-}"; shift 2 ;;
    --rounds) ROUNDS="${2:-}"; shift 2 ;;
    --continuous) CONTINUOUS=1; shift 1 ;;
    --sleep-seconds) SLEEP_SECONDS="${2:-}"; shift 2 ;;
    --job-workers) JOB_WORKERS="${2:-}"; shift 2 ;;
    --task-agent-count) TASK_AGENT_COUNT="${2:-}"; shift 2 ;;
    --worker-agent-count) WORKER_AGENT_COUNT="${2:-}"; shift 2 ;;
    --voter-agent-count) VOTER_AGENT_COUNT="${2:-}"; shift 2 ;;
    --claim-attempts-per-job) CLAIM_ATTEMPTS_PER_JOB="${2:-}"; shift 2 ;;
    --max-agents-per-job) MAX_AGENTS_PER_JOB="${2:-}"; shift 2 ;;
    --min-votes-to-select) MIN_VOTES_TO_SELECT="${2:-}"; shift 2 ;;
    --votes-per-submission) VOTES_PER_SUBMISSION="${2:-}"; shift 2 ;;
    --amount-specks) AMOUNT_SPECKS="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_positive_int() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: $name must be a non-negative integer" >&2; exit 1; }
}

require_positive_int "$JOBS_PER_ROUND" "jobs-per-round"
require_positive_int "$ROUNDS" "rounds"
require_positive_int "$SLEEP_SECONDS" "sleep-seconds"
require_positive_int "$JOB_WORKERS" "job-workers"
require_positive_int "$TASK_AGENT_COUNT" "task-agent-count"
require_positive_int "$WORKER_AGENT_COUNT" "worker-agent-count"
require_positive_int "$VOTER_AGENT_COUNT" "voter-agent-count"
require_positive_int "$CLAIM_ATTEMPTS_PER_JOB" "claim-attempts-per-job"
require_positive_int "$MAX_AGENTS_PER_JOB" "max-agents-per-job"
require_positive_int "$MIN_VOTES_TO_SELECT" "min-votes-to-select"
require_positive_int "$VOTES_PER_SUBMISSION" "votes-per-submission"
require_positive_int "$AMOUNT_SPECKS" "amount-specks"
require_positive_int "$TIMEOUT_SECONDS" "timeout-seconds"
if [[ -n "$SEED" ]]; then
  require_positive_int "$SEED" "seed"
fi

if (( MAX_AGENTS_PER_JOB < 1 )); then
  echo "ERROR: max-agents-per-job must be >= 1" >&2
  exit 1
fi
if (( MAX_AGENTS_PER_JOB > 20 )); then
  echo "ERROR: max-agents-per-job must be <= 20 (server-side contest cap)" >&2
  exit 1
fi
if (( MIN_VOTES_TO_SELECT < 1 )); then
  echo "ERROR: min-votes-to-select must be >= 1" >&2
  exit 1
fi
if (( TASK_AGENT_COUNT < 1 || WORKER_AGENT_COUNT < 1 || VOTER_AGENT_COUNT < 1 )); then
  echo "ERROR: task/worker/voter agent counts must be >= 1" >&2
  exit 1
fi
if (( JOB_WORKERS < 1 )); then
  echo "ERROR: job-workers must be >= 1" >&2
  exit 1
fi

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == *"WindowsApps"* ]]; then
  PYTHON_BIN="$(command -v python 2>/dev/null || true)"
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "ERROR: python3/python is required" >&2
  exit 1
fi

exec "$PYTHON_BIN" - \
  "$BASE_URL" \
  "$JOBS_PER_ROUND" \
  "$ROUNDS" \
  "$CONTINUOUS" \
  "$SLEEP_SECONDS" \
  "$JOB_WORKERS" \
  "$TASK_AGENT_COUNT" \
  "$WORKER_AGENT_COUNT" \
  "$VOTER_AGENT_COUNT" \
  "$CLAIM_ATTEMPTS_PER_JOB" \
  "$MAX_AGENTS_PER_JOB" \
  "$MIN_VOTES_TO_SELECT" \
  "$VOTES_PER_SUBMISSION" \
  "$AMOUNT_SPECKS" \
  "$TIMEOUT_SECONDS" \
  "$SEED" <<'PYCODE'
import concurrent.futures
import json
import random
import secrets
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

(
    base_url,
    jobs_per_round,
    rounds,
    continuous,
    sleep_seconds,
    job_workers,
    task_agent_count,
    worker_agent_count,
    voter_agent_count,
    claim_attempts_per_job,
    max_agents_per_job,
    min_votes_to_select,
    votes_per_submission,
    amount_specks,
    timeout_seconds,
    seed_raw,
) = sys.argv[1:17]

jobs_per_round = int(jobs_per_round)
rounds = int(rounds)
continuous = int(continuous)
sleep_seconds = int(sleep_seconds)
job_workers = int(job_workers)
task_agent_count = int(task_agent_count)
worker_agent_count = int(worker_agent_count)
voter_agent_count = int(voter_agent_count)
claim_attempts_per_job = int(claim_attempts_per_job)
max_agents_per_job = int(max_agents_per_job)
min_votes_to_select = int(min_votes_to_select)
votes_per_submission = int(votes_per_submission)
amount_specks = int(amount_specks)
timeout_seconds = int(timeout_seconds)

seed = int(seed_raw) if seed_raw else int(time.time_ns() % (2**31 - 1))
rng = random.Random(seed)

base_url = base_url.rstrip("/")
task_agents = [f"tasker-{i:04d}" for i in range(task_agent_count)]
worker_agents = [f"worker-{i:04d}" for i in range(worker_agent_count)]
voter_agents = [f"voter-{i:04d}" for i in range(voter_agent_count)]


def pctl(values, percentile):
    if not values:
        return 0.0
    if len(values) == 1:
        return float(values[0])
    return float(statistics.quantiles(values, n=100, method="inclusive")[percentile - 1])


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def post_json(path, payload, headers=None):
    hdrs = {"Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}{path}",
        data=body,
        headers=hdrs,
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
            dt_ms = (time.perf_counter() - t0) * 1000.0
            try:
                data = json.loads(raw) if raw else {}
            except Exception:
                data = {"_raw": raw}
            return resp.status, data, dt_ms
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8") if exc.fp else ""
        dt_ms = (time.perf_counter() - t0) * 1000.0
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            data = {"error": raw or str(exc)}
        return int(exc.code), data, dt_ms
    except Exception as exc:
        dt_ms = (time.perf_counter() - t0) * 1000.0
        return 0, {"error": str(exc)}, dt_ms


def get_json(path, headers=None):
    hdrs = {}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(f"{base_url}{path}", headers=hdrs, method="GET")
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            raw = resp.read().decode("utf-8")
            dt_ms = (time.perf_counter() - t0) * 1000.0
            try:
                data = json.loads(raw) if raw else {}
            except Exception:
                data = {"_raw": raw}
            return resp.status, data, dt_ms
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8") if exc.fp else ""
        dt_ms = (time.perf_counter() - t0) * 1000.0
        try:
            data = json.loads(raw) if raw else {}
        except Exception:
            data = {"error": raw or str(exc)}
        return int(exc.code), data, dt_ms
    except Exception as exc:
        dt_ms = (time.perf_counter() - t0) * 1000.0
        return 0, {"error": str(exc)}, dt_ms


def empty_metrics():
    return {
        "jobs_planned": 0,
        "jobs_started": 0,
        "jobs_start_failed": 0,
        "jobs_flow_completed": 0,
        "jobs_flow_failed": 0,
        "claim_attempts": 0,
        "claim_success": 0,
        "claim_cap_rejections": 0,
        "claim_other_failures": 0,
        "submission_attempts": 0,
        "submission_success": 0,
        "submission_failures": 0,
        "vote_attempts": 0,
        "vote_success": 0,
        "vote_failures": 0,
        "winner_select_success": 0,
        "winner_select_failures": 0,
        "claim_cap_violations": 0,
        "status_awaiting_approval": 0,
        "status_multisig_pending": 0,
        "status_other": 0,
        "economics_total_amount_specks": 0,
        "economics_total_fee_specks": 0,
        "economics_total_net_specks": 0,
        "endpoint_latencies_ms": {
            "start_job": [],
            "claim_job": [],
            "provide_result": [],
            "vote_submission": [],
            "select_winner": [],
            "status": [],
            "submissions": [],
        },
        "errors": [],
    }


def merge_metrics(dst, src):
    for key, value in src.items():
        if key == "endpoint_latencies_ms":
            for endpoint, samples in value.items():
                dst["endpoint_latencies_ms"][endpoint].extend(samples)
        elif key == "errors":
            dst["errors"].extend(value)
        elif isinstance(value, int):
            dst[key] += value


def compact_error(stage, code, payload):
    err = payload.get("error")
    if isinstance(err, dict):
        err = json.dumps(err, separators=(",", ":"))
    return {"stage": stage, "code": code, "error": str(err)[:200]}


def vote_for_submission(job_id, submission_id, voter_id, vote_value, metrics):
    code, payload, dt = post_json(
        f"/vote_submission/{job_id}/{submission_id}",
        {"voter_id": voter_id, "vote": vote_value, "reason": "sim-load"},
    )
    metrics["vote_attempts"] += 1
    metrics["endpoint_latencies_ms"]["vote_submission"].append(dt)
    if code == 200:
        metrics["vote_success"] += 1
        return True
    metrics["vote_failures"] += 1
    metrics["errors"].append(compact_error("vote_submission", code, payload))
    return False


def run_job(round_index, job_index):
    local = empty_metrics()
    local_rng = random.Random(seed + (round_index * 100000) + job_index)
    local["jobs_planned"] = 1

    task_agent = task_agents[(round_index + job_index) % len(task_agents)]
    commitment_hash = secrets.token_hex(32)
    payload = {
        "input_data": {
            "description": f"sim-{task_agent}-r{round_index}-j{job_index}-{commitment_hash[:12]}",
            "commitmentHash": commitment_hash,
            "network": "preprod",
        },
        "amount_specks": amount_specks,
        "contest": {
            "enabled": True,
            "min_agents": max_agents_per_job,
            "max_agents": max_agents_per_job,
            "min_votes_to_select": min_votes_to_select,
        },
    }

    code, start_body, dt = post_json("/start_job", payload)
    local["endpoint_latencies_ms"]["start_job"].append(dt)
    if code != 200:
        local["jobs_start_failed"] += 1
        local["jobs_flow_failed"] += 1
        local["errors"].append(compact_error("start_job", code, start_body))
        return local

    job_id = str(start_body.get("job_id") or "").strip()
    job_token = str(start_body.get("job_token") or "").strip()
    if not job_id or not job_token:
        local["jobs_start_failed"] += 1
        local["jobs_flow_failed"] += 1
        local["errors"].append({"stage": "start_job", "code": code, "error": "missing job_id/job_token"})
        return local

    local["jobs_started"] += 1
    claimed = []
    attempted = set()

    max_claim_attempts = max(claim_attempts_per_job, max_agents_per_job)
    for _ in range(max_claim_attempts):
        if len(claimed) >= max_agents_per_job:
            break
        agent = local_rng.choice(worker_agents)
        if agent in attempted:
            continue
        attempted.add(agent)
        c_code, c_body, c_dt = post_json(f"/claim_job/{job_id}", {"agent_id": agent})
        local["claim_attempts"] += 1
        local["endpoint_latencies_ms"]["claim_job"].append(c_dt)
        if c_code == 200:
            local["claim_success"] += 1
            if agent not in claimed:
                claimed.append(agent)
            continue
        if c_code == 409 and "max_agents" in str(c_body.get("error", "")):
            local["claim_cap_rejections"] += 1
            continue
        local["claim_other_failures"] += 1
        local["errors"].append(compact_error("claim_job", c_code, c_body))

    # Force at least max_agents_per_job successful claims if possible.
    if len(claimed) < max_agents_per_job:
        for agent in worker_agents:
            if len(claimed) >= max_agents_per_job:
                break
            if agent in attempted:
                continue
            attempted.add(agent)
            c_code, c_body, c_dt = post_json(f"/claim_job/{job_id}", {"agent_id": agent})
            local["claim_attempts"] += 1
            local["endpoint_latencies_ms"]["claim_job"].append(c_dt)
            if c_code == 200:
                local["claim_success"] += 1
                claimed.append(agent)
                continue
            if c_code == 409 and "max_agents" in str(c_body.get("error", "")):
                local["claim_cap_rejections"] += 1
                break
            local["claim_other_failures"] += 1
            local["errors"].append(compact_error("claim_job", c_code, c_body))

    if len(claimed) < max_agents_per_job:
        local["jobs_flow_failed"] += 1
        local["errors"].append(
            {"stage": "claim_job", "code": 409, "error": f"only {len(claimed)} claims, expected {max_agents_per_job}"}
        )
        return local

    for agent in claimed:
        work_output = f"solution job={job_id} agent={agent} round={round_index} idx={job_index}"
        p_code, p_body, p_dt = post_json(
            f"/provide_result/{job_id}",
            {"agent_id": agent, "work_output": work_output, "artifact_file_paths": [f"/tmp/{job_id}/{agent}.json"]},
        )
        local["submission_attempts"] += 1
        local["endpoint_latencies_ms"]["provide_result"].append(p_dt)
        if p_code == 200:
            local["submission_success"] += 1
        else:
            local["submission_failures"] += 1
            local["errors"].append(compact_error("provide_result", p_code, p_body))

    s_code, subs_body, s_dt = get_json(f"/submissions/{job_id}")
    local["endpoint_latencies_ms"]["submissions"].append(s_dt)
    if s_code != 200:
        local["jobs_flow_failed"] += 1
        local["errors"].append(compact_error("submissions", s_code, subs_body))
        return local

    submissions = subs_body.get("submissions") if isinstance(subs_body, dict) else []
    if not isinstance(submissions, list) or not submissions:
        local["jobs_flow_failed"] += 1
        local["errors"].append({"stage": "submissions", "code": s_code, "error": "no submissions found"})
        return local

    # Vote per submission; bias first submission positive so winner selection passes.
    used_voters = set()
    for idx, submission in enumerate(submissions):
        sub_id = str(submission.get("submission_id") or "").strip()
        sub_agent = str(submission.get("agent_id") or "").strip()
        if not sub_id:
            continue
        for vote_idx in range(votes_per_submission):
            voter = local_rng.choice(voter_agents)
            # Avoid self-votes and duplicate voter on same job as much as possible.
            for _ in range(10):
                if voter != sub_agent and voter not in used_voters:
                    break
                voter = local_rng.choice(voter_agents)
            used_voters.add(voter)
            vote_value = "approve" if idx == 0 else ("approve" if local_rng.random() >= 0.5 else "reject")
            vote_for_submission(job_id, sub_id, voter, vote_value, local)

    sel_code, sel_body, sel_dt = post_json(
        f"/select_winner/{job_id}",
        {},
        headers={"Authorization": f"Bearer {job_token}"},
    )
    local["endpoint_latencies_ms"]["select_winner"].append(sel_dt)
    if sel_code != 200 and sel_code == 409 and "not enough votes" in str(sel_body.get("error", "")):
        # Top up the best-ranked submission with additional approvals, then retry once.
        first_sub = submissions[0]
        first_sub_id = str(first_sub.get("submission_id") or "").strip()
        first_agent = str(first_sub.get("agent_id") or "").strip()
        if first_sub_id:
            top_up = max(min_votes_to_select, 1)
            for _ in range(top_up):
                voter = local_rng.choice(voter_agents)
                for _ in range(10):
                    if voter != first_agent and voter not in used_voters:
                        break
                    voter = local_rng.choice(voter_agents)
                used_voters.add(voter)
                vote_for_submission(job_id, first_sub_id, voter, "approve", local)
            sel_code, sel_body, sel_dt = post_json(
                f"/select_winner/{job_id}",
                {},
                headers={"Authorization": f"Bearer {job_token}"},
            )
            local["endpoint_latencies_ms"]["select_winner"].append(sel_dt)

    if sel_code == 200:
        local["winner_select_success"] += 1
        econ = sel_body.get("economics") if isinstance(sel_body, dict) else {}
        if isinstance(econ, dict):
            local["economics_total_amount_specks"] += int(econ.get("amount_specks") or 0)
            local["economics_total_fee_specks"] += int(econ.get("fee") or 0)
            local["economics_total_net_specks"] += int(econ.get("net_to_agent") or 0)
    else:
        local["winner_select_failures"] += 1
        local["jobs_flow_failed"] += 1
        local["errors"].append(compact_error("select_winner", sel_code, sel_body))
        return local

    st_code, st_body, st_dt = get_json(f"/status/{job_id}")
    local["endpoint_latencies_ms"]["status"].append(st_dt)
    if st_code == 200:
        internal = str(st_body.get("internal_status") or "")
        claims_count = int(st_body.get("claims_count") or 0)
        if claims_count > max_agents_per_job:
            local["claim_cap_violations"] += 1
        if internal == "awaiting_approval":
            local["status_awaiting_approval"] += 1
        elif internal == "multisig_pending":
            local["status_multisig_pending"] += 1
        else:
            local["status_other"] += 1
    else:
        local["status_other"] += 1
        local["errors"].append(compact_error("status", st_code, st_body))

    local["jobs_flow_completed"] += 1
    return local


def format_latency_table(latency_map):
    out = {}
    for endpoint, samples in latency_map.items():
        if not samples:
            out[endpoint] = {"count": 0, "avg_ms": 0.0, "p50_ms": 0.0, "p95_ms": 0.0, "max_ms": 0.0}
            continue
        out[endpoint] = {
            "count": len(samples),
            "avg_ms": round(sum(samples) / len(samples), 2),
            "p50_ms": round(pctl(samples, 50), 2),
            "p95_ms": round(pctl(samples, 95), 2),
            "max_ms": round(max(samples), 2),
        }
    return out


def round_header(round_number):
    return f"[load-sim] round={round_number} ts={now_iso()} base={base_url}"


def run_round(round_number):
    round_metrics = empty_metrics()
    started = time.perf_counter()

    with concurrent.futures.ThreadPoolExecutor(max_workers=job_workers) as pool:
        futures = [pool.submit(run_job, round_number, i) for i in range(jobs_per_round)]
        for fut in concurrent.futures.as_completed(futures):
            try:
                result = fut.result()
            except Exception as exc:
                result = empty_metrics()
                result["jobs_planned"] = 1
                result["jobs_flow_failed"] = 1
                result["errors"].append({"stage": "executor", "code": 0, "error": str(exc)[:200]})
            merge_metrics(round_metrics, result)

    elapsed = time.perf_counter() - started
    round_metrics["round_elapsed_seconds"] = round(elapsed, 2)
    round_metrics["latency"] = format_latency_table(round_metrics["endpoint_latencies_ms"])
    return round_metrics


def printable_metrics(metrics):
    out = dict(metrics)
    out.pop("endpoint_latencies_ms", None)
    errors = out.get("errors", [])
    out["error_count"] = len(errors)
    out["sample_errors"] = errors[:8]
    out["errors"] = []
    return out


def print_round_summary(label, metrics):
    print(round_header(label))
    print(
        json.dumps(
            printable_metrics(metrics),
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )
    print(
        json.dumps(
            {"latency": metrics.get("latency", {})},
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )


def main():
    cumulative = empty_metrics()
    round_index = 1
    availability_code, availability_payload, availability_dt = get_json("/availability")
    if availability_code != 200:
        err = {
            "event": "load-sim-preflight-failed",
            "base_url": base_url,
            "endpoint": "/availability",
            "status_code": availability_code,
            "latency_ms": round(availability_dt, 2),
            "error": str(availability_payload.get("error", "service unavailable"))[:300],
        }
        print(json.dumps(err, separators=(",", ":"), sort_keys=True), flush=True)
        return 2
    print(
        json.dumps(
            {
                "event": "load-sim-preflight-ok",
                "base_url": base_url,
                "availability_status": availability_payload.get("status"),
                "latency_ms": round(availability_dt, 2),
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )
    try:
        while True:
            metrics = run_round(round_index)
            merge_metrics(cumulative, metrics)
            cumulative["latency"] = format_latency_table(cumulative["endpoint_latencies_ms"])
            print_round_summary(round_index, metrics)
            print_round_summary("cumulative", cumulative)

            if not continuous and round_index >= rounds:
                break
            round_index += 1
            if sleep_seconds > 0:
                time.sleep(sleep_seconds)
    except KeyboardInterrupt:
        cumulative["latency"] = format_latency_table(cumulative["endpoint_latencies_ms"])
        print("[load-sim] interrupted", flush=True)
        print_round_summary("cumulative", cumulative)
        return 130
    return 0


if __name__ == "__main__":
    print(
        json.dumps(
            {
                "event": "load-sim-start",
                "ts": now_iso(),
                "base_url": base_url,
                "jobs_per_round": jobs_per_round,
                "rounds": rounds,
                "continuous": bool(continuous),
                "job_workers": job_workers,
                "task_agent_count": task_agent_count,
                "worker_agent_count": worker_agent_count,
                "voter_agent_count": voter_agent_count,
                "claim_attempts_per_job": claim_attempts_per_job,
                "max_agents_per_job": max_agents_per_job,
                "min_votes_to_select": min_votes_to_select,
                "votes_per_submission": votes_per_submission,
                "amount_specks": amount_specks,
                "timeout_seconds": timeout_seconds,
                "seed": seed,
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )
    sys.exit(main())
PYCODE
