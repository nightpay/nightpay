#!/usr/bin/env bash
# nightpay setup — one-command onboarding for any agent platform
#
# Detects your platform, copies skill files, validates env,
# runs health check. Zero manual steps.
#
# Usage:
#   bash setup.sh                    # auto-detect platform
#   bash setup.sh --platform openclaw
#   bash setup.sh --platform claude-code
#   bash setup.sh --platform cursor
#   bash setup.sh --platform copilot
#   bash setup.sh --platform raw
#   bash setup.sh --validate-only    # just check env + health
#   bash setup.sh --help
#
# Environment:
#   NIGHTPAY_WORKSPACE   Override target directory (default: auto-detect)
#   MASUMI_API_KEY        Required — Masumi payment API key
#   OPERATOR_ADDRESS      Required — 64-char hex Midnight operator address
#   NIGHTPAY_API_URL      Required — Deployed MIP-003 API base URL
#   BRIDGE_URL            Recommended — Midnight bridge URL

set -euo pipefail

# ─── Colors (disabled when not a TTY) ─────────────────────────────────────────
if [[ -t 2 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  CHECK="✅"; CROSS="❌"; WARN="⚠️"; ARROW="→"
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
  CHECK="OK"; CROSS="FAIL"; WARN="WARN"; ARROW="->"
fi

# ─── Script location ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_SRC="$REPO_ROOT/skills/nightpay"

# ─── Defaults ─────────────────────────────────────────────────────────────────
PLATFORM=""
VALIDATE_ONLY=false
ERRORS=0
WARNINGS=0

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<HELP
${BOLD}nightpay setup${RESET} — one-command agent onboarding

${BOLD}USAGE${RESET}
  bash setup.sh [OPTIONS]

${BOLD}OPTIONS${RESET}
  --platform <name>    Force platform: openclaw, claude-code, cursor, copilot, raw
  --validate-only      Skip install, just validate env + connectivity
  --workspace <path>   Override target directory
  --help               This message

${BOLD}EXAMPLES${RESET}
  bash setup.sh                          # auto-detect and install
  bash setup.sh --platform claude-code   # force Claude Code setup
  bash setup.sh --validate-only          # just check everything works

${BOLD}ENVIRONMENT${RESET}
  MASUMI_API_KEY       ${RED}Required${RESET}  Masumi payment API key
  OPERATOR_ADDRESS     ${RED}Required${RESET}  Midnight operator shielded address
  NIGHTPAY_API_URL     ${RED}Required${RESET}  Deployed MIP-003 API URL
  BRIDGE_URL           ${YELLOW}Recommended${RESET}  Midnight bridge URL
  MIDNIGHT_NETWORK     ${DIM}Optional${RESET}   preprod (default) or mainnet
HELP
  exit 0
}

# ─── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)    PLATFORM="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --workspace)   NIGHTPAY_WORKSPACE="$2"; shift 2 ;;
    --help|-h)     usage ;;
    *)             echo "${RED}Unknown option: $1${RESET}"; usage ;;
  esac
done

# ─── Platform detection ───────────────────────────────────────────────────────
detect_platform() {
  if [[ -n "$PLATFORM" ]]; then
    echo "$PLATFORM"
    return
  fi

  # Check for OpenClaw
  if command -v openclaw &>/dev/null; then
    echo "openclaw"
    return
  fi

  # Check for Claude Code markers
  if [[ -d ".claude" ]] || [[ -f ".claude/settings.json" ]]; then
    echo "claude-code"
    return
  fi

  # Check for Cursor markers
  if [[ -d ".cursor" ]] || [[ -f ".cursorrules" ]]; then
    echo "cursor"
    return
  fi

  # Check for Copilot markers
  if [[ -d ".github" ]] && [[ -f ".github/copilot-instructions.md" ]]; then
    echo "copilot"
    return
  fi

  # Default to raw
  echo "raw"
}

# ─── Logging ──────────────────────────────────────────────────────────────────
info()  { echo "  ${CYAN}${ARROW}${RESET} $*"; }
ok()    { echo "  ${GREEN}${CHECK}${RESET} $*"; }
warn()  { echo "  ${YELLOW}${WARN}${RESET} $*"; ((WARNINGS++)); }
fail()  { echo "  ${RED}${CROSS}${RESET} $*"; ((ERRORS++)); }

header() {
  echo ""
  echo "${BOLD}$*${RESET}"
  echo "${DIM}$(printf '%.0s─' $(seq 1 ${#1}))${RESET}"
}

# ─── Prerequisite check ──────────────────────────────────────────────────────
check_prerequisites() {
  header "Checking prerequisites"

  local bins=(bash curl openssl sqlite3)
  for bin in "${bins[@]}"; do
    if command -v "$bin" &>/dev/null; then
      ok "$bin found: $(command -v "$bin")"
    else
      fail "$bin not found — required by gateway.sh"
    fi
  done

  # sha256sum or shasum
  if command -v sha256sum &>/dev/null; then
    ok "sha256sum found"
  elif command -v shasum &>/dev/null; then
    ok "shasum found (macOS — compatible)"
  else
    fail "sha256sum/shasum not found — required for hash verification"
  fi
}

# ─── Env validation ──────────────────────────────────────────────────────────
validate_env() {
  header "Validating environment variables"

  # Required vars
  local required_vars=("MASUMI_API_KEY" "OPERATOR_ADDRESS" "NIGHTPAY_API_URL" "BRIDGE_URL")
  local required_labels=("Masumi API key" "Operator address" "NightPay API URL" "Bridge URL")

  for i in "${!required_vars[@]}"; do
    local var="${required_vars[$i]}"
    local label="${required_labels[$i]}"
    local val="${!var:-}"

    if [[ -z "$val" ]]; then
      fail "$var not set — $label is required"
    elif [[ "$val" == "$var" ]]; then
      fail "$var is set to placeholder value '$var' — replace with real value"
    else
      # Sanity checks per var
      case "$var" in
        OPERATOR_ADDRESS)
          if [[ ${#val} -ne 64 ]] || ! [[ "$val" =~ ^[0-9a-fA-F]+$ ]]; then
            warn "$var doesn't look like a 64-char hex address (got ${#val} chars)"
          else
            ok "$var set (${val:0:8}...${val: -4})"
          fi
          ;;
        NIGHTPAY_API_URL|BRIDGE_URL)
          if [[ "$val" == *"localhost"* ]]; then
            warn "$var points to localhost ($val) — only valid if stack runs locally"
          else
            ok "$var set ($val)"
          fi
          ;;
        *)
          ok "$var set (${val:0:8}...)"
          ;;
      esac
    fi
  done

  # Optional vars
  local opt_vars=("MIDNIGHT_NETWORK" "OPERATOR_FEE_BPS" "RECEIPT_CONTRACT_ADDRESS")
  for var in "${opt_vars[@]}"; do
    local val="${!var:-}"
    if [[ -n "$val" && "$val" != "$var" ]]; then
      ok "$var set ($val)"
    else
      info "$var not set (using default)"
    fi
  done
}

# ─── Connectivity check ──────────────────────────────────────────────────────
check_connectivity() {
  header "Checking connectivity"

  local api_url="${NIGHTPAY_API_URL:-}"
  local bridge_url="${BRIDGE_URL:-}"

  if [[ -n "$api_url" && "$api_url" != "NIGHTPAY_API_URL" ]]; then
    if curl -sf --max-time 10 "${api_url}/availability" > /dev/null 2>&1; then
      ok "NightPay API reachable at $api_url"
    else
      warn "NightPay API not reachable at $api_url (may be offline or wrong URL)"
    fi
  else
    info "Skipping API check — NIGHTPAY_API_URL not set"
  fi

  if [[ -n "$bridge_url" && "$bridge_url" != "BRIDGE_URL" ]]; then
    if curl -sf --max-time 10 "${bridge_url}/health" > /dev/null 2>&1; then
      ok "Bridge reachable at $bridge_url"
    else
      warn "Bridge not reachable at $bridge_url (on-chain mode may not work)"
    fi
  else
    info "Skipping bridge check — BRIDGE_URL not set"
  fi
}

# ─── Install skill files ─────────────────────────────────────────────────────
install_skill() {
  local platform="$1"
  local target="${NIGHTPAY_WORKSPACE:-}"

  header "Installing NightPay skill (platform: $platform)"

  # Determine target directory
  if [[ -z "$target" ]]; then
    case "$platform" in
      openclaw)
        # Try to detect OpenClaw workspace
        local agent_id="${NIGHTPAY_AGENT:-nightpay}"
        if [[ -d "$HOME/.openclaw/workspace-$agent_id" ]]; then
          target="$HOME/.openclaw/workspace-$agent_id/skills/nightpay"
        else
          target="$HOME/.openclaw/workspace-nightpay/skills/nightpay"
        fi
        ;;
      *)
        target="$(pwd)/skills/nightpay"
        ;;
    esac
  fi

  info "Target: $target"

  # Check if already installed
  if [[ -f "$target/SKILL.md" ]]; then
    ok "Skill already installed at $target"
    info "To reinstall, remove the directory first"
    return
  fi

  # Copy skill files
  mkdir -p "$target"
  if [[ -d "$SKILL_SRC" ]]; then
    cp -r "$SKILL_SRC"/* "$target/" 2>/dev/null || true
    cp -r "$SKILL_SRC"/.[!.]* "$target/" 2>/dev/null || true
    ok "Skill files copied to $target"
  else
    fail "Skill source not found at $SKILL_SRC"
    return
  fi

  # Fix permissions
  if [[ -d "$target/scripts" ]]; then
    chmod +x "$target/scripts"/*.sh 2>/dev/null || true
    ok "Script permissions fixed (chmod +x)"
  fi

  # Verify SKILL.md is at the right level (not nested)
  if [[ -f "$target/SKILL.md" ]]; then
    ok "SKILL.md found at correct level"
  elif [[ -f "$target/skills/nightpay/SKILL.md" ]]; then
    warn "SKILL.md is nested — flattening..."
    cp -r "$target/skills/nightpay"/* "$target/"
    ok "Flattened: SKILL.md now at correct level"
  else
    fail "SKILL.md not found — install may be incomplete"
  fi
}

# ─── Platform-specific setup ─────────────────────────────────────────────────
setup_platform() {
  local platform="$1"
  local target="${NIGHTPAY_WORKSPACE:-$(pwd)/skills/nightpay}"

  header "Platform-specific setup ($platform)"

  case "$platform" in
    openclaw)
      info "OpenClaw: skill will be auto-discovered from workspace"
      info "Merge env vars into openclaw.json → skills.entries.nightpay.env"

      # Check if openclaw-fragment.json has placeholder values
      if [[ -f "$REPO_ROOT/openclaw-fragment.json" ]]; then
        local placeholders
        placeholders=$(grep -c '"MASUMI_API_KEY": "MASUMI_API_KEY"' "$REPO_ROOT/openclaw-fragment.json" 2>/dev/null || echo 0)
        if [[ "$placeholders" -gt 0 ]]; then
          warn "openclaw-fragment.json has placeholder values — replace before merging"
        fi
      fi
      ;;

    claude-code)
      # Create .claude/commands/ wrapper if not exists
      local cmd_dir="$(pwd)/.claude/commands"
      if [[ ! -f "$cmd_dir/nightpay.md" ]]; then
        mkdir -p "$cmd_dir"
        cat > "$cmd_dir/nightpay.md" << 'CLAUDE_CMD'
---
description: "Run NightPay bounty operations"
---

Use the NightPay skill at `skills/nightpay/SKILL.md` for anonymous community bounty operations.

Available commands via `bash skills/nightpay/scripts/gateway.sh`:
- `create-pool <description> <contribution_specks> <goal_specks>`
- `fund-pool <pool_commitment>`
- `pool-status <pool_commitment>`
- `post-bounty <description> <amount_specks>`
- `find-agent <capability>`
- `hire-and-pay <agent_id> <description> <commitment_hash>`
- `stats`
CLAUDE_CMD
        ok "Created .claude/commands/nightpay.md"
      else
        ok ".claude/commands/nightpay.md already exists"
      fi
      ;;

    cursor)
      # Create .cursor/rules/ wrapper if not exists
      local rules_dir="$(pwd)/.cursor/rules"
      if [[ ! -f "$rules_dir/nightpay.md" ]]; then
        mkdir -p "$rules_dir"
        cat > "$rules_dir/nightpay.md" << 'CURSOR_RULE'
# NightPay Bounty Skill

When the user asks about bounties, community funding, or anonymous payments, use the NightPay skill.

## Available commands

Run these via the terminal:
```bash
bash skills/nightpay/scripts/gateway.sh create-pool "description" 5000 25000
bash skills/nightpay/scripts/gateway.sh fund-pool <pool_commitment>
bash skills/nightpay/scripts/gateway.sh post-bounty "description" 10000
bash skills/nightpay/scripts/gateway.sh find-agent "code review"
bash skills/nightpay/scripts/gateway.sh stats
```

Required env: MASUMI_API_KEY, OPERATOR_ADDRESS, NIGHTPAY_API_URL, BRIDGE_URL.
See `skills/nightpay/SKILL.md` for full documentation.
CURSOR_RULE
        ok "Created .cursor/rules/nightpay.md"
      else
        ok ".cursor/rules/nightpay.md already exists"
      fi
      ;;

    copilot)
      # Add to .github/copilot-instructions.md
      local copilot_file="$(pwd)/.github/copilot-instructions.md"
      if [[ -f "$copilot_file" ]] && grep -q "NightPay" "$copilot_file"; then
        ok "NightPay already in copilot-instructions.md"
      else
        mkdir -p "$(pwd)/.github"
        cat >> "$copilot_file" << 'COPILOT_INST'

## NightPay Bounty Skill

This project includes the NightPay anonymous bounty skill at `skills/nightpay/`.
When asked about bounties, anonymous funding, or agent payments, use:
`bash skills/nightpay/scripts/gateway.sh <command> [args]`

Commands: create-pool, fund-pool, pool-status, post-bounty, find-agent,
hire-and-pay, check-job, complete, refund, stats.

See `skills/nightpay/SKILL.md` for full documentation.
Required env: MASUMI_API_KEY, OPERATOR_ADDRESS, NIGHTPAY_API_URL, BRIDGE_URL.
COPILOT_INST
        ok "Added NightPay section to .github/copilot-instructions.md"
      fi
      ;;

    raw)
      ok "Raw mode — no platform-specific setup needed"
      info "Run: bash skills/nightpay/scripts/gateway.sh stats"
      ;;
  esac
}

# ─── Gateway smoke test ──────────────────────────────────────────────────────
smoke_test() {
  header "Smoke test"

  local gateway=""
  local target="${NIGHTPAY_WORKSPACE:-$(pwd)/skills/nightpay}"

  if [[ -f "$target/scripts/gateway.sh" ]]; then
    gateway="$target/scripts/gateway.sh"
  elif [[ -f "$REPO_ROOT/skills/nightpay/scripts/gateway.sh" ]]; then
    gateway="$REPO_ROOT/skills/nightpay/scripts/gateway.sh"
  fi

  if [[ -z "$gateway" ]]; then
    warn "gateway.sh not found — skipping smoke test"
    return
  fi

  if bash "$gateway" stats > /dev/null 2>&1; then
    ok "gateway.sh stats — passed"
  else
    warn "gateway.sh stats failed — API may be offline or env vars missing"
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
summary() {
  header "Setup Summary"

  if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
    echo ""
    echo "  ${GREEN}${BOLD}NightPay is ready!${RESET} ${CHECK}"
    echo ""
    echo "  Try: ${CYAN}bash skills/nightpay/scripts/gateway.sh stats${RESET}"
    echo ""
  elif [[ $ERRORS -eq 0 ]]; then
    echo ""
    echo "  ${YELLOW}${BOLD}NightPay installed with $WARNINGS warning(s)${RESET}"
    echo ""
    echo "  Review the warnings above. The skill may work, but some"
    echo "  features might be limited."
    echo ""
  else
    echo ""
    echo "  ${RED}${BOLD}Setup incomplete: $ERRORS error(s), $WARNINGS warning(s)${RESET}"
    echo ""
    echo "  Fix the errors above and run again:"
    echo "  ${CYAN}bash setup.sh --validate-only${RESET}"
    echo ""
  fi

  return $ERRORS
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "${BOLD}NightPay Agent Onboarding${RESET} v0.2.4"
  echo "${DIM}Anonymous community bounties for AI agents${RESET}"
  echo ""

  PLATFORM=$(detect_platform)
  info "Detected platform: ${BOLD}$PLATFORM${RESET}"

  check_prerequisites

  if [[ "$VALIDATE_ONLY" == false ]]; then
    install_skill "$PLATFORM"
    setup_platform "$PLATFORM"
  fi

  validate_env
  check_connectivity
  smoke_test
  summary
}

main
