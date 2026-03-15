#!/usr/bin/env node
// NightPay OpenClaw plugin entrypoint — v0.3.5
// openclaw.extensions → satisfies `openclaw plugins install nightpay`
// openclaw.plugin.json skills[] → auto-discovers skills/nightpay/ (no npx init needed)

import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const REQUIRED_ENV = ["MASUMI_API_KEY", "OPERATOR_ADDRESS", "BRIDGE_URL"];
const DEFAULTS = {
  NIGHTPAY_API_URL: "https://api.nightpay.dev",
  MIDNIGHT_NETWORK: "preprod",
  OPERATOR_FEE_BPS: "200",
};

// Compact system context injected into every agent run when nightpay is configured.
// Full detail is in skills/nightpay/SKILL.md, AGENTS.md, and ontology/ontology.md
// (auto-loaded by OpenClaw via openclaw.plugin.json skills field).
const SYSTEM_CONTEXT = `
## NightPay Skill Active

Anonymous community bounty pools — Midnight ZK proofs · Masumi agent hiring · Cardano settlement.

### Activation triggers
Activate when user says: "bounty", "nightpay", "create a pool", "fund this", "anonymous bounty",
"community bounty", "bounty board", "crowdfund", "hire an agent", "post a bounty".

### Pool lifecycle
funding → activated (goal met) → completed (work done + ZK receipt minted)
       └→ expired (deadline passed, goal unmet) → claimRefund (100% returned to funders)

### Job lifecycle
running → awaiting_approval → completed | disputed | refunded

### Key tools (use gateway.sh or MIP-003 API)
- create_pool(description, contributionAmountSpecks, fundingGoalSpecks, maxFunders)
- fund_pool(poolCommitment, funderNullifier)
- submit_work(jobId, workOutput, bountyCommitment, outputHash)
- verify_receipt(receiptHash) — proves ZK system is working
- get_ontology() → GET /ontology (full JSON-LD, call before complex operations)

### Pre-flight (ALWAYS run before funding or accepting work)
1. GET /availability — operator online?
2. gateway.sh stats → operatorFeeBps ≤ 500 (5%)? initialized = 1?
3. verify-receipt <any_hash> — ZK system OK?

### CRITICAL privacy rule
NEVER log, store, or expose funderNullifier, nonce, or funder identity in any form.
These are the funder's private keys. Exposure breaks the privacy model.
Use encrypted credential storage (memoryId pattern) when available.

### Amounts
Always in specks. 1 NIGHT = 1,000,000 specks.

### Full docs
- SKILL.md — tools, config, trust model, credential storage
- AGENTS.md — roles, decision trees, guardrails
- ontology/ontology.md — concepts, lifecycles, contest mode, worked examples
`.trim();

function resolveEnv(config) {
  return config?.skills?.entries?.nightpay?.env ?? {};
}

function missingEnv(env) {
  return REQUIRED_ENV.filter((k) => !env[k] || env[k] === k);
}

const plugin = {
  id: "nightpay",
  name: "NightPay",
  description:
    "Anonymous community bounties — Midnight ZK proofs + Masumi settlement + Cardano finality",
  configSchema: { safeParse: () => ({ success: true }) },

  register(api) {
    // Warn on gateway start if env not configured
    api.on("gateway_start", async () => {
      const env = resolveEnv(api.config);
      const missing = missingEnv(env);
      if (missing.length > 0) {
        api.logger.warn(
          `[nightpay] ${missing.length} env var(s) unconfigured: ${missing.join(", ")}. ` +
            `Set via: openclaw config set skills.entries.nightpay.env.<KEY> "value"`
        );
      } else {
        const url = env.NIGHTPAY_API_URL || DEFAULTS.NIGHTPAY_API_URL;
        api.logger.info(`[nightpay] Plugin ready — ${url} (${env.MIDNIGHT_NETWORK || DEFAULTS.MIDNIGHT_NETWORK})`);
      }
    });

    // Inject skill context into every agent prompt (only when configured)
    api.on("before_prompt_build", async (_event, ctx) => {
      const env = resolveEnv(api.config);
      if (missingEnv(env).length > 0) return; // skip if not configured
      return { appendSystemContext: SYSTEM_CONTEXT };
    });

    // /nightpay slash command — status, config check, quick help
    api.registerCommand({
      name: "nightpay",
      description: "NightPay bounty pool — status, config check, quick help",
      acceptsArgs: true,
      requireAuth: true,
      handler: async (ctx) => {
        const env = resolveEnv(api.config);
        const missing = missingEnv(env);

        if (missing.length > 0) {
          const fixes = missing
            .map((k) => `  openclaw config set skills.entries.nightpay.env.${k} "your-value"`)
            .join("\n");
          return {
            text:
              `⚠️ NightPay not configured — missing: ${missing.join(", ")}\n\n` +
              `Fix:\n${fixes}\n\n` +
              `Then: openclaw gateway restart`,
          };
        }

        const apiUrl = env.NIGHTPAY_API_URL || DEFAULTS.NIGHTPAY_API_URL;
        const network = env.MIDNIGHT_NETWORK || DEFAULTS.MIDNIGHT_NETWORK;
        const feeBps = env.OPERATOR_FEE_BPS || DEFAULTS.OPERATOR_FEE_BPS;
        const args = (ctx.args || "").trim();

        if (!args || args === "status") {
          return {
            text:
              `✅ NightPay ready\n` +
              `  API:     ${apiUrl}\n` +
              `  Network: ${network}\n` +
              `  Fee:     ${feeBps} bps (${(Number(feeBps) / 100).toFixed(1)}%)\n\n` +
              `Say: "create a bounty pool for [task]", "show bounty board", or "fund this anonymously"`,
          };
        }

        return {
          text: `NightPay: handling "${args}" — using skill at skills/nightpay/`,
          agentInstructions: `Use the nightpay skill. Task: ${args}`,
        };
      },
    });
  },
};

export default plugin;
