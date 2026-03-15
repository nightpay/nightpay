#!/usr/bin/env node
// NightPay OpenClaw plugin entrypoint -- v0.3.6
// Fix: prependContext (was appendSystemContext -- context was never being injected)
// New: context-aware injection, operating model wired into install

import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const REQUIRED_ENV = ["MASUMI_API_KEY", "OPERATOR_ADDRESS", "BRIDGE_URL"];
const DEFAULTS = {
  NIGHTPAY_API_URL: "https://api.nightpay.dev",
  MIDNIGHT_NETWORK: "preprod",
  OPERATOR_FEE_BPS: "200",
};

// Strong: explicit nightpay intent -> inject full context
const STRONG_TRIGGERS = [
  "nightpay", "bounty pool", "bounty board", "create a pool", "create a bounty",
  "fund this anonymously", "anonymous bounty", "anonymous pool", "crowdfund",
  "masumi", "midnight zk", "cardano bounty", "hire an agent", "post a bounty",
  "claim refund", "zk receipt", "verify receipt", "fund the pool",
];

// Weak: adjacent topics -> inject brief pointer only
const WEAK_TRIGGERS = [
  "bounty", "anonymous fund", "fund the ", "pool ", "pool,", "pool.",
  "funder", "operator fee", "on-chain settlement",
];

// Injected on weak signals or ongoing nightpay thread
const BRIEF_CONTEXT = [
  "## NightPay available",
  "Anonymous community bounty pools on Cardano.",
  'Activate: "create a bounty pool for X", "show bounty board", "fund this anonymously".',
  "Skill docs auto-loaded: SKILL.md / AGENTS.md / ontology/ontology.md",
].join("\n");

// Injected on strong nightpay signals
const FULL_CONTEXT = [
  "## NightPay Skill Active",
  "",
  "Anonymous community bounty pools -- Midnight ZK proofs / Masumi agent hiring / Cardano settlement.",
  "",
  "### Operating model",
  "You are acting as a NightPay operator agent:",
  "1. Help users CREATE bounty pools (description, goal, deadline, max funders)",
  "2. Help funders CONTRIBUTE anonymously via ZK nullifier (NEVER store or log the nullifier)",
  "3. HIRE agents via Masumi MIP-003 when pool activates",
  "4. VERIFY work and release funds on completion",
  "5. HANDLE disputes impartially if work is rejected",
  "",
  "### Pool lifecycle",
  "funding -> activated (goal met) -> completed (ZK receipt minted)",
  "       `-> expired (deadline passed, goal unmet) -> claimRefund (100% returned)",
  "",
  "### Job lifecycle",
  "running -> awaiting_approval -> completed | disputed | refunded",
  "",
  "### Key tools (gateway.sh or MIP-003 API)",
  "- create_pool(description, contributionAmountSpecks, fundingGoalSpecks, maxFunders)",
  "- fund_pool(poolCommitment, funderNullifier)",
  "- submit_work(jobId, workOutput, bountyCommitment, outputHash)",
  "- verify_receipt(receiptHash)",
  "- get_ontology() -> GET /ontology  -- call before complex ops",
  "",
  "### Pre-flight (ALWAYS before funding or accepting work)",
  "1. GET /availability -- operator online?",
  "2. gateway.sh stats -> operatorFeeBps <= 500? initialized = 1?",
  "3. verify-receipt <any_hash> -> ZK system live?",
  "",
  "### CRITICAL privacy rule",
  "NEVER log, store, or expose funderNullifier or nonce.",
  "Use memoryId pattern for encrypted credential storage.",
  "",
  "### Amounts: always in specks. 1 NIGHT = 1,000,000 specks.",
  "Full docs: SKILL.md / AGENTS.md / ontology/ontology.md",
].join("\n");

const OPERATING_MODEL = [
  "NightPay Operating Model -- v0.3.6",
  "=".repeat(50),
  "",
  "POOL CREATION",
  '  User: "create a bounty pool for reviewing this PR"',
  "  Agent: calls create_pool() -> returns poolId + poolCommitment",
  "  Agent: shares poolCommitment with potential funders",
  "",
  "FUNDING (anonymous)",
  "  Funder generates nullifier (ZK private key -- NEVER expose this)",
  "  Funder calls fund_pool(poolCommitment, nullifier)",
  "  When goal met -> pool auto-activates",
  "",
  "HIRING AN AGENT",
  "  Agent calls Masumi MIP-003 to post job from activated pool",
  "  Masumi routes to available agents on the network",
  "",
  "WORK COMPLETION",
  "  Worker: submit_work(jobId, output, commitment, hash)",
  "  Operator: reviews -> approve releases funds + mints ZK receipt",
  "  Funder: verify receipt proves their anonymous contribution was honored",
  "",
  "REFUND PATH",
  "  Pool expires (deadline + goal unmet) -> claimRefund() returns 100% to funders",
  "  Work disputed -> dispute resolution flow (see AGENTS.md)",
  "",
  "ACTIVATION PHRASES",
  '  "create a bounty pool for X"  "show bounty board"  "fund this anonymously"',
  '  "hire an agent to do X"  "post a bounty for X"  "claim refund on pool X"',
  "",
  "COMMANDS",
  "  /nightpay status  -- config + connectivity check",
  "  /nightpay help    -- this message",
  "  /nightpay <task>  -- delegate task to nightpay skill",
  "",
  "DOCS (auto-loaded from installed package)",
  "  SKILL.md              -- full tool reference, trust model, credential patterns",
  "  AGENTS.md             -- roles, decision trees, guardrails",
  "  ontology/ontology.md  -- concepts, lifecycle states, worked examples",
].join("\n");

function resolveEnv(config) {
  return config?.skills?.entries?.nightpay?.env ?? {};
}

function missingEnv(env) {
  return REQUIRED_ENV.filter((k) => !env[k] || env[k] === k || env[k] === "");
}

function detectIntent(prompt, messages) {
  const text = (prompt || "").toLowerCase();
  if (STRONG_TRIGGERS.some((t) => text.includes(t))) return "full";
  if (WEAK_TRIGGERS.some((t) => text.includes(t))) return "brief";

  // Check ongoing conversation thread (last 6 messages)
  if (Array.isArray(messages) && messages.length > 0) {
    const recent = messages.slice(-6).map((m) => {
      if (typeof m === "string") return m.toLowerCase();
      if (typeof m?.content === "string") return m.content.toLowerCase();
      if (Array.isArray(m?.content))
        return m.content.map((c) => c?.text ?? "").join(" ").toLowerCase();
      return "";
    }).join(" ");
    if (STRONG_TRIGGERS.some((t) => recent.includes(t))) return "brief";
    if (WEAK_TRIGGERS.some((t) => recent.includes(t))) return "brief";
  }
  return "none";
}

const plugin = {
  id: "nightpay",
  name: "NightPay",
  description: "Anonymous community bounties -- Midnight ZK proofs + Masumi settlement + Cardano finality",
  configSchema: { safeParse: () => ({ success: true }) },

  register(api) {
    // Log operating model summary + env status on gateway start
    api.on("gateway_start", async () => {
      const env = resolveEnv(api.config);
      const missing = missingEnv(env);
      if (missing.length > 0) {
        api.logger.warn(
          `[nightpay] Plugin loaded -- ${missing.length} credential(s) missing: ${missing.join(", ")}.\n` +
          `  Set: openclaw config set skills.entries.nightpay.env.<KEY> "value"\n` +
          `  Then: openclaw gateway restart\n` +
          `  Operating model: /nightpay help in your channel`
        );
      } else {
        const url = env.NIGHTPAY_API_URL || DEFAULTS.NIGHTPAY_API_URL;
        const net = env.MIDNIGHT_NETWORK || DEFAULTS.MIDNIGHT_NETWORK;
        const fee = env.OPERATOR_FEE_BPS || DEFAULTS.OPERATOR_FEE_BPS;
        api.logger.info(
          `[nightpay] Ready -- ${url} | network: ${net} | fee: ${fee}bps\n` +
          `  Skill docs auto-loaded: SKILL.md / AGENTS.md / ontology/\n` +
          `  Context injected: only on nightpay/bounty/pool keywords (context-aware)\n` +
          `  Type /nightpay help for the full operating model`
        );
      }
    });

    // Context-aware injection -- only fires when conversation is nightpay-relevant
    api.on("before_prompt_build", async (event, ctx) => {
      const env = resolveEnv(api.config);
      if (missingEnv(env).length > 0) return;
      const intent = detectIntent(event.prompt, event.messages);
      if (intent === "none") return;
      return { prependContext: intent === "full" ? FULL_CONTEXT : BRIEF_CONTEXT };
    });

    // /nightpay slash command
    api.registerCommand({
      name: "nightpay",
      description: "NightPay -- status, operating model, config check",
      acceptsArgs: true,
      requireAuth: true,
      handler: async (ctx) => {
        const env = resolveEnv(api.config);
        const missing = missingEnv(env);
        const args = (ctx.args || "").trim();

        // /nightpay help -- always works even if not configured
        if (args === "help") return { text: OPERATING_MODEL };

        if (missing.length > 0) {
          const fixes = missing
            .map((k) => `  openclaw config set skills.entries.nightpay.env.${k} "your-value"`)
            .join("\n");
          return {
            text:
              `NightPay not configured -- missing: ${missing.join(", ")}\n\n` +
              `Fix:\n${fixes}\n\nThen: openclaw gateway restart\n` +
              `Run /nightpay help to see the operating model.`,
          };
        }

        const apiUrl = env.NIGHTPAY_API_URL || DEFAULTS.NIGHTPAY_API_URL;
        const network = env.MIDNIGHT_NETWORK || DEFAULTS.MIDNIGHT_NETWORK;
        const feeBps = env.OPERATOR_FEE_BPS || DEFAULTS.OPERATOR_FEE_BPS;

        if (!args || args === "status") {
          return {
            text:
              `NightPay ready\n` +
              `  API:     ${apiUrl}\n` +
              `  Network: ${network}\n` +
              `  Fee:     ${feeBps} bps (${(Number(feeBps) / 100).toFixed(1)}%)\n\n` +
              `Activation: "create a bounty pool for [task]", "show bounty board", "fund this anonymously"\n` +
              `Full operating model: /nightpay help`,
          };
        }

        return {
          text: `NightPay: handling "${args}"`,
          agentInstructions: `Use the nightpay skill. Task: ${args}. Read SKILL.md for tool reference.`,
        };
      },
    });
  },
};

export default plugin;
