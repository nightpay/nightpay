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

# Severity ordering per HEARTBEAT.md (lower = more urgent)
SEV_SERVICE = 1
SEV_BRIDGE = 2
SEV_WORK = 3
SEV_VERSION = 4

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


def load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {
            "_v": STATE_VERSION,
            "api_fail_streak": 0,
            "ontology_fail_streak": 0,
            "last_active_jobs": None,
            "last_bridge_network": None,
            "last_skill_check_ts": 0.0,
            "last_notified_remote_skill_version": None,
        }
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("not a dict")
        data.setdefault("_v", STATE_VERSION)
        data.setdefault("api_fail_streak", 0)
        data.setdefault("ontology_fail_streak", 0)
        data.setdefault("last_active_jobs", None)
        data.setdefault("last_bridge_network", None)
        data.setdefault("last_skill_check_ts", 0.0)
        data.setdefault("last_notified_remote_skill_version", None)
        return data
    except (OSError, json.JSONDecodeError, ValueError):
        return {
            "_v": STATE_VERSION,
            "api_fail_streak": 0,
            "ontology_fail_streak": 0,
            "last_active_jobs": None,
            "last_bridge_network": None,
            "last_skill_check_ts": 0.0,
            "last_notified_remote_skill_version": None,
        }


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
    td = Path(tempfile.mkdtemp())
    try:
        base = load_state(td / "missing.json")
        base["api_fail_streak"] = 1
        save_state(td / "s.json", base)
        st2 = load_state(td / "s.json")
        assert st2["api_fail_streak"] == 1
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
