#!/usr/bin/env python3
"""Cross-check agent-readable skill surfaces (see docs/architecture.md § Skill distribution)."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "skills" / "nightpay" / "SKILL.md"
HOSTED_MD = ROOT / "ui" / "public" / "skill.md"
HOSTED_JSON = ROOT / "ui" / "public" / "skill.json"
PLUGIN_JS = ROOT / "plugin.js"
PLUGIN_JSON = ROOT / "openclaw.plugin.json"
PACKAGE_JSON = ROOT / "package.json"
SKILL_DOCS = ROOT / "ui" / "src" / "pages" / "SkillDocsPage.tsx"
ONTOLOGY = ROOT / "skills" / "nightpay" / "ontology" / "ontology.jsonld"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        fail(f"{path}: missing YAML frontmatter")
    end = text.find("\n---", 3)
    if end < 0:
        fail(f"{path}: unclosed frontmatter")
    block = text[3:end].strip()
    meta_line = next((ln for ln in block.splitlines() if ln.startswith("metadata:")), None)
    if not meta_line:
        fail(f"{path}: frontmatter missing metadata")
    raw = meta_line.split(":", 1)[1].strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"{path}: metadata JSON invalid: {exc}")


def extract_required_env(plugin_js: Path) -> list[str]:
    text = plugin_js.read_text(encoding="utf-8")
    m = re.search(r'const REQUIRED_ENV = \[(.*?)\];', text, re.S)
    if not m:
        fail(f"{plugin_js}: REQUIRED_ENV not found")
    inner = m.group(1)
    return re.findall(r'"([^"]+)"', inner)


def extract_plugin_version(plugin_js: Path) -> str:
    text = plugin_js.read_text(encoding="utf-8")
    m = re.search(r"NightPay OpenClaw plugin entrypoint -- v(\d+\.\d+\.\d+)", text)
    if not m:
        fail(f"{plugin_js}: plugin version comment not found")
    return m.group(1)


def extract_skill_docs_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    m = re.search(r"const SKILL_VERSION = '(\d+\.\d+\.\d+)';", text)
    if not m:
        fail(f"{path}: SKILL_VERSION constant not found")
    return m.group(1)


def main() -> None:
    errors: list[str] = []

    if not CANONICAL.is_file():
        errors.append(f"missing canonical {CANONICAL}")
    if not HOSTED_MD.is_file():
        errors.append(f"missing hosted mirror {HOSTED_MD}")
    if not HOSTED_JSON.is_file():
        errors.append(f"missing hosted metadata {HOSTED_JSON}")

    if errors:
        for err in errors:
            print(f"FAIL: {err}", file=sys.stderr)
        sys.exit(1)

    canonical_bytes = CANONICAL.read_bytes()
    hosted_bytes = HOSTED_MD.read_bytes()
    if canonical_bytes != hosted_bytes:
        fail("ui/public/skill.md is not a byte-for-byte mirror of skills/nightpay/SKILL.md")

    meta = parse_frontmatter(CANONICAL)
    version = meta.get("openclaw", {}).get("version") or meta.get("version")
    if not version:
        fail("canonical metadata.version missing")

    skill_json = json.loads(HOSTED_JSON.read_text(encoding="utf-8"))
    plugin_manifest = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
    package = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))

    for label, got in (
        ("ui/public/skill.json", skill_json.get("version")),
        ("openclaw.plugin.json", plugin_manifest.get("version")),
        ("package.json", package.get("version")),
        ("plugin.js header", extract_plugin_version(PLUGIN_JS)),
        ("SkillDocsPage.tsx", extract_skill_docs_version(SKILL_DOCS)),
    ):
        if got != version:
            fail(f"version mismatch: canonical={version} {label}={got}")

    canonical_env = meta.get("openclaw", {}).get("requires", {}).get("env", [])
    hosted_env = skill_json.get("openclaw", {}).get("requires", {}).get("env", [])
    plugin_env = extract_required_env(PLUGIN_JS)

    if canonical_env != hosted_env:
        fail(f"requires.env mismatch: canonical={canonical_env} skill.json={hosted_env}")
    if plugin_env != canonical_env:
        fail(f"REQUIRED_ENV mismatch: plugin.js={plugin_env} canonical={canonical_env}")

    canonical_bins = meta.get("openclaw", {}).get("requires", {}).get("bins", [])
    hosted_bins = skill_json.get("openclaw", {}).get("requires", {}).get("bins", [])
    if canonical_bins != hosted_bins:
        fail(f"requires.bins mismatch: canonical={canonical_bins} skill.json={hosted_bins}")

    ontology = json.loads(ONTOLOGY.read_text(encoding="utf-8"))
    if "@context" not in ontology or "@graph" not in ontology:
        fail("ontology.jsonld missing @context or @graph")

    if "nightpay init" not in package.get("bin", {}).get("nightpay", "") and package.get("bin", {}).get("nightpay") != "bin/cli.js":
        pass  # bin wiring checked via presence
    if not (ROOT / "bin" / "cli.js").is_file():
        fail("missing bin/cli.js for npx nightpay init wiring")

    print(f"ok: skill surfaces aligned at v{version}")


if __name__ == "__main__":
    main()
