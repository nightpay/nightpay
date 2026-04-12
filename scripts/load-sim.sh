#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/load-sim.sh [options]

Options:
  --activity-mode                  Sequential activity feed mode (leaderboard-style)
  --activity-agent-count <n>       Logical agent pool size in activity mode (default: 100)
  --activity-target-tasks <n>      Stop after this many tasks in activity mode (default: 15000000)
  --activity-interval-min-seconds <n>  Min delay between tasks in activity mode (default: 3)
  --activity-interval-max-seconds <n>  Max delay between tasks in activity mode (default: 5)
  --activity-report-every <n>      Emit progress summary every N tasks in activity mode (default: 25)
  --activity-state-file <path>     Persist counters to JSON for resume/observation (default: .tmp/activity-sim-state.json)
  --activity-visibility <mode>     Job visibility in activity mode: public|private (default: public)
  --operator-secret <secret>       Operator bearer for /complete_job (default: OPERATOR_SECRET_KEY env var)
  --skip-complete                  Activity mode only: leave jobs awaiting approval (no /complete_job)

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
  bash scripts/load-sim.sh --activity-mode --continuous
  bash scripts/load-sim.sh --activity-mode --activity-target-tasks 15000000 --activity-agent-count 100
EOF
}

ACTIVITY_MODE=0
ACTIVITY_AGENT_COUNT=100
ACTIVITY_TARGET_TASKS=15000000
ACTIVITY_INTERVAL_MIN_SECONDS=3
ACTIVITY_INTERVAL_MAX_SECONDS=5
ACTIVITY_REPORT_EVERY=25
ACTIVITY_STATE_FILE=".tmp/activity-sim-state.json"
ACTIVITY_VISIBILITY="public"
OPERATOR_SECRET="${OPERATOR_SECRET_KEY:-}"
ACTIVITY_SKIP_COMPLETE=0

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
    --activity-mode) ACTIVITY_MODE=1; shift 1 ;;
    --activity-agent-count) ACTIVITY_AGENT_COUNT="${2:-}"; shift 2 ;;
    --activity-target-tasks) ACTIVITY_TARGET_TASKS="${2:-}"; shift 2 ;;
    --activity-interval-min-seconds) ACTIVITY_INTERVAL_MIN_SECONDS="${2:-}"; shift 2 ;;
    --activity-interval-max-seconds) ACTIVITY_INTERVAL_MAX_SECONDS="${2:-}"; shift 2 ;;
    --activity-report-every) ACTIVITY_REPORT_EVERY="${2:-}"; shift 2 ;;
    --activity-state-file) ACTIVITY_STATE_FILE="${2:-}"; shift 2 ;;
    --activity-visibility) ACTIVITY_VISIBILITY="${2:-}"; shift 2 ;;
    --operator-secret) OPERATOR_SECRET="${2:-}"; shift 2 ;;
    --skip-complete) ACTIVITY_SKIP_COMPLETE=1; shift 1 ;;

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
require_positive_int "$ACTIVITY_AGENT_COUNT" "activity-agent-count"
require_positive_int "$ACTIVITY_TARGET_TASKS" "activity-target-tasks"
require_positive_int "$ACTIVITY_INTERVAL_MIN_SECONDS" "activity-interval-min-seconds"
require_positive_int "$ACTIVITY_INTERVAL_MAX_SECONDS" "activity-interval-max-seconds"
require_positive_int "$ACTIVITY_REPORT_EVERY" "activity-report-every"
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
if (( ACTIVITY_AGENT_COUNT < 1 )); then
  echo "ERROR: activity-agent-count must be >= 1" >&2
  exit 1
fi
if (( ACTIVITY_TARGET_TASKS < 1 )) && (( CONTINUOUS == 0 )) && (( ACTIVITY_MODE == 1 )); then
  echo "ERROR: activity-target-tasks must be >= 1 unless --continuous is used" >&2
  exit 1
fi
if (( ACTIVITY_INTERVAL_MAX_SECONDS < ACTIVITY_INTERVAL_MIN_SECONDS )); then
  echo "ERROR: activity-interval-max-seconds must be >= activity-interval-min-seconds" >&2
  exit 1
fi
if (( ACTIVITY_MODE == 1 )) && (( ACTIVITY_SKIP_COMPLETE == 0 )) && [[ -z "${OPERATOR_SECRET}" ]]; then
  echo "ERROR: activity mode requires --operator-secret (or OPERATOR_SECRET_KEY env var) unless --skip-complete is set" >&2
  exit 1
fi
if [[ "$ACTIVITY_VISIBILITY" != "public" && "$ACTIVITY_VISIBILITY" != "private" ]]; then
  echo "ERROR: activity-visibility must be one of: public, private" >&2
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
  "$ACTIVITY_MODE" \
  "$ACTIVITY_AGENT_COUNT" \
  "$ACTIVITY_TARGET_TASKS" \
  "$ACTIVITY_INTERVAL_MIN_SECONDS" \
  "$ACTIVITY_INTERVAL_MAX_SECONDS" \
  "$ACTIVITY_REPORT_EVERY" \
  "$ACTIVITY_STATE_FILE" \
  "$ACTIVITY_VISIBILITY" \
  "$OPERATOR_SECRET" \
  "$ACTIVITY_SKIP_COMPLETE" \
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
import os
import random
import secrets
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

(
    activity_mode,
    activity_agent_count,
    activity_target_tasks,
    activity_interval_min_seconds,
    activity_interval_max_seconds,
    activity_report_every,
    activity_state_file,
    activity_visibility,
    operator_secret,
    activity_skip_complete,
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
) = sys.argv[1:27]

activity_mode = int(activity_mode)
activity_agent_count = int(activity_agent_count)
activity_target_tasks = int(activity_target_tasks)
activity_interval_min_seconds = int(activity_interval_min_seconds)
activity_interval_max_seconds = int(activity_interval_max_seconds)
activity_report_every = int(activity_report_every)
activity_skip_complete = int(activity_skip_complete)
operator_secret = str(operator_secret or "")
activity_state_file = str(activity_state_file or "").strip()
activity_visibility = str(activity_visibility or "public").strip().lower()

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


def build_epic_agent_pool(count, local_rng):
    adjectives = [
        "amber",
        "brisk",
        "cinder",
        "daring",
        "ember",
        "frost",
        "gale",
        "helios",
        "ion",
        "jade",
        "kepler",
        "lunar",
        "magma",
        "nova",
        "onyx",
        "prism",
        "quantum",
        "rivet",
        "solstice",
        "turbo",
        "umbra",
        "vivid",
        "wild",
        "xeno",
        "young",
        "zen",
    ]
    nouns = [
        "falcon",
        "otter",
        "lynx",
        "orca",
        "tiger",
        "panther",
        "condor",
        "rocket",
        "pixel",
        "cipher",
        "orbit",
        "vortex",
        "matrix",
        "beacon",
        "ranger",
        "voyager",
        "striker",
        "pioneer",
        "nomad",
        "engine",
        "signal",
        "radar",
        "comet",
        "blaze",
        "atlas",
        "sentinel",
    ]
    names = []
    used = set()
    while len(names) < count:
        candidate = f"{local_rng.choice(adjectives)}-{local_rng.choice(nouns)}-{local_rng.randint(100, 999)}"
        if candidate in used:
            continue
        used.add(candidate)
        names.append(candidate)
    return names


task_agents = [f"tasker-{i:04d}" for i in range(task_agent_count)]
worker_agents = [f"worker-{i:04d}" for i in range(worker_agent_count)]
voter_agents = [f"voter-{i:04d}" for i in range(voter_agent_count)]
activity_agents = build_epic_agent_pool(activity_agent_count, random.Random(seed + 97))


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

    legacy = start_body.get("legacy") if isinstance(start_body, dict) else {}
    if not isinstance(legacy, dict):
        legacy = {}
    job_id = str(
        start_body.get("job_id")
        or start_body.get("id")
        or legacy.get("job_id")
        or ""
    ).strip()
    job_token = str(
        start_body.get("job_token")
        or start_body.get("jobToken")
        or legacy.get("job_token")
        or ""
    ).strip()
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

    s_code, subs_body, s_dt = get_json(
        f"/submissions/{job_id}",
        headers={"Authorization": f"Bearer {job_token}"},
    )
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
    # Voter snapshot is claim-based when agent_voting_only=true, so prefer claimed agents here.
    used_voters = set()
    eligible_voters = [agent for agent in claimed if agent]
    if not eligible_voters:
        eligible_voters = [agent for agent in worker_agents if agent]

    def pick_voter(exclude_agent):
        pool = [v for v in eligible_voters if v != exclude_agent and v not in used_voters]
        if not pool:
            pool = [v for v in eligible_voters if v != exclude_agent]
        if not pool:
            pool = list(eligible_voters)
        if not pool:
            pool = list(worker_agents)
        return local_rng.choice(pool)

    for idx, submission in enumerate(submissions):
        sub_id = str(submission.get("submission_id") or "").strip()
        sub_agent = str(submission.get("agent_id") or "").strip()
        if not sub_id:
            continue
        for vote_idx in range(votes_per_submission):
            voter = pick_voter(sub_agent)
            used_voters.add(voter)
            vote_value = "approve" if idx == 0 else ("approve" if local_rng.random() >= 0.5 else "reject")
            vote_for_submission(job_id, sub_id, voter, vote_value, local)

    sel_code, sel_body, sel_dt = post_json(
        f"/select_winner/{job_id}",
        {},
        headers={"Authorization": f"Bearer {job_token}"},
    )
    local["endpoint_latencies_ms"]["select_winner"].append(sel_dt)
    sel_error = str(sel_body.get("error", "")).lower()
    if sel_code != 200 and sel_code == 409 and (
        "not enough votes" in sel_error or "strict majority" in sel_error
    ):
        # Top up the best-ranked submission with additional approvals, then retry once.
        first_sub = submissions[0]
        first_sub_id = str(first_sub.get("submission_id") or "").strip()
        first_agent = str(first_sub.get("agent_id") or "").strip()
        if first_sub_id:
            top_up = max(min_votes_to_select, 1)
            for _ in range(top_up):
                voter = pick_voter(first_agent)
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

    st_code, st_body, st_dt = get_json(
        f"/status/{job_id}",
        headers={"Authorization": f"Bearer {job_token}"},
    )
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


def empty_activity_metrics():
    return {
        "tasks_target": int(activity_target_tasks),
        "tasks_attempted": 0,
        "tasks_started": 0,
        "tasks_completed": 0,
        "tasks_failed": 0,
        "claim_success": 0,
        "submission_success": 0,
        "completion_success": 0,
        "endpoint_latencies_ms": {
            "start_job": [],
            "claim_job": [],
            "provide_result": [],
            "complete_job": [],
            "status": [],
        },
        "errors": [],
    }


def load_activity_state(path):
    if not path:
        return None
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    state = empty_activity_metrics()
    for key in ("tasks_attempted", "tasks_started", "tasks_completed", "tasks_failed", "claim_success", "submission_success", "completion_success"):
        try:
            value = int(raw.get(key, 0))
            if value < 0:
                value = 0
            state[key] = value
        except Exception:
            state[key] = 0
    return state


def save_activity_state(path, metrics, last_event=None):
    if not path:
        return
    payload = {
        "mode": "activity",
        "updated_at": now_iso(),
        "seed": seed,
        "base_url": base_url,
        "tasks_target": int(activity_target_tasks),
        "tasks_attempted": int(metrics.get("tasks_attempted", 0)),
        "tasks_started": int(metrics.get("tasks_started", 0)),
        "tasks_completed": int(metrics.get("tasks_completed", 0)),
        "tasks_failed": int(metrics.get("tasks_failed", 0)),
        "claim_success": int(metrics.get("claim_success", 0)),
        "submission_success": int(metrics.get("submission_success", 0)),
        "completion_success": int(metrics.get("completion_success", 0)),
        "last_event": last_event or {},
    }
    out_dir = os.path.dirname(path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, path)


def pick_two_distinct_agents(local_rng, agents):
    first = local_rng.choice(agents)
    second = first
    if len(agents) > 1:
        while second == first:
            second = local_rng.choice(agents)
    return first, second


def run_activity_task(task_seq, local_rng):
    event = {
        "event": "activity-task",
        "ts": now_iso(),
        "task_seq": int(task_seq),
    }
    commitment_hash = secrets.token_hex(32)
    requester, preferred_worker = pick_two_distinct_agents(local_rng, activity_agents)
    payload = {
        "input_data": {
            "description": f"epic-sim-{requester}-to-{preferred_worker}-task-{task_seq}-{commitment_hash[:10]}",
            "commitmentHash": commitment_hash,
            "network": "preprod",
        },
        "amount_specks": amount_specks,
        "visibility": activity_visibility,
        # Present in strict mode, ignored in compat mode.
        "agentIdentifier": requester,
        "identifier_from_purchaser": f"buyer-{requester}",
    }
    event["requester"] = requester
    event["preferred_worker"] = preferred_worker

    code, start_body, start_dt = post_json("/start_job", payload)
    event["start_status"] = int(code)
    event["start_ms"] = round(start_dt, 2)
    if code != 200:
        event["ok"] = False
        event["stage"] = "start_job"
        event["error"] = str(start_body.get("error", "start_job failed"))[:200]
        return event

    legacy = start_body.get("legacy") if isinstance(start_body, dict) else {}
    if not isinstance(legacy, dict):
        legacy = {}
    job_id = str(
        start_body.get("job_id")
        or start_body.get("id")
        or legacy.get("job_id")
        or ""
    ).strip()
    job_token = str(
        start_body.get("job_token")
        or start_body.get("jobToken")
        or legacy.get("job_token")
        or ""
    ).strip()
    if not job_id or not job_token:
        event["ok"] = False
        event["stage"] = "start_job"
        event["error"] = "missing job_id/job_token"
        if isinstance(start_body, dict):
            event["start_body_keys"] = sorted(start_body.keys())
        if isinstance(legacy, dict):
            event["legacy_keys"] = sorted(legacy.keys())
        return event

    event["job_id"] = job_id
    claim_candidates = [preferred_worker]
    if len(activity_agents) > 1:
        remaining = [agent for agent in activity_agents if agent != preferred_worker]
        local_rng.shuffle(remaining)
        claim_candidates.extend(remaining[:4])

    claimed_agent = ""
    claim_errors = []
    claim_dt_last = 0.0
    for candidate in claim_candidates:
        c_code, c_body, c_dt = post_json(f"/claim_job/{job_id}", {"agent_id": candidate})
        claim_dt_last = c_dt
        if c_code == 200:
            claimed_agent = candidate
            break
        claim_errors.append({"code": int(c_code), "error": str(c_body.get("error", ""))[:120]})
    event["claim_ms"] = round(claim_dt_last, 2)
    if not claimed_agent:
        event["ok"] = False
        event["stage"] = "claim_job"
        event["error"] = "claim failed for all candidates"
        event["claim_errors"] = claim_errors[:4]
        return event

    event["worker"] = claimed_agent
    work_output = (
        f"epic completion task={task_seq} requester={requester} worker={claimed_agent} "
        f"commit={commitment_hash[:12]}"
    )
    p_code, p_body, p_dt = post_json(
        f"/provide_result/{job_id}",
        {"agent_id": claimed_agent, "work_output": work_output, "artifact_file_paths": [f"/tmp/{job_id}/{claimed_agent}.txt"]},
        headers={"Authorization": f"Bearer {job_token}"},
    )
    event["provide_status"] = int(p_code)
    event["provide_ms"] = round(p_dt, 2)
    if p_code != 200:
        event["ok"] = False
        event["stage"] = "provide_result"
        event["error"] = str(p_body.get("error", "provide_result failed"))[:200]
        return event

    if activity_skip_complete == 0:
        comp_payload = {
            "receiptHash": secrets.token_hex(32),
            "outputHash": secrets.token_hex(32),
            "onChain": False,
        }
        k_code, k_body, k_dt = post_json(
            f"/complete_job/{job_id}",
            comp_payload,
            headers={"Authorization": f"Bearer {operator_secret}"},
        )
        event["complete_status"] = int(k_code)
        event["complete_ms"] = round(k_dt, 2)
        if k_code != 200:
            event["ok"] = False
            event["stage"] = "complete_job"
            event["error"] = str(k_body.get("error", "complete_job failed"))[:200]
            return event
    else:
        event["complete_status"] = 0
        event["complete_ms"] = 0.0

    s_code, s_body, s_dt = get_json(f"/status/{job_id}", headers={"Authorization": f"Bearer {job_token}"})
    event["status_check"] = int(s_code)
    event["status_ms"] = round(s_dt, 2)
    strict_status = ""
    if s_code == 200:
        event["internal_status"] = str(s_body.get("internal_status") or "")
        strict_status = str(s_body.get("status") or "")
        event["status"] = strict_status
    internal_status = str(event.get("internal_status") or "")
    if activity_skip_complete:
        status_ok = internal_status in ("awaiting_approval", "multisig_pending") or strict_status == "running"
    else:
        status_ok = internal_status == "completed" or strict_status == "completed"
    if s_code != 200 or not status_ok:
        expected = "awaiting_approval/running" if activity_skip_complete else "completed"
        event["ok"] = False
        event["stage"] = "status"
        got = internal_status or strict_status or "unknown"
        event["error"] = f"expected {expected}, got {got}"
        return event

    event["ok"] = True
    return event


def print_activity_summary(metrics, started_at, label):
    elapsed = max(time.perf_counter() - started_at, 0.001)
    started = int(metrics.get("tasks_started", 0))
    completed = int(metrics.get("tasks_completed", 0))
    failed = int(metrics.get("tasks_failed", 0))
    remaining = max(int(activity_target_tasks) - started, 0)
    rate = started / elapsed
    eta_seconds = int(remaining / rate) if rate > 0 and remaining > 0 else 0
    summary = {
        "event": "activity-sim-progress",
        "label": label,
        "ts": now_iso(),
        "tasks_target": int(activity_target_tasks),
        "tasks_attempted": int(metrics.get("tasks_attempted", 0)),
        "tasks_started": started,
        "tasks_completed": completed,
        "tasks_failed": failed,
        "remaining_tasks": remaining,
        "rate_tasks_per_second": round(rate, 4),
        "eta_seconds": eta_seconds,
        "latency": format_latency_table(metrics.get("endpoint_latencies_ms", {})),
        "error_count": len(metrics.get("errors", [])),
        "sample_errors": metrics.get("errors", [])[:8],
    }
    print(json.dumps(summary, separators=(",", ":"), sort_keys=True), flush=True)


def run_activity_mode():
    metrics = empty_activity_metrics()
    started_at = time.perf_counter()
    state = load_activity_state(activity_state_file)
    if state:
        metrics.update({k: v for k, v in state.items() if k in metrics})
        print(
            json.dumps(
                {
                    "event": "activity-sim-resume",
                    "ts": now_iso(),
                    "state_file": activity_state_file,
                    "tasks_attempted": metrics["tasks_attempted"],
                    "tasks_started": metrics["tasks_started"],
                    "tasks_completed": metrics["tasks_completed"],
                    "tasks_failed": metrics["tasks_failed"],
                },
                separators=(",", ":"),
                sort_keys=True,
            ),
            flush=True,
        )

    availability_code, availability_payload, availability_dt = get_json("/availability")
    if availability_code != 200:
        err = {
            "event": "load-sim-preflight-failed",
            "mode": "activity",
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
                "mode": "activity",
                "base_url": base_url,
                "availability_status": availability_payload.get("status"),
                "latency_ms": round(availability_dt, 2),
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )
    print(
        json.dumps(
            {
                "event": "activity-agents",
                "count": len(activity_agents),
                "agents": activity_agents,
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )

    consecutive_failures = 0
    max_consecutive_failures = 50
    try:
        while True:
            if not continuous and metrics["tasks_started"] >= activity_target_tasks:
                break

            task_seq = metrics["tasks_attempted"] + 1
            task_started_t0 = time.perf_counter()
            event = run_activity_task(task_seq, rng)
            event["task_runtime_ms"] = round((time.perf_counter() - task_started_t0) * 1000.0, 2)
            metrics["tasks_attempted"] += 1

            start_ms = event.get("start_ms")
            if isinstance(start_ms, (int, float)):
                metrics["endpoint_latencies_ms"]["start_job"].append(float(start_ms))
            claim_ms = event.get("claim_ms")
            if isinstance(claim_ms, (int, float)) and claim_ms > 0:
                metrics["endpoint_latencies_ms"]["claim_job"].append(float(claim_ms))
            provide_ms = event.get("provide_ms")
            if isinstance(provide_ms, (int, float)) and provide_ms > 0:
                metrics["endpoint_latencies_ms"]["provide_result"].append(float(provide_ms))
            complete_ms = event.get("complete_ms")
            if isinstance(complete_ms, (int, float)) and complete_ms > 0:
                metrics["endpoint_latencies_ms"]["complete_job"].append(float(complete_ms))
            status_ms = event.get("status_ms")
            if isinstance(status_ms, (int, float)) and status_ms > 0:
                metrics["endpoint_latencies_ms"]["status"].append(float(status_ms))

            if event.get("start_status") == 200:
                metrics["tasks_started"] += 1
            if event.get("worker"):
                metrics["claim_success"] += 1
            if event.get("provide_status") == 200:
                metrics["submission_success"] += 1
            if activity_skip_complete == 0 and event.get("complete_status") == 200:
                metrics["completion_success"] += 1
            if activity_skip_complete == 1 and event.get("status_check") == 200:
                metrics["completion_success"] += 1

            if event.get("ok"):
                metrics["tasks_completed"] += 1
                consecutive_failures = 0
            else:
                metrics["tasks_failed"] += 1
                consecutive_failures += 1
                metrics["errors"].append(
                    {
                        "task_seq": int(task_seq),
                        "stage": str(event.get("stage", "unknown")),
                        "error": str(event.get("error", ""))[:200],
                    }
                )

            next_delay = 0
            if activity_interval_max_seconds > 0:
                next_delay = rng.randint(activity_interval_min_seconds, activity_interval_max_seconds)
            event["next_delay_seconds"] = int(next_delay)
            event["tasks_started_total"] = int(metrics["tasks_started"])
            event["tasks_completed_total"] = int(metrics["tasks_completed"])
            event["tasks_failed_total"] = int(metrics["tasks_failed"])
            print(json.dumps(event, separators=(",", ":"), sort_keys=True), flush=True)

            save_activity_state(activity_state_file, metrics, event)

            if consecutive_failures >= max_consecutive_failures:
                print(
                    json.dumps(
                        {
                            "event": "activity-sim-abort",
                            "ts": now_iso(),
                            "reason": "too_many_consecutive_failures",
                            "consecutive_failures": consecutive_failures,
                        },
                        separators=(",", ":"),
                        sort_keys=True,
                    ),
                    flush=True,
                )
                print_activity_summary(metrics, started_at, "abort")
                save_activity_state(activity_state_file, metrics, {"event": "activity-sim-abort"})
                return 1

            if metrics["tasks_attempted"] % activity_report_every == 0:
                print_activity_summary(metrics, started_at, "periodic")

            if not continuous and metrics["tasks_started"] >= activity_target_tasks:
                break
            if next_delay > 0:
                time.sleep(next_delay)
    except KeyboardInterrupt:
        print("[load-sim] interrupted", flush=True)
        print_activity_summary(metrics, started_at, "interrupted")
        save_activity_state(activity_state_file, metrics, {"event": "interrupt"})
        return 130

    print_activity_summary(metrics, started_at, "done")
    save_activity_state(activity_state_file, metrics, {"event": "done"})
    return 0


def main():
    if activity_mode:
        return run_activity_mode()

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
    start_mode = "activity" if activity_mode else "round"
    print(
        json.dumps(
            {
                "event": "load-sim-start",
                "ts": now_iso(),
                "mode": start_mode,
                "base_url": base_url,
                "activity_agent_count": activity_agent_count,
                "activity_target_tasks": activity_target_tasks,
                "activity_interval_min_seconds": activity_interval_min_seconds,
                "activity_interval_max_seconds": activity_interval_max_seconds,
                "activity_report_every": activity_report_every,
                "activity_state_file": activity_state_file,
                "activity_visibility": activity_visibility,
                "activity_skip_complete": bool(activity_skip_complete),
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
