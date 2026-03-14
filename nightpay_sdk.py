#!/usr/bin/env python3
"""
nightpay_sdk.py — Python SDK for NightPay agent integration.

Handles setup, env validation, gateway calls, health checks, and self-healing.
Works with any agent platform or standalone scripts.

Usage:
    from nightpay_sdk import NightPay

    np = NightPay()                    # auto-discovers skill location
    np.validate()                      # check env + connectivity
    np.stats()                         # get contract stats
    np.post_bounty("Review PR", 5000)  # post a bounty

CLI usage:
    python3 nightpay_sdk.py validate   # validate env + health
    python3 nightpay_sdk.py stats      # get contract stats
    python3 nightpay_sdk.py setup      # run full setup
    python3 nightpay_sdk.py doctor     # diagnose and fix issues
"""

import os
import sys
import json
import shutil
import subprocess
import urllib.request
import urllib.error
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class ValidationResult:
    """Result of a validation check."""
    name: str
    passed: bool
    message: str
    severity: str = "error"  # error, warning, info
    fix_hint: Optional[str] = None

    def __str__(self):
        icon = "OK" if self.passed else ("WARN" if self.severity == "warning" else "FAIL")
        s = f"  [{icon}] {self.name}: {self.message}"
        if not self.passed and self.fix_hint:
            s += f"\n        Fix: {self.fix_hint}"
        return s


@dataclass
class HealthReport:
    """Complete health check report."""
    checks: list = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return all(c.passed for c in self.checks if c.severity == "error")

    @property
    def errors(self) -> int:
        return sum(1 for c in self.checks if not c.passed and c.severity == "error")

    @property
    def warnings(self) -> int:
        return sum(1 for c in self.checks if not c.passed and c.severity == "warning")

    def add(self, name, passed, message, severity="error", fix_hint=None):
        self.checks.append(ValidationResult(name, passed, message, severity, fix_hint))
        return self

    def __str__(self):
        lines = [str(c) for c in self.checks]
        if self.passed:
            lines.append(f"\n  NightPay is healthy ({len(self.checks)} checks passed)")
        else:
            lines.append(f"\n  Issues: {self.errors} error(s), {self.warnings} warning(s)")
        return "\n".join(lines)

    def to_dict(self):
        return {
            "healthy": self.passed,
            "errors": self.errors,
            "warnings": self.warnings,
            "checks": [
                {"name": c.name, "passed": c.passed, "message": c.message,
                 "severity": c.severity, "fix_hint": c.fix_hint}
                for c in self.checks
            ]
        }


class NightPay:
    """NightPay SDK — setup, validate, and interact with NightPay."""

    REQUIRED_ENV = {
        "MASUMI_API_KEY": "Masumi payment API key",
        "OPERATOR_ADDRESS": "64-char hex Midnight operator shielded address",
        "NIGHTPAY_API_URL": "Deployed MIP-003 API base URL",
        "BRIDGE_URL": "Midnight bridge URL",
    }

    REQUIRED_BINS = ["bash", "curl", "openssl", "sqlite3"]

    def __init__(self, skill_path: Optional[str] = None):
        """Initialize NightPay SDK.

        Args:
            skill_path: Path to nightpay skill directory.
                        Auto-discovers if not provided.
        """
        self.skill_path = Path(skill_path) if skill_path else self._discover_skill()
        self.gateway = self.skill_path / "scripts" / "gateway.sh" if self.skill_path else None

    def _discover_skill(self) -> Optional[Path]:
        """Auto-discover skill location."""
        candidates = [
            Path.cwd() / "skills" / "nightpay",
            Path.home() / ".openclaw" / "workspace-nightpay" / "skills" / "nightpay",
            Path(__file__).parent,
            Path(__file__).parent.parent / "skills" / "nightpay",
        ]
        for p in candidates:
            if (p / "SKILL.md").exists():
                return p
            # Check for nested structure
            if (p / "skills" / "nightpay" / "SKILL.md").exists():
                return p / "skills" / "nightpay"
        return None

    # ─── Validation ───────────────────────────────────────────────────────

    def validate(self, verbose: bool = True) -> HealthReport:
        """Run full validation: prerequisites, env, connectivity, skill files."""
        report = HealthReport()

        # Prerequisites
        for b in self.REQUIRED_BINS:
            found = shutil.which(b) is not None
            report.add(f"bin:{b}", found,
                       f"{b} found" if found else f"{b} not found",
                       fix_hint=f"Install {b} via your package manager")

        # sha256sum or shasum
        has_hash = shutil.which("sha256sum") or shutil.which("shasum")
        report.add("bin:sha256sum", bool(has_hash),
                    "sha256sum/shasum found" if has_hash else "neither found",
                    fix_hint="Install coreutils (Linux) or use shasum (macOS)")

        # Env vars
        for var, desc in self.REQUIRED_ENV.items():
            val = os.environ.get(var, "")
            if not val:
                report.add(f"env:{var}", False, f"not set — {desc}",
                           fix_hint=f"export {var}='your-value'")
            elif val == var:
                report.add(f"env:{var}", False,
                           f"set to placeholder '{var}' — replace with real value",
                           fix_hint=f"export {var}='actual-value-here'")
            else:
                # Extra validation
                if var == "OPERATOR_ADDRESS":
                    if len(val) != 64 or not all(c in "0123456789abcdefABCDEF" for c in val):
                        report.add(f"env:{var}", False,
                                   f"doesn't look like 64-char hex (got {len(val)} chars)",
                                   severity="warning")
                    else:
                        report.add(f"env:{var}", True,
                                   f"set ({val[:8]}...{val[-4:]})")
                elif var in ("NIGHTPAY_API_URL", "BRIDGE_URL"):
                    if "localhost" in val:
                        report.add(f"env:{var}", True, f"set ({val})",
                                   severity="warning",
                                   fix_hint="localhost only works if stack runs locally")
                    else:
                        report.add(f"env:{var}", True, f"set ({val})")
                else:
                    report.add(f"env:{var}", True, f"set ({val[:8]}...)")

        # Skill files
        if self.skill_path and (self.skill_path / "SKILL.md").exists():
            report.add("skill:SKILL.md", True, f"found at {self.skill_path}")
        else:
            report.add("skill:SKILL.md", False, "not found",
                       fix_hint="Run: npx nightpay init (or bash setup.sh)")

        if self.gateway and self.gateway.exists():
            is_exec = os.access(str(self.gateway), os.X_OK)
            report.add("skill:gateway.sh", True,
                       f"found {'(executable)' if is_exec else '(NOT executable)'}")
            if not is_exec:
                report.add("skill:gateway.sh:exec", False,
                           "gateway.sh is not executable",
                           fix_hint=f"chmod +x {self.gateway}")
        else:
            report.add("skill:gateway.sh", False, "not found",
                       fix_hint="Reinstall skill files")

        # Connectivity
        api_url = os.environ.get("NIGHTPAY_API_URL", "")
        if api_url and api_url != "NIGHTPAY_API_URL":
            try:
                req = urllib.request.Request(f"{api_url}/availability",
                                            method="GET")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    report.add("connectivity:api", True,
                               f"API reachable ({resp.status})")
            except Exception as e:
                report.add("connectivity:api", False,
                           f"API unreachable: {e}",
                           severity="warning",
                           fix_hint="Check NIGHTPAY_API_URL and ensure stack is running")

        bridge_url = os.environ.get("BRIDGE_URL", "")
        if bridge_url and bridge_url != "BRIDGE_URL":
            try:
                req = urllib.request.Request(f"{bridge_url}/health",
                                            method="GET")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    report.add("connectivity:bridge", True,
                               f"Bridge reachable ({resp.status})")
            except Exception as e:
                report.add("connectivity:bridge", False,
                           f"Bridge unreachable: {e}",
                           severity="warning",
                           fix_hint="Check BRIDGE_URL — on-chain mode may not work")

        if verbose:
            print(report)

        return report

    # ─── Self-healing doctor ──────────────────────────────────────────────

    def doctor(self, auto_fix: bool = False) -> HealthReport:
        """Diagnose issues and optionally auto-fix them."""
        report = self.validate(verbose=False)

        fixes_applied = 0

        for check in report.checks:
            if check.passed:
                continue

            if auto_fix:
                # Auto-fix permissions
                if check.name == "skill:gateway.sh:exec" and self.gateway:
                    os.chmod(str(self.gateway), 0o755)
                    check.passed = True
                    check.message = "fixed: chmod +x applied"
                    fixes_applied += 1

                # Auto-fix nested SKILL.md
                if check.name == "skill:SKILL.md" and self.skill_path:
                    nested = self.skill_path / "skills" / "nightpay" / "SKILL.md"
                    if nested.exists():
                        import shutil as sh
                        nested_dir = self.skill_path / "skills" / "nightpay"
                        for item in nested_dir.iterdir():
                            dest = self.skill_path / item.name
                            if item.is_dir():
                                sh.copytree(str(item), str(dest),
                                            dirs_exist_ok=True)
                            else:
                                sh.copy2(str(item), str(dest))
                        check.passed = True
                        check.message = "fixed: flattened nested skill directory"
                        fixes_applied += 1

        print(report)
        if fixes_applied:
            print(f"\n  Auto-fixed {fixes_applied} issue(s)")

        return report

    # ─── Gateway commands ─────────────────────────────────────────────────

    def _run_gateway(self, *args) -> subprocess.CompletedProcess:
        """Run a gateway.sh command."""
        if not self.gateway or not self.gateway.exists():
            raise FileNotFoundError(
                "gateway.sh not found. Run setup first: bash setup.sh")
        return subprocess.run(
            ["bash", str(self.gateway)] + list(args),
            capture_output=True, text=True, timeout=30
        )

    def stats(self) -> dict:
        """Get contract statistics."""
        result = self._run_gateway("stats")
        if result.returncode != 0:
            raise RuntimeError(f"stats failed: {result.stderr}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"raw_output": result.stdout.strip()}

    def post_bounty(self, description: str, amount_specks: int) -> dict:
        """Post a simple bounty."""
        result = self._run_gateway("post-bounty", description,
                                   str(amount_specks))
        if result.returncode != 0:
            raise RuntimeError(f"post-bounty failed: {result.stderr}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"raw_output": result.stdout.strip()}

    def create_pool(self, description: str, contribution_specks: int,
                    funding_goal_specks: int) -> dict:
        """Create a bounty pool."""
        result = self._run_gateway("create-pool", description,
                                   str(contribution_specks),
                                   str(funding_goal_specks))
        if result.returncode != 0:
            raise RuntimeError(f"create-pool failed: {result.stderr}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"raw_output": result.stdout.strip()}

    def find_agent(self, capability: str) -> dict:
        """Find agents matching a capability query."""
        result = self._run_gateway("find-agent", capability)
        if result.returncode != 0:
            raise RuntimeError(f"find-agent failed: {result.stderr}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"raw_output": result.stdout.strip()}

    def pool_status(self, pool_commitment: str) -> dict:
        """Check pool status."""
        result = self._run_gateway("pool-status", pool_commitment)
        if result.returncode != 0:
            raise RuntimeError(f"pool-status failed: {result.stderr}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"raw_output": result.stdout.strip()}

    def health_check(self) -> dict:
        """Quick health check — returns JSON-safe result."""
        report = self.validate(verbose=False)
        return report.to_dict()


# ─── CLI ──────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 nightpay_sdk.py <command>")
        print("Commands: validate, stats, setup, doctor, health")
        sys.exit(1)

    cmd = sys.argv[1]
    np = NightPay()

    if cmd == "validate":
        report = np.validate()
        sys.exit(0 if report.passed else 1)

    elif cmd == "doctor":
        auto = "--auto-fix" in sys.argv
        report = np.doctor(auto_fix=auto)
        sys.exit(0 if report.passed else 1)

    elif cmd == "health":
        result = np.health_check()
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["healthy"] else 1)

    elif cmd == "stats":
        try:
            result = np.stats()
            print(json.dumps(result, indent=2))
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)

    elif cmd == "setup":
        # Run bash setup.sh if available
        setup_sh = Path(__file__).parent / "scripts" / "setup.sh"
        if not setup_sh.exists():
            setup_sh = Path(__file__).parent.parent / "scripts" / "setup.sh"
        if setup_sh.exists():
            os.execvp("bash", ["bash", str(setup_sh)] + sys.argv[2:])
        else:
            print("setup.sh not found — run validate instead")
            np.validate()

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
