#!/usr/bin/env node

import { cpSync, existsSync, mkdirSync, readFileSync, chmodSync, readdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync, spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL_SRC = resolve(__dirname, "..", "skills", "nightpay");
const COMMANDS = ["init", "add", "setup", "validate", "doctor", "list", "help"];

const command = process.argv[2] || "help";

if (!COMMANDS.includes(command)) {
  console.error(`Unknown command: ${command}\nRun: npx nightpay help`);
  process.exit(1);
}

// ─── Colors ──────────────────────────────────────────────────────────────────
const isTTY = process.stderr.isTTY;
const C = {
  red: isTTY ? "\x1b[31m" : "",
  green: isTTY ? "\x1b[32m" : "",
  yellow: isTTY ? "\x1b[33m" : "",
  cyan: isTTY ? "\x1b[36m" : "",
  bold: isTTY ? "\x1b[1m" : "",
  dim: isTTY ? "\x1b[2m" : "",
  reset: isTTY ? "\x1b[0m" : "",
};
const OK = `${C.green}✅${C.reset}`;
const FAIL = `${C.red}❌${C.reset}`;
const WARN = `${C.yellow}⚠️${C.reset}`;

// ─── Help ────────────────────────────────────────────────────────────────────
if (command === "help") {
  console.log(`
${C.bold}nightpay${C.reset} — anonymous community bounties for AI agents

${C.bold}COMMANDS${C.reset}
  npx nightpay ${C.cyan}init${C.reset}        Copy skill files into ./skills/nightpay
  npx nightpay ${C.cyan}setup${C.reset}       Full onboarding: install + validate + platform config
  npx nightpay ${C.cyan}validate${C.reset}    Check env vars, prerequisites, and connectivity
  npx nightpay ${C.cyan}doctor${C.reset}      Diagnose and auto-fix common issues
  npx nightpay ${C.cyan}list${C.reset}        Show skill info
  npx nightpay ${C.cyan}help${C.reset}        This message

${C.bold}QUICK START${C.reset}
  ${C.dim}# Install and validate in one step:${C.reset}
  npx nightpay setup

  ${C.dim}# Or step by step:${C.reset}
  npx nightpay init
  export MASUMI_API_KEY="your-key"
  export OPERATOR_ADDRESS="your-address"
  export NIGHTPAY_API_URL="https://api.nightpay.dev"
  export BRIDGE_URL="https://bridge.nightpay.dev"
  npx nightpay validate
`);
  process.exit(0);
}

// ─── List ────────────────────────────────────────────────────────────────────
if (command === "list") {
  console.log(`
${C.bold}Available skill:${C.reset}
  nightpay    Anonymous community bounty board (Midnight + Masumi + Cardano)
              Many funders pool shielded NIGHT → AI agent completes work → ZK receipt

${C.bold}Platforms:${C.reset} OpenClaw, Claude Code, Cursor, GitHub Copilot, ACP, Raw API
${C.bold}Version:${C.reset}   0.2.4
${C.bold}License:${C.reset}   Apache-2.0
`);
  process.exit(0);
}

// ─── Detect platform ────────────────────────────────────────────────────────
function detectPlatform() {
  try { execSync("which openclaw", { stdio: "ignore" }); return "openclaw"; } catch {}
  if (existsSync(".claude") || existsSync(".claude/settings.json")) return "claude-code";
  if (existsSync(".cursor") || existsSync(".cursorrules")) return "cursor";
  if (existsSync(".github/copilot-instructions.md")) return "copilot";
  return "raw";
}

// ─── Init (copy files) ──────────────────────────────────────────────────────
function init() {
  const dest = resolve(process.cwd(), "skills", "nightpay");

  if (existsSync(join(dest, "SKILL.md"))) {
    console.log(`${OK} Skill already installed at ${dest}`);
    return dest;
  }

  mkdirSync(resolve(process.cwd(), "skills"), { recursive: true });
  cpSync(SKILL_SRC, dest, { recursive: true });
  console.log(`${OK} Installed skill files to ${dest}`);

  // Fix permissions on scripts
  const scriptsDir = join(dest, "scripts");
  if (existsSync(scriptsDir)) {
    try {
      for (const f of readdirSync(scriptsDir)) {
        if (f.endsWith(".sh")) {
          chmodSync(join(scriptsDir, f), 0o755);
        }
      }
      console.log(`${OK} Script permissions fixed`);
    } catch {}
  }

  // Auto-flatten if needed
  const nestedSkill = join(dest, "skills", "nightpay", "SKILL.md");
  if (!existsSync(join(dest, "SKILL.md")) && existsSync(nestedSkill)) {
    console.log(`${WARN} SKILL.md nested — flattening...`);
    cpSync(join(dest, "skills", "nightpay"), dest, { recursive: true });
    console.log(`${OK} Flattened skill directory`);
  }

  return dest;
}

// ─── Validate ────────────────────────────────────────────────────────────────
function validate() {
  let errors = 0;
  let warnings = 0;

  console.log(`\n${C.bold}Prerequisites${C.reset}`);
  for (const bin of ["bash", "curl", "openssl", "sqlite3"]) {
    try {
      execSync(`which ${bin}`, { stdio: "ignore" });
      console.log(`  ${OK} ${bin} found`);
    } catch {
      console.log(`  ${FAIL} ${bin} not found`);
      errors++;
    }
  }

  // sha256sum or shasum
  let hasHash = false;
  try { execSync("which sha256sum", { stdio: "ignore" }); hasHash = true; } catch {}
  try { execSync("which shasum", { stdio: "ignore" }); hasHash = true; } catch {}
  if (hasHash) console.log(`  ${OK} sha256sum/shasum found`);
  else { console.log(`  ${FAIL} sha256sum/shasum not found`); errors++; }

  console.log(`\n${C.bold}Environment variables${C.reset}`);
  const required = {
    MASUMI_API_KEY: "Masumi payment API key",
    OPERATOR_ADDRESS: "Midnight operator address (64-char hex)",
    NIGHTPAY_API_URL: "Deployed MIP-003 API URL",
    BRIDGE_URL: "Midnight bridge URL",
  };

  for (const [key, desc] of Object.entries(required)) {
    const val = process.env[key];
    if (!val) {
      console.log(`  ${FAIL} ${key} not set — ${desc}`);
      console.log(`       ${C.dim}Fix: export ${key}="your-value"${C.reset}`);
      errors++;
    } else if (val === key) {
      console.log(`  ${FAIL} ${key} is placeholder "${key}" — replace with real value`);
      errors++;
    } else if (key === "OPERATOR_ADDRESS" && (val.length !== 64 || !/^[0-9a-fA-F]+$/.test(val))) {
      console.log(`  ${WARN} ${key} doesn't look like 64-char hex (got ${val.length} chars)`);
      warnings++;
    } else {
      const display = key.includes("URL") ? val : `${val.slice(0, 8)}...`;
      console.log(`  ${OK} ${key} set (${display})`);
    }
  }

  console.log(`\n${C.bold}Skill files${C.reset}`);
  const dest = resolve(process.cwd(), "skills", "nightpay");
  if (existsSync(join(dest, "SKILL.md"))) {
    console.log(`  ${OK} SKILL.md found`);
  } else {
    console.log(`  ${FAIL} SKILL.md not found — run: npx nightpay init`);
    errors++;
  }

  if (existsSync(join(dest, "scripts", "gateway.sh"))) {
    console.log(`  ${OK} gateway.sh found`);
  } else {
    console.log(`  ${FAIL} gateway.sh not found`);
    errors++;
  }

  console.log(`\n${C.bold}Connectivity${C.reset}`);
  const apiUrl = process.env.NIGHTPAY_API_URL;
  if (apiUrl && apiUrl !== "NIGHTPAY_API_URL") {
    try {
      execSync(`curl -sf --max-time 10 "${apiUrl}/availability"`, { stdio: "ignore" });
      console.log(`  ${OK} API reachable at ${apiUrl}`);
    } catch {
      console.log(`  ${WARN} API unreachable at ${apiUrl}`);
      warnings++;
    }
  }

  const bridgeUrl = process.env.BRIDGE_URL;
  if (bridgeUrl && bridgeUrl !== "BRIDGE_URL") {
    try {
      execSync(`curl -sf --max-time 10 "${bridgeUrl}/health"`, { stdio: "ignore" });
      console.log(`  ${OK} Bridge reachable at ${bridgeUrl}`);
    } catch {
      console.log(`  ${WARN} Bridge unreachable at ${bridgeUrl}`);
      warnings++;
    }
  }

  // Summary
  console.log("");
  if (errors === 0 && warnings === 0) {
    console.log(`${C.green}${C.bold}NightPay is ready!${C.reset} Run: bash skills/nightpay/scripts/gateway.sh stats`);
  } else if (errors === 0) {
    console.log(`${C.yellow}${C.bold}Ready with ${warnings} warning(s)${C.reset} — review above`);
  } else {
    console.log(`${C.red}${C.bold}Not ready: ${errors} error(s), ${warnings} warning(s)${C.reset}`);
    console.log(`Fix the issues above and run: npx nightpay validate`);
  }

  return { errors, warnings };
}

// ─── Doctor (diagnose + auto-fix) ────────────────────────────────────────────
function doctor() {
  console.log(`\n${C.bold}NightPay Doctor${C.reset} — diagnosing and fixing issues...\n`);
  let fixed = 0;

  const dest = resolve(process.cwd(), "skills", "nightpay");

  // Fix 1: Missing skill files
  if (!existsSync(join(dest, "SKILL.md"))) {
    console.log(`  ${WARN} Skill not installed — installing now...`);
    init();
    fixed++;
  }

  // Fix 2: Nested SKILL.md
  const nestedSkill = join(dest, "skills", "nightpay", "SKILL.md");
  if (existsSync(nestedSkill) && !existsSync(join(dest, "SKILL.md"))) {
    console.log(`  ${WARN} SKILL.md nested — flattening...`);
    cpSync(join(dest, "skills", "nightpay"), dest, { recursive: true });
    console.log(`  ${OK} Fixed: flattened skill directory`);
    fixed++;
  }

  // Fix 3: Script permissions
  const gateway = join(dest, "scripts", "gateway.sh");
  if (existsSync(gateway)) {
    try {
      chmodSync(gateway, 0o755);
      console.log(`  ${OK} Fixed: gateway.sh permissions`);
      fixed++;
    } catch {}
  }

  // Fix 4: Warn about placeholder env vars
  const fragment = join(dest, "openclaw-fragment.json");
  if (existsSync(fragment)) {
    try {
      const content = readFileSync(fragment, "utf8");
      const data = JSON.parse(content);
      const env = data?.skills?.entries?.nightpay?.env || {};
      const placeholders = Object.entries(env).filter(([k, v]) => k === v);
      if (placeholders.length > 0) {
        console.log(`\n  ${WARN} openclaw-fragment.json has ${placeholders.length} placeholder value(s):`);
        for (const [k] of placeholders) {
          console.log(`       ${C.dim}${k}: "${k}" → replace with real value${C.reset}`);
        }
      }
    } catch {}
  }

  console.log(`\n  Applied ${fixed} fix(es). Running validation...\n`);
  validate();
}

// ─── Setup (full onboarding) ─────────────────────────────────────────────────
function setup() {
  const platform = detectPlatform();
  console.log(`\n${C.bold}NightPay Agent Onboarding${C.reset} v0.2.4`);
  console.log(`${C.dim}Anonymous community bounties for AI agents${C.reset}`);
  console.log(`\n  Platform: ${C.bold}${platform}${C.reset}\n`);

  // Step 1: Install
  const dest = init();

  // Step 2: Platform-specific config
  console.log(`\n${C.bold}Platform setup (${platform})${C.reset}`);

  // Check if bash setup.sh exists and delegate for platform-specific stuff
  const setupSh = join(dest, "scripts", "setup.sh");
  if (existsSync(setupSh)) {
    const result = spawnSync("bash", [setupSh, "--platform", platform, "--validate-only"], {
      stdio: "inherit",
      env: { ...process.env, NIGHTPAY_WORKSPACE: dest }
    });
    if (result.status === 0) {
      console.log(`\n${C.green}${C.bold}Setup complete!${C.reset}`);
    }
  } else {
    // Fallback: just validate
    validate();
  }

  // Step 3: Next steps
  console.log(`\n${C.bold}Next steps${C.reset}`);
  console.log(`  1. Set your environment variables (if not already set)`);
  console.log(`  2. Run: ${C.cyan}bash skills/nightpay/scripts/gateway.sh stats${C.reset}`);
  console.log(`  3. Post your first bounty: ${C.cyan}bash skills/nightpay/scripts/gateway.sh post-bounty "Review this PR" 5000${C.reset}`);
  console.log("");
}

// ─── Route command ───────────────────────────────────────────────────────────
if (command === "init" || command === "add") {
  init();
  console.log(`\nNext: run ${C.cyan}npx nightpay validate${C.reset} to check your setup`);
} else if (command === "setup") {
  setup();
} else if (command === "validate") {
  const { errors } = validate();
  process.exit(errors > 0 ? 1 : 0);
} else if (command === "doctor") {
  doctor();
}
