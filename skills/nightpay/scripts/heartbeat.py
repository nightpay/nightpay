#!/usr/bin/env python3
"""
NightPay OpenClaw heartbeat runner — implements skills/nightpay/HEARTBEAT.md.

Exit 0 and print HEARTBEAT_OK when no alerts (info lines allowed).
Exit 1 when any alert fires, including skill version drift; prints alerts ordered by severity.
Optional [INFO] lines for bridge stub mode or skipped remote skill fetch.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# Severity ordering per HEARTBEAT.md (lower = more urgent).
# SEV_DEADLINE sits between work spikes and version drift — expired timers
# need attention soon but are less urgent than a down service or bridge.
SEV_SERVICE = 1
SEV_BRIDGE = 2
SEV_WORK = 3
SEV_DEADLINE = 4
SEV_VERSION = 5

# Deadline radar buckets (HEARTBEAT.md §6). Ordered most-urgent-first so the
# heartbeat fires the tighter bucket before the looser one when a timer
# crosses both at once.
DEADLINE_BUCKETS = (
    ("expired", 0),
    ("lt_1h", 3600),
    ("lt_6h", 21600),
)
MAINNET_NOTIFY_WITHIN_DAYS = 30
DEFAULT_MAINNET_DATE = "2026-03-30T00:00:00Z"

DEFAULT_API = "https://api.nightpay.dev"
REMOTE_SKILL_URL = (
    "https://raw.githubusercontent.com/nightpay/nightpay/master/skills/nightpay/SKILL.md"
)
STATE_VERSION = 1


def _state_path() -> Path:
    raw = os.environ.get("NIGHTPAY_HEARTBEAT_STATE")
    if raw:
        return Path(raw).expanduser()
    xdg = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(xdg) if xdg else Path.home() / ".local" / "state"
    return base / "nightpay" / "heartbeat-state.json"


def _default_state() -> dict[str, Any]:
    # Keep the default state builder DRY — add new fields here only.
    return {
        "_v": STATE_VERSION,
        "api_fail_streak": 0,
        "ontology_fail_streak": 0,
        "last_active_jobs": None,
        "last_bridge_network": None,
        "last_skill_check_ts": 0.0,
        "last_notified_remote_skill_version": None,
        # Deadline-radar state: maps "<job_id>:<timer>" -> most urgent bucket
        # name already notified, so the same bucket doesn't re-alert every run.
        "notified_deadlines": {},
        "mainnet_milestone_notified": False,
    }


def load_state(path: Path) -> dict[str, Any]:
    defaults = _default_state()
    if not path.is_file():
        return defaults
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("not a dict")
        for key, value in defaults.items():
            data.setdefault(key, value)
        return data
    except (OSError, json.JSONDecodeError, ValueError):
        return defaults


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    state["_v"] = STATE_VERSION
    payload = json.dumps(state, indent=2, sort_keys=True) + "\n"
    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent), prefix=".heartbeat-", suffix=".json"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.isfile(tmp):
                os.unlink(tmp)
        except OSError:
            pass


def http_get(
    url: str, timeout: float = 15.0
) -> tuple[bytes | None, int | None, str | None]:
    req = urllib.request.Request(url, headers={"User-Agent": "nightpay-heartbeat/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return body, resp.getcode(), None
    except urllib.error.HTTPError as e:
        try:
            return e.read(), e.code, None
        except OSError:
            return None, e.code, str(e)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return None, None, str(e)


def parse_json_body(raw: bytes | None) -> tuple[Any | None, str | None]:
    if raw is None:
        return None, "empty body"
    try:
        return json.loads(raw.decode("utf-8")), None
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        return None, str(e)


def parse_iso(raw: str | None) -> float | None:
    """Parse an ISO-8601 timestamp into a UTC unix timestamp.

    Tolerates trailing 'Z' and missing tz (assumes UTC) to match the shapes
    emitted by gateway.sh and mip003-server.sh.
    """
    if not raw:
        return None
    try:
        from datetime import datetime, timezone
        dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except (TypeError, ValueError):
        return None


def classify_bucket(seconds_remaining: float | None) -> str | None:
    """Return the most-urgent bucket name a timer has crossed, or None."""
    if seconds_remaining is None:
        return None
    for name, threshold in DEADLINE_BUCKETS:
        # 'expired' has threshold 0; any value <= 0 means we're past the deadline.
        if seconds_remaining <= threshold:
            return name
    return None


def _bucket_rank(name: str | None) -> int:
    """Lower rank = more urgent. Used to suppress re-alerting the same bucket."""
    order = {n: i for i, (n, _) in enumerate(DEADLINE_BUCKETS)}
    return order.get(name or "", len(DEADLINE_BUCKETS))


def skill_version_from_markdown(text: str) -> str | None:
    m = re.match(r"^---\s*\r?\n(.*?)\r?\n---", text, re.DOTALL)
    if not m:
        return None
    fm = m.group(1)
    vm = re.search(r'"version"\s*:\s*"([^"]+)"', fm)
    return vm.group(1) if vm else None


def normalize_base(url: str) -> str:
    return url.rstrip("/")


def run_selftest() -> None:
    sample = '---\nname: nightpay\nmetadata: {"version":"9.9.9"}\n---\n# x\n'
    assert skill_version_from_markdown(sample) == "9.9.9"
    assert skill_version_from_markdown("# no frontmatter") is None

    # ISO parsing + bucket classification (deadline radar).
    assert parse_iso(None) is None
    assert parse_iso("not-a-date") is None
    ts_z = parse_iso("2026-01-02T03:04:05Z")
    ts_off = parse_iso("2026-01-02T03:04:05+00:00")
    assert ts_z is not None and ts_off is not None
    assert abs(ts_z - ts_off) < 1.0
    assert classify_bucket(None) is None
    assert classify_bucket(-10) == "expired"
    assert classify_bucket(0) == "expired"
    assert classify_bucket(60) == "lt_1h"
    assert classify_bucket(3600) == "lt_1h"
    assert classify_bucket(3601) == "lt_6h"
    assert classify_bucket(21600) == "lt_6h"
    assert classify_bucket(21601) is None
    assert _bucket_rank("expired") < _bucket_rank("lt_1h") < _bucket_rank("lt_6h")

    td = Path(tempfile.mkdtemp())
    try:
        base = load_state(td / "missing.json")
        base["api_fail_streak"] = 1
        base["notified_deadlines"]["job_a:escrow_timeout"] = "lt_6h"
        save_state(td / "s.json", base)
        st2 = load_state(td / "s.json")
        assert st2["api_fail_streak"] == 1
        assert st2["notified_deadlines"]["job_a:escrow_timeout"] == "lt_6h"
        assert st2["mainnet_milestone_notified"] is False
    finally:
        for f in td.glob("*"):
            f.unlink(missing_ok=True)
        td.rmdir()
    print("heartbeat selftest OK", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description="NightPay HEARTBEAT.md runner")
    ap.add_argument(
        "--selftest",
        action="store_true",
        help="Run local sanity checks (no network)",
    )
    args = ap.parse_args()
    if args.selftest:
        run_selftest()
        return 0

    skill_root = os.environ.get("NIGHTPAY_SKILL_ROOT", "").strip()
    if not skill_root:
        skill_root = str(Path(__file__).resolve().parent.parent)
    local_skill = Path(skill_root) / "SKILL.md"
    if not local_skill.is_file():
        print(
            f"[INFO] Local SKILL.md not found at {local_skill} — "
            f"set NIGHTPAY_SKILL_ROOT for skill version compare.",
            file=sys.stderr,
        )

    api_base = normalize_base(os.environ.get("NIGHTPAY_API_URL", DEFAULT_API))
    bridge_raw = os.environ.get("BRIDGE_URL", "").strip()
    bridge_base = normalize_base(bridge_raw) if bridge_raw else ""

    state_path = _state_path()
    state = load_state(state_path)

    alerts: list[tuple[int, str]] = []
    info_lines: list[str] = []

    # --- 1) API availability ---
    av_url = f"{api_base}/availability"
    raw, code, err = http_get(av_url)
    av_data, parse_err = parse_json_body(raw)
    api_ok = (
        code == 200
        and av_data is not None
        and isinstance(av_data, dict)
        and av_data.get("status") == "available"
    )
    if api_ok:
        state["api_fail_streak"] = 0
    else:
        state["api_fail_streak"] = int(state["api_fail_streak"]) + 1
        detail = err or parse_err or f"HTTP {code}"
        if state["api_fail_streak"] >= 2:
            alerts.append(
                (
                    SEV_SERVICE,
                    f"API unavailable ({detail}). MIP-003 /availability failed after "
                    f"{state['api_fail_streak']} consecutive checks. "
                    f"Confirm NIGHTPAY_API_URL and operator stack.",
                )
            )

    active_jobs: int | None = None
    if api_ok and isinstance(av_data, dict):
        try:
            active_jobs = int(av_data.get("active_jobs", 0))
        except (TypeError, ValueError):
            active_jobs = None

    # --- 2) Ontology ---
    on_url = f"{api_base}/ontology"
    raw_o, code_o, err_o = http_get(on_url)
    on_data, parse_err_o = parse_json_body(raw_o)
    ontology_ok = (
        code_o == 200
        and on_data is not None
        and isinstance(on_data, dict)
        and ("@graph" in on_data or "version" in on_data)
    )
    if ontology_ok:
        state["ontology_fail_streak"] = 0
    else:
        state["ontology_fail_streak"] = int(state["ontology_fail_streak"]) + 1
        detail_o = err_o or parse_err_o or f"HTTP {code_o}"
        if state["ontology_fail_streak"] >= 2:
            alerts.append(
                (
                    SEV_SERVICE,
                    f"Ontology unreachable ({detail_o}). Agents lose JSON-LD navigation "
                    f"after {state['ontology_fail_streak']} consecutive failures.",
                )
            )

    # --- 3) Bridge ---
    if bridge_base:
        h_url = f"{bridge_base}/health"
        raw_b, code_b, err_b = http_get(h_url)
        b_data, parse_err_b = parse_json_body(raw_b)
        if code_b != 200 or b_data is None:
            detail_b = err_b or parse_err_b or f"HTTP {code_b}"
            alerts.append(
                (
                    SEV_BRIDGE,
                    f"Bridge health check failed ({detail_b}). "
                    f"Review BRIDGE_URL and bridge logs.",
                )
            )
        else:
            assert isinstance(b_data, dict)
            if b_data.get("initError"):
                alerts.append(
                    (
                        SEV_BRIDGE,
                        f"Bridge initError: {b_data.get('initError')}. "
                        f"Fix bridge configuration before on-chain flows.",
                    )
                )
            net = b_data.get("network")
            prev_net = state.get("last_bridge_network")
            if (
                prev_net
                and net
                and str(prev_net) != str(net)
            ):
                alerts.append(
                    (
                        SEV_BRIDGE,
                        f"Bridge network changed from {prev_net!r} to {net!r} — "
                        f"verify MIDNIGHT_NETWORK / deployment intent.",
                    )
                )
            if net is not None:
                state["last_bridge_network"] = str(net)
            if b_data.get("stub") is True:
                info_lines.append(
                    "[INFO] Bridge reports stub mode (no live Midnight transactions) — "
                    "expected for local/dev."
                )

    # --- 4) Work queue signal ---
    if active_jobs is not None:
        prev = state.get("last_active_jobs")
        if prev is not None:
            try:
                pi = int(prev)
            except (TypeError, ValueError):
                pi = None
            if pi is not None:
                if pi == 0 and active_jobs > 0:
                    alerts.append(
                        (
                            SEV_WORK,
                            f"Work queue: active_jobs went from 0 to {active_jobs}. "
                            f"New runnable jobs may need operator attention.",
                        )
                    )
                elif active_jobs - pi >= 5:
                    alerts.append(
                        (
                            SEV_WORK,
                            f"Work queue spike: active_jobs {pi} → {active_jobs} "
                            f"(+{active_jobs - pi}). Check for backlog or hiring needs.",
                        )
                    )
        state["last_active_jobs"] = active_jobs

    # --- 5) Daily skill freshness ---
    now = time.time()
    last_chk = float(state.get("last_skill_check_ts") or 0.0)
    if now - last_chk >= 86400.0:
        state["last_skill_check_ts"] = now
        local_ver: str | None = None
        if local_skill.is_file():
            try:
                local_ver = skill_version_from_markdown(
                    local_skill.read_text(encoding="utf-8")
                )
            except OSError:
                local_ver = None
        raw_r, code_r, err_r = http_get(REMOTE_SKILL_URL, timeout=20.0)
        remote_ver: str | None = None
        if code_r == 200 and raw_r:
            remote_ver = skill_version_from_markdown(raw_r.decode("utf-8", errors="replace"))
        if remote_ver and local_ver and remote_ver != local_ver:
            last_n = state.get("last_notified_remote_skill_version")
            if last_n != remote_ver:
                alerts.append(
                    (
                        SEV_VERSION,
                        f"Skill update available: GitHub SKILL.md version {remote_ver} "
                        f"vs local {local_ver}. Run `npx nightpay init` or sync the skill.",
                    )
                )
                state["last_notified_remote_skill_version"] = remote_ver
        elif not remote_ver and code_r != 200:
            info_lines.append(
                f"[INFO] Could not fetch remote SKILL.md ({err_r or 'HTTP ' + str(code_r)}) "
                f"— skipped version compare."
            )

    # --- 6) Deadline radar ---
    # Policy windows mirror the constants used by gateway.sh / mip003-server.sh
    # and exposed via `gateway.sh schedule`. Env overrides keep a single source
    # of truth across the three runtimes.
    escrow_timeout_minutes = int(os.environ.get("ESCROW_TIMEOUT_MINUTES", "60") or "60")
    optimistic_hours = int(os.environ.get("OPTIMISTIC_WINDOW_HOURS", "48") or "48")
    unclaimed_hours = int(os.environ.get("UNCLAIMED_REFUND_HOURS", "24") or "24")
    mainnet_date_raw = os.environ.get("MIDNIGHT_MAINNET_DATE", DEFAULT_MAINNET_DATE)

    notified: dict[str, Any] = state.get("notified_deadlines") or {}
    if not isinstance(notified, dict):
        notified = {}

    jobs_url = f"{api_base}/jobs?status=running&limit=50"
    raw_j, code_j, _err_j = http_get(jobs_url, timeout=10.0)
    jobs_data, _parse_err_j = parse_json_body(raw_j)
    jobs_list: list[dict[str, Any]] = []
    if code_j == 200 and isinstance(jobs_data, dict):
        jobs_raw = jobs_data.get("jobs")
        if isinstance(jobs_raw, list):
            jobs_list = [j for j in jobs_raw if isinstance(j, dict)]

    now_ts = time.time()
    live_keys: set[str] = set()

    # Reuse the same timer table for every job to stay DRY with the gateway.sh
    # `schedule` output (agents see matching field names and severities).
    def _maybe_alert(job_id: str, timer: str, deadline_ts: float | None, human: str) -> None:
        if not deadline_ts or not job_id:
            return
        remaining = deadline_ts - now_ts
        bucket = classify_bucket(remaining)
        if bucket is None:
            return
        key = f"{job_id}:{timer}"
        live_keys.add(key)
        prev = notified.get(key)
        if prev and _bucket_rank(prev) <= _bucket_rank(bucket):
            return
        notified[key] = bucket
        hours = round(remaining / 3600, 2)
        if bucket == "expired":
            msg = (f"Deadline EXPIRED: job_id={job_id} {human} "
                   f"({hours}h overdue). Run `gateway.sh schedule {job_id}`.")
        elif bucket == "lt_1h":
            msg = (f"Deadline <1h: job_id={job_id} {human} in {hours}h. "
                   f"Review via `gateway.sh schedule {job_id}`.")
        else:
            msg = (f"Deadline <6h: job_id={job_id} {human} in {hours}h.")
        alerts.append((SEV_DEADLINE, msg))

    for j in jobs_list:
        jid = str(j.get("job_id") or "")
        started = parse_iso(j.get("started_at") or j.get("startedAt"))
        approved = parse_iso(j.get("approved_at") or j.get("approvedAt"))
        voting_ends = parse_iso(j.get("voting_ends_at") or (j.get("voting") or {}).get("ends_at"))

        if started is not None:
            _maybe_alert(jid, "escrow_timeout",
                         started + escrow_timeout_minutes * 60,
                         "escrow timeout")
            _maybe_alert(jid, "unclaimed_refund_at",
                         started + unclaimed_hours * 3600,
                         "unclaimed-refund threshold")
        if approved is not None:
            _maybe_alert(jid, "optimistic_autocomplete_at",
                         approved + optimistic_hours * 3600,
                         "optimistic auto-complete")
        if voting_ends is not None:
            _maybe_alert(jid, "voting_ends", voting_ends, "voting window closes")

    # Garbage-collect notifications for jobs that are no longer active so the
    # state file stays bounded. Only drop keys that are not part of the current
    # /jobs response AND whose bucket is "expired" — expired past entries are
    # the common case where the job has moved off the running board.
    if live_keys or jobs_list:
        notified = {k: v for k, v in notified.items() if k in live_keys or v != "expired"}
    state["notified_deadlines"] = notified

    # Mainnet milestone: one-shot notice within 30 days of the cutover.
    mainnet_ts = parse_iso(mainnet_date_raw)
    if mainnet_ts is not None:
        days_to_mainnet = (mainnet_ts - now_ts) / 86400.0
        if 0 <= days_to_mainnet <= MAINNET_NOTIFY_WITHIN_DAYS:
            if not state.get("mainnet_milestone_notified"):
                alerts.append((
                    SEV_DEADLINE,
                    f"Midnight mainnet (Kūkolu) in {round(days_to_mainnet, 1)}d "
                    f"({mainnet_date_raw}). Review mainnet migration checklist "
                    f"before switching MIDNIGHT_NETWORK.",
                ))
                state["mainnet_milestone_notified"] = True
        elif days_to_mainnet < 0 and state.get("mainnet_milestone_notified"):
            # Reset after the milestone passes so a future re-scheduling re-alerts.
            state["mainnet_milestone_notified"] = False

    save_state(state_path, state)

    for line in info_lines:
        print(line)

    if alerts:
        for _sev, msg in sorted(alerts, key=lambda x: x[0]):
            print(msg)
        return 1

    print("HEARTBEAT_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        raise SystemExit(0)
