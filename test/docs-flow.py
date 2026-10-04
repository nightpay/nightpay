"""Public docs stay aligned with the release the marketplace deploy ships."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fail(message):
    raise SystemExit(f"docs-flow: {message}")


def text(path):
    file = ROOT / path
    if not file.is_file():
        fail(f"missing {path}")
    return file.read_text(encoding="utf-8")


def main():
    package = json.loads(text("package.json"))
    version = package["version"]
    skill = text("skills/nightpay/SKILL.md")
    hosted = text("web/skill.md")
    if skill != hosted:
        fail("web/skill.md must be a byte-for-byte copy of skills/nightpay/SKILL.md")
    if f'"version":"{version}"' not in skill and f'"version": "{version}"' not in skill:
        fail(f"SKILL.md metadata version must be {version}")
    readme = text("README.md")
    for needle in ("docs/README.md", "standing", "package.json"):
        if needle not in readme:
            fail(f"README.md missing {needle}")
    marketplace = text("docs/AGENT_MARKETPLACE.md")
    for needle in ("service_offer_mode", "v" + version, "nightpay services"):
        if needle not in marketplace:
            fail(f"docs/AGENT_MARKETPLACE.md missing {needle}")
    index = text("docs/README.md")
    for needle in ("find-a-skill.md", "docs-flow.py", "SKILL.md"):
        if needle not in index:
            fail(f"docs/README.md missing {needle}")
    if not (ROOT / "skills/nightpay/rules/find-a-skill.md").is_file():
        fail("missing skills/nightpay/rules/find-a-skill.md")
    llms = text("web/llms.txt")
    for needle in ("standing", version, "hire-service"):
        if needle not in llms:
            fail(f"web/llms.txt missing {needle}")
    if "docs-flow.py" not in text("CONTRIBUTING.md"):
        fail("CONTRIBUTING.md must require the docs-flow check")
    if "find-a-skill.md" not in text("skills/nightpay/AGENTS.md"):
        fail("skills/nightpay/AGENTS.md must point at the missing-skill rule")
    print(f"docs-flow ok for v{version}")


if __name__ == "__main__":
    main()
