#!/usr/bin/env node
// NightPay OpenClaw plugin entrypoint -- v0.3.11
// Fix: bridge health probe on gateway_start, RECEIPT_CONTRACT_ADDRESS validation,
//      wallet connectivity status in ready log

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { existsSync, mkdirSync, cpSync, rmSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL_SRC = join(__dirname, "skills", "nightpay");

const REQUIRED_ENV = ["MASUMI_API_KEY", "OPERATOR_ADDRESS", "BRIDGE_URL"];
const WALLET_ENV = ["RECEIPT_CONTRACT_ADDRESS", "OPERATOR_SECRET_KEY"];

const DEFAULTS = {
  NIGHTPAY_API_URL: "https://api.nightpay.dev",
  MIDNIGHT_NETWORK: "preprod",
  OPERATOR_FEE_BPS: "200",
};

const STRONG_TRIGGERS = [
  "nightpay", "bounty pool", "bounty board", "create a pool", "create a bounty",
  "fund this anonymously", "anonymous bounty", "anonymous pool", "crowdfund",
  "masumi", "midnight zk", "cardano bounty", "hire an agent", "post a bounty",
  "claim refund", "zk receipt", "verify receipt", "fund the pool",
];
const WEAK_TRIGGERS = [
  "bounty", "anonymous fund", "fund the ", "pool ", "pool,", "pool.",
  "funder", "operator fee", "on-chain settlement",
];

const BRIEF_CONTEXT = [
  "## NightPay available",
  "Anonymous community bounty pools on Cardano.",
  'Activate: "create a bounty pool for X", "show bounty board", "fund this anonymously".',
  "Skill docs auto-loaded: skills/nightpay/SKILL.md / AGENTS.md / ontology/ontology.md",
].join("\n");

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
  "### Key tools (bridge or MIP-003 API)",
  "- create_pool(description, contributionAmountSpecks, fundingGoalSpecks, maxFunders)",
  "- fund_pool(poolCommitment, funderNullifier)",
  "- submit_work(jobId, workOutput, bountyCommitment, outputHash)",
  "- verify_receipt(receiptHash)",
  "- get_ontology() -> GET /ontology  -- call before complex ops",
  "",
  "### Pre-flight (ALWAYS before funding or accepting work)",
  "1. GET /availability -- operator online?",
  "2. GET BRIDGE_URL/health -> contractAddress + stub status",
  "3. verify-receipt <any_hash> -> ZK system live?",
  "",
  "### CRITICAL privacy rule",
  "NEVER log, store, or expose funderNullifier or nonce.",
  "Use memoryId pattern for encrypted credential storage.",
  "",
  "### Amounts: always in specks. 1 NIGHT = 1,000,000 specks.",
  "Full docs at skills/nightpay/ (copied into your agent workspace by this plugin).",
].join("\n");

const OPERATING_MODEL = [
  "NightPay Operating Model -- v0.3.11",
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
  "  Work disputed -> dispute resolution flow (see skills/nightpay/AGENTS.md)",
  "",
  "WALLET CONNECTIVITY",
  "  Masumi:   NIGHTPAY_API_URL (MIP-003, /availability /start_job /status)",
  "  Cardano:  OPERATOR_ADDRESS (64-char hex, receives operator fees on settlement)",
  "  Midnight: BRIDGE_URL/health (ZK contract, auto-discovered contractAddress)",
  "  Keys:     MASUMI_API_KEY + OPERATOR_SECRET_KEY + RECEIPT_CONTRACT_ADDRESS",
  "",
  "ACTIVATION PHRASES",
  '  "create a bounty pool for X"  "show bounty board"  "fund this anonymously"',
  '  "hire an agent to do X"  "post a bounty for X"  "claim refund on pool X"',
  "",
  "COMMANDS",
  "  /nightpay status  -- config + bridge + connectivity check",
  "  /nightpay help    -- this message",
  "  /nightpay <task>  -- delegate task to nightpay skill",
  "",
  "DOCS (refreshed on every gateway_start)",
  "  skills/nightpay/SKILL.md              -- full tool reference, trust model",
  "  skills/nightpay/AGENTS.md             -- roles, decision trees, guardrails",
  "  skills/nightpay/ontology/ontology.md  -- concepts, lifecycle states, examples",
].join("\n");

function resolveEnv(config) {
  return config?.skills?.entries?.nightpay?.env ?? {};
}

function missingEnv(env) {
  return REQUIRED_ENV.filter((k) => !env[k] || env[k] === k || env[k] === "");
}

function missingWalletEnv(env) {
  return WALLET_ENV.filter((k) => !env[k] || env[k] === k || env[k] === "");
}

function isPlaceholderAddress(addr) {
  if (!addr) return true;
  // Detect obvious placeholders like aabbcc... repeated patterns
  const cleaned = addr.replace(/[^a-f0-9]/gi, "").toLowerCase();
  if (cleaned.length < 32) return true;
  // Check if it's all one repeated pattern (aaaa... or aabb... cycles)
  const unique = new Set(cleaned.split("")).size;
  return unique <= 4; // real hex addresses have more entropy
}

function detectIntent(prompt, messages) {
  const text = (prompt || "").toLowerCase();
  if (STRONG_TRIGGERS.some((t) => text.includes(t))) return "full";
  if (WEAK_TRIGGERS.some((t) => text.includes(t))) return "brief";
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

/**
 * Probe bridge/health: returns { contractAddress, network, stub } or null on failure.
 */
async function probeBridge(bridgeUrl, logger) {
  try {
    const res = await fetch(`${bridgeUrl}/health`, { signal: AbortSignal.timeout(6000) });
    if (!res.ok) {
      logger.warn(`[nightpay] Bridge health check failed: HTTP ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (err) {
    logger.warn(`[nightpay] Bridge unreachable: ${err.message}`);
    return null;
  }
}

/**
 * Copy skills/nightpay into every configured agent workspace.
 * Always removes the existing path first (handles symlinks, real dirs, absent).
 * OpenClaw realpath() rejects symlinks outside workspace root; real files pass.
 */
function wireSkillIntoWorkspaces(config, logger) {
  const workspaces = new Set();
  const defaultWs = config?.agents?.defaults?.workspace;
  if (defaultWs) workspaces.add(defaultWs);
  const agents = config?.agents?.list ?? [];
  for (const agent of agents) {
    if (agent?.workspace) workspaces.add(agent.workspace);
  }
  let wired = 0, errors = 0;
  for (const ws of workspaces) {
    const skillsDir = join(ws, "skills");
    const destPath = join(skillsDir, "nightpay");
    try {
      if (!existsSync(skillsDir)) mkdirSync(skillsDir, { recursive: true });
      rmSync(destPath, { recursive: true, force: true });
      cpSync(SKILL_SRC, destPath, { recursive: true });
      wired++;
    } catch (err) {
      errors++;
      logger.warn(`[nightpay] Could not copy skill docs into ${ws}: ${err.message}`);
    }
  }
  return { wired, errors };
}

const plugin = {
  id: "nightpay",
  name: "NightPay",
  description: "Anonymous community bounties -- Midnight ZK proofs + Masumi settlement + Cardano finality",
  configSchema: { safeParse: () => ({ success: true }) },

  register(api) {
    api.on("gateway_start", async () => {
      // 1. Wire skill docs into all workspaces
      const { wired, errors } = wireSkillIntoWorkspaces(api.config, api.logger);
      api.logger.info(
        `[nightpay] Skill docs refreshed in ${wired} workspace(s)` +
        (errors > 0 ? ` (${errors} error(s))` : "")
      );

      const env = resolveEnv(api.config);
      const missing = missingEnv(env);

      if (missing.length > 0) {
        api.logger.warn(
          `[nightpay] Plugin loaded -- ${missing.length} required credential(s) missing: ${missing.join(", ")}.\n` +
          `  Set: openclaw config set skills.entries.nightpay.env.<KEY> "value"\n` +
          `  Then: openclaw gateway restart\n` +
          `  Run /nightpay help for the operating model`
        );
        return;
      }

      // 2. Probe bridge for Midnight contract + stub status
      const bridgeUrl = env.BRIDGE_URL || "";
      const bridgeHealth = bridgeUrl ? await probeBridge(bridgeUrl, api.logger) : null;

      // 3. Auto-populate RECEIPT_CONTRACT_ADDRESS from bridge if not already set
      if (bridgeHealth?.contractAddress && !env.RECEIPT_CONTRACT_ADDRESS) {
        api.logger.warn(
          `[nightpay] RECEIPT_CONTRACT_ADDRESS not set -- discovered from bridge: ${bridgeHealth.contractAddress}\n` +
          `  Set it: openclaw config set skills.entries.nightpay.env.RECEIPT_CONTRACT_ADDRESS "${bridgeHealth.contractAddress}"`
        );
      }

      // 4. Warn about missing wallet keys
      const missingWallet = missingWalletEnv(env);
      if (missingWallet.length > 0) {
        api.logger.warn(
          `[nightpay] Wallet credentials missing (ZK receipts + operator signing disabled): ${missingWallet.join(", ")}\n` +
          `  RECEIPT_CONTRACT_ADDRESS: from bridge /health (contractAddress field)\n` +
          `  OPERATOR_SECRET_KEY: from your Midnight wallet / operator setup`
        );
      }

      // 5. Warn if operator address looks like a placeholder
      if (isPlaceholderAddress(env.OPERATOR_ADDRESS)) {
        api.logger.warn(
          `[nightpay] OPERATOR_ADDRESS looks like a placeholder ("${env.OPERATOR_ADDRESS?.slice(0, 12)}...").\n` +
          `  Set a real Cardano preprod address (bech32 addr_test1... or 56-byte hex).\n` +
          `  This is where operator fees are sent on successful pool completion.`
        );
      }

      // 6. Build wallet connectivity summary
      const url = env.NIGHTPAY_API_URL || DEFAULTS.NIGHTPAY_API_URL;
      const net = env.MIDNIGHT_NETWORK || DEFAULTS.MIDNIGHT_NETWORK;
      const fee = env.OPERATOR_FEE_BPS || DEFAULTS.OPERATOR_FEE_BPS;

      const bridgeStatus = bridgeHealth
        ? `${bridgeHealth.status}${bridgeHealth.stub ? " (stub/preprod)" : " (live)"} | contract: ${bridgeHealth.contractAddress?.slice(0, 16)}...`
        : "unreachable";

      api.logger.info(
        `[nightpay] Ready -- ${url} | network: ${net} | fee: ${fee}bps\n` +
        `  Masumi (MIP-003): ${url} [API reachable on startup]\n` +
        `  Midnight bridge:  ${bridgeUrl} -> ${bridgeStatus}\n` +
        `  Cardano operator: ${env.OPERATOR_ADDRESS ? env.OPERATOR_ADDRESS.slice(0, 16) + "..." : "NOT SET"}\n` +
        `  ZK receipts:      ${env.RECEIPT_CONTRACT_ADDRESS ? "contract set" : "RECEIPT_CONTRACT_ADDRESS missing"}\n` +
        `  Skill docs:       skills/nightpay/ (in all agent workspaces)\n` +
        `  Type /nightpay help for the full operating model`
      );
    });

    api.on("before_prompt_build", async (event, ctx) => {
      const env = resolveEnv(api.config);
      if (missingEnv(env).length > 0) return;
      const intent = detectIntent(event.prompt, event.messages);
      if (intent === "none") return;
      return { prependContext: intent === "full" ? FULL_CONTEXT : BRIEF_CONTEXT };
    });

    api.registerCommand({
      name: "nightpay",
      description: "NightPay -- status, bridge check, operating model",
      acceptsArgs: true,
      requireAuth: true,
      handler: async (ctx) => {
        const env = resolveEnv(api.config);
        const missing = missingEnv(env);
        const args = (ctx.args || "").trim();

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
        const bridgeUrl = env.BRIDGE_URL || "";

        if (!args || args === "status") {
          // Live bridge probe for /nightpay status
          let bridgeLine = "not configured";
          if (bridgeUrl) {
            try {
              const res = await fetch(`${bridgeUrl}/health`, { signal: AbortSignal.timeout(5000) });
              const h = res.ok ? await res.json() : null;
              bridgeLine = h
                ? `${h.status}${h.stub ? " (stub)" : " (live)"} | contract: ${h.contractAddress?.slice(0, 16)}... | network: ${h.network}`
                : `HTTP ${res.status}`;
            } catch (e) {
              bridgeLine = `unreachable (${e.message})`;
            }
          }

          const walletMissing = missingWalletEnv(env);
          const addrOk = !isPlaceholderAddress(env.OPERATOR_ADDRESS);

          return {
            text:
              `NightPay v0.3.11\n\n` +
              `Masumi (MIP-003)\n` +
              `  API:     ${apiUrl}\n` +
              `  Key:     ${env.MASUMI_API_KEY ? "set" : "MISSING"}\n\n` +
              `Midnight bridge\n` +
              `  URL:     ${bridgeUrl || "MISSING"}\n` +
              `  Status:  ${bridgeLine}\n` +
              `  Receipt: ${env.RECEIPT_CONTRACT_ADDRESS ? env.RECEIPT_CONTRACT_ADDRESS.slice(0, 16) + "..." : "MISSING -- set RECEIPT_CONTRACT_ADDRESS"}\n\n` +
              `Cardano operator\n` +
              `  Address: ${addrOk ? env.OPERATOR_ADDRESS.slice(0, 16) + "..." : "PLACEHOLDER -- set a real Cardano address"}\n` +
              `  Fee:     ${feeBps} bps (${(Number(feeBps) / 100).toFixed(1)}%)\n` +
              `  Network: ${network}\n\n` +
              (walletMissing.length > 0
                ? `Missing wallet credentials: ${walletMissing.join(", ")}\n  RECEIPT_CONTRACT_ADDRESS: from bridge /health\n  OPERATOR_SECRET_KEY: from your Midnight wallet\n\n`
                : "Wallet: fully configured\n\n") +
              `Run /nightpay help for the operating model.`,
          };
        }

        return {
          text: `NightPay: handling "${args}"`,
          agentInstructions: `Use the nightpay skill. Task: ${args}. Read skills/nightpay/SKILL.md for tool reference.`,
        };
      },
    });
  },
};

export default plugin;
