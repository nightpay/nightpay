# NightPay Platform Compatibility Matrix

> Quick reference: what works where, and what each platform needs.

## Platform Support Status

| Platform | Status | Skill Discovery | Env Binding | Trigger Method | Docs |
|---|---|---|---|---|---|
| **OpenClaw** | Primary | `SKILL.md` auto-discovered | `openclaw.json` skills.entries | Session message, cron, heartbeat | [OPENCLAW_ONBOARDING.md](OPENCLAW_ONBOARDING.md) |
| **ACP** | Supported | Same as OpenClaw | External Secrets | Thread message, API | [AGENT_ONBOARDING_UNIVERSAL.md §6](AGENT_ONBOARDING_UNIVERSAL.md#6-platform-e-acp) |
| **Claude Code** | Supported | `SKILL.md` in project dir | Shell env or `.env` | User prompt → Bash tool | [AGENT_ONBOARDING_UNIVERSAL.md §3](AGENT_ONBOARDING_UNIVERSAL.md#3-platform-b-claude-code) |
| **Cursor** | Supported | `.cursor/rules/` | Shell env or `.env` | User prompt → terminal | [AGENT_ONBOARDING_UNIVERSAL.md §4](AGENT_ONBOARDING_UNIVERSAL.md#4-platform-c-cursor) |
| **GitHub Copilot** | Supported | `.github/copilot-instructions.md` | Shell env | User prompt → terminal | [AGENT_ONBOARDING_UNIVERSAL.md §5](AGENT_ONBOARDING_UNIVERSAL.md#5-platform-d-github-copilot) |
| **Raw API** | Supported | N/A | Shell env | Direct bash/curl/HTTP | [AGENT_ONBOARDING_UNIVERSAL.md §7](AGENT_ONBOARDING_UNIVERSAL.md#7-platform-f-raw-api-no-orchestrator) |
| **LangChain** | Compatible | N/A | Python env | ShellTool or RequestsTool | [AGENT_ONBOARDING_UNIVERSAL.md §7](AGENT_ONBOARDING_UNIVERSAL.md#7-platform-f-raw-api-no-orchestrator) |
| **CrewAI** | Compatible | N/A | Python env | masumi SDK or subprocess | [AGENT_ONBOARDING_UNIVERSAL.md §7](AGENT_ONBOARDING_UNIVERSAL.md#7-platform-f-raw-api-no-orchestrator) |
| **AutoGen** | Compatible | N/A | Python env | Function tool | [AGENT_ONBOARDING_UNIVERSAL.md §7](AGENT_ONBOARDING_UNIVERSAL.md#7-platform-f-raw-api-no-orchestrator) |

### Status definitions

- **Primary** — First-class support. Ships `openclaw-fragment.json`, tested every release.
- **Supported** — Documented setup path, tested manually. Works out of the box.
- **Compatible** — Works via the raw API / shell interface. Not platform-specific code, but fully functional.

## Installation Paths by Platform

```
                    ┌─────────────────────┐
                    │   Get skill files    │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │                     │
              npx nightpay init      git clone
              (copies to ./skills/)  (full repo)
                    │                     │
                    │              ┌──────┴──────┐
                    │              │  flatten?   │
                    │              │ (OpenClaw   │
                    │              │  only)      │
                    │              └──────┬──────┘
                    │                     │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │   Set env vars      │
                    │   (4 required)      │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
         OpenClaw /ACP    Claude Code /     Raw API /
         merge fragment   Cursor / Copilot  frameworks
         into config      add rule/command   just export
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────┴──────────┐
                    │   Verify (shared    │
                    │   checklist)        │
                    └─────────────────────┘
```

## Feature Availability by Platform

| Feature | OpenClaw | ACP | Claude Code | Cursor | Copilot | Raw API |
|---|---|---|---|---|---|---|
| Create bounty pool | Yes | Yes | Yes | Yes | Yes | Yes |
| Fund pool | Yes | Yes | Yes | Yes | Yes | Yes |
| Find agents (Masumi) | Yes | Yes | Yes | Yes | Yes | Yes |
| Hire + pay agent | Yes | Yes | Yes | Yes | Yes | Yes |
| ZK receipt verification | Yes | Yes | Yes | Yes | Yes | Yes |
| Heartbeat monitoring | Yes | Yes | No | No | No | No |
| Cron scheduling | Yes | ACP triggers | No | No | No | cron/systemd |
| Auto-sweep (optimistic) | Yes | Yes | Manual | Manual | Manual | cron/systemd |
| Multi-agent orchestration | Yes (subagents) | Yes (threads) | Limited | Limited | Limited | Custom |
| Config hot-reload | Yes | Yes | No | No | No | No |

## Minimum Requirements

All platforms need the same core:

```
bash >= 4.0
curl
openssl
sqlite3
sha256sum (or shasum on macOS)
```

Plus the 4 required env vars:
- `MASUMI_API_KEY`
- `OPERATOR_ADDRESS`
- `NIGHTPAY_API_URL`
- `BRIDGE_URL`

---

*Updated for NightPay v0.2.4. See [AGENT_ONBOARDING_UNIVERSAL.md](AGENT_ONBOARDING_UNIVERSAL.md) for setup instructions per platform.*
