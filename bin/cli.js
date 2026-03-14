#!/usr/bin/env node

import { cpSync, copyFileSync, existsSync, mkdirSync, readFileSync, chmodSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { resolve, dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync, spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(__dirname, "..");
const SKILL_SRC = resolve(PKG_ROOT, "skills", "nightpay");
const SDK_SRC = resolve(PKG_ROOT, "nightpay_sdk.py");
const SETUP_SRC = resolve(PKG_ROOT, "scripts", "setup.sh");
const COMMANDS = ["init", "add", "setup", "validate", "doctor", "list", "help"];

const command = process.argv[2] || "help";

if (!COMMANDS.includes(command)) {
  console.error(`Unknown command: ${command}\nRun: npx nightpay help`);
  process.exit(1);
}

// ─── Version ─────────────────────────────────────────────────────────────────
let VERSION = "0.3.2";
try {
  const pkg = JSON.parse(readFileSync(resolve(PKG_ROOT, "package.json"), "utf8"));
  VERSION = pkg.version || VERSION;
} catch {}

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
const INFO = `${C.cyan}ℹ${C.reset}`;

// ─── Help ────────────────────────────────────────────────────────────────────
if (command === "help") {
  console.log(`
${C.bold}nightpay${C.reset} v${VERSION} — anonymous community bounties for AI agents

${C.bold}COMMANDS${C.reset}
  npx nightpay ${C.cyan}init${C.reset}        Install skill files, SDK, and setup script
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

${C.bold}WHAT INIT INSTALLS${C.reset}
  ./skills/nightpay/          Skill files (SKILL.md, scripts, config)
  ./skills/nightpay/sdk/      Python SDK (nightpay_sdk.py)
  ./skills/nightpay/scripts/  Gateway + setup scripts
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
${C.bold}Version:${C.reset}   ${VERSION}
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

// ─── Copy one file safely ───────────────────────────────────────────────────
function safeCopy(src, dest, label) {
  if (!existsSync(src)) {
    return { status: "skip", reason: "source not found in package" };
  }
  mkdirSync(dirname(dest), { recursive: true });
  if (existsSync(dest)) {
    // Compare sizes — if same, skip
    try {
      const srcStat = statSync(src);
      const destStat = statSync(dest);
      if (srcStat.size === destStat.size) {
        return { status: "exists", reason: "already up to date" };
      }
    } catch {}
  }
  copyFileSync(src, dest);
  return { status: "copied" };
}

// ─── Init (copy ALL files) ──────────────────────────────────────────────────
function init() {
  const dest = resolve(process.cwd(), "skills", "nightpay");
  const installed = [];

  console.log(`\n${C.bold}Installing NightPay${C.reset} v${VERSION}\n`);

  // 1. Core skill files (SKILL.md, scripts/gateway.sh, etc.)
  mkdirSync(resolve(process.cwd(), "skills"), { recursive: true });
  if (existsSync(join(dest, "SKILL.md"))) {
    // Update existing — re-copy to catch any upstream changes
    cpSync(SKILL_SRC, dest, { recursive: true });
    console.log(`  ${OK} Skill files updated at ${C.dim}./skills/nightpay/${C.reset}`);
    installed.push("skills/nightpay/ (updated)");
  } else {
    cpSync(SKILL_SRC, dest, { recursive: true });
    console.log(`  ${OK} Skill files installed to ${C.dim}./skills/nightpay/${C.reset}`);
    installed.push("skills/nightpay/");
  }

  // 2. Python SDK → ./skills/nightpay/sdk/nightpay_sdk.py
  const sdkDest = join(dest, "sdk", "nightpay_sdk.py");
  const sdkResult = safeCopy(SDK_SRC, sdkDest, "Python SDK");
  if (sdkResult.status === "copied") {
    console.log(`  ${OK} Python SDK installed to ${C.dim}./skills/nightpay/sdk/nightpay_sdk.py${C.reset}`);
    installed.push("sdk/nightpay_sdk.py");
  } else if (sdkResult.status === "exists") {
    console.log(`  ${OK} Python SDK ${C.dim}(already up to date)${C.reset}`);
  } else {
    console.log(`  ${INFO} Python SDK not bundled in this version ${C.dim}(download from GitHub)${C.reset}`);
  }

  // Also copy SDK to project root for direct import convenience
  const sdkRootDest = resolve(process.cwd(), "nightpay_sdk.py");
  const sdkRootResult = safeCopy(SDK_SRC, sdkRootDest, "Python SDK (root)");
  if (sdkRootResult.status === "copied") {
    console.log(`  ${OK} Python SDK also at ${C.dim}./nightpay_sdk.py${C.reset} ${C.dim}(for direct import)${C.reset}`);
  }

  // 3. Setup script → ./skills/nightpay/scripts/setup.sh
  const setupDest = join(dest, "scripts", "setup.sh");
  const setupResult = safeCopy(SETUP_SRC, setupDest, "setup.sh");
  if (setupResult.status === "copied") {
    console.log(`  ${OK} Setup script installed to ${C.dim}./skills/nightpay/scripts/setup.sh${C.reset}`);
    installed.push("scripts/setup.sh");
  } else if (setupResult.status === "exists") {
    console.log(`  ${OK} Setup script ${C.dim}(already up to date)${C.reset}`);
  } else {
    console.log(`  ${INFO} Setup script not bundled in this version`);
  }

  // 4. Fix permissions on ALL scripts
  const scriptsDir = join(dest, "scripts");
  if (existsSync(scriptsDir)) {
    let chmodCount = 0;
    try {
      for (const f of readdirSync(scriptsDir)) {
        if (f.endsWith(".sh")) {
          chmodSync(join(scriptsDir, f), 0o755);
          chmodCount++;
        }
      }
      if (chmodCount > 0) {
        console.log(`  ${OK} Made ${chmodCount} script(s) executable`);
      }
    } catch {}
  }

  // 5. Auto-flatten nested skill directory (common misinstall)
  const nestedSkill = join(dest, "skills", "nightpay", "SKILL.md");
  if (existsSync(nestedSkill)) {
    console.log(`  ${WARN} Nested skill directory detected — flattening...`);
    cpSync(join(dest, "skills", "nightpay"), dest, { recursive: true });
    console.log(`  ${OK} Flattened: ${C.dim}skills/nightpay/skills/nightpay/ → skills/nightpay/${C.reset}`);
  }

  // 6. Summary
  console.log(`\n${C.bold}Installed ${installed.length} component(s):${C.reset}`);
  for (const item of installed) {
    console.log(`  ${C.dim}•${C.reset} ${item}`);
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

  let hasHash = false;
  try { execSync("which sha256sum", { stdio: "ignore" }); hasHash = true; } catch {}
  try { execSync("which shasum", { stdio: "ignore" }); hasHash = true; } catch {}
  if (hasHash) console.log(`  ${OK} sha256sum/shasum found`);
  else { console.log(`  ${FAIL} sha256sum/shasum not found`); errors++; }

  // Python check (for SDK)
  let hasPython = false;
  try { execSync("which python3", { stdio: "ignore" }); hasPython = true; } catch {}
  if (hasPython) console.log(`  ${OK} python3 found (SDK available)`);
  else console.log(`  ${INFO} python3 not found ${C.dim}(optional — needed for Python SDK)${C.reset}`);

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

  const fileChecks = [
    { path: join(dest, "SKILL.md"), label: "SKILL.md", required: true },
    { path: join(dest, "scripts", "gateway.sh"), label: "gateway.sh", required: true },
    { path: join(dest, "scripts", "setup.sh"), label: "setup.sh", required: false },
    { path: join(dest, "sdk", "nightpay_sdk.py"), label: "Python SDK (sdk/)", required: false },
  ];

  for (const check of fileChecks) {
    if (existsSync(check.path)) {
      console.log(`  ${OK} ${check.label} found`);
    } else if (check.required) {
      console.log(`  ${FAIL} ${check.label} not found — run: ${C.cyan}npx nightpay init${C.reset}`);
      errors++;
    } else {
      console.log(`  ${WARN} ${check.label} not found — run: ${C.cyan}npx nightpay init${C.reset} to install`);
      warnings++;
    }
  }

  // Check for root-level SDK copy too
  const rootSdk = resolve(process.cwd(), "nightpay_sdk.py");
  if (existsSync(rootSdk)) {
    console.log(`  ${OK} Python SDK also at ./nightpay_sdk.py`);
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
  console.log(`\n${C.bold}NightPay Doctor${C.reset} v${VERSION} — diagnosing and fixing issues...\n`);
  let fixed = 0;

  const dest = resolve(process.cwd(), "skills", "nightpay");

  // Fix 1: Missing skill files → full init
  if (!existsSync(join(dest, "SKILL.md"))) {
    console.log(`  ${WARN} Skill not installed — running full init...`);
    init();
    fixed++;
  }

  // Fix 2: Nested SKILL.md
  const nestedSkill = join(dest, "skills", "nightpay", "SKILL.md");
  if (existsSync(nestedSkill)) {
    console.log(`  ${WARN} SKILL.md nested — flattening...`);
    cpSync(join(dest, "skills", "nightpay"), dest, { recursive: true });
    console.log(`  ${OK} Fixed: flattened skill directory`);
    fixed++;
  }

  // Fix 3: Script permissions
  const scriptsDir = join(dest, "scripts");
  if (existsSync(scriptsDir)) {
    for (const f of readdirSync(scriptsDir)) {
      if (f.endsWith(".sh")) {
        try {
          chmodSync(join(scriptsDir, f), 0o755);
          fixed++;
        } catch {}
      }
    }
    console.log(`  ${OK} Fixed: script permissions`);
  }

  // Fix 4: Missing SDK
  const sdkDest = join(dest, "sdk", "nightpay_sdk.py");
  if (!existsSync(sdkDest) && existsSync(SDK_SRC)) {
    mkdirSync(join(dest, "sdk"), { recursive: true });
    copyFileSync(SDK_SRC, sdkDest);
    console.log(`  ${OK} Fixed: installed Python SDK to ${C.dim}sdk/nightpay_sdk.py${C.reset}`);
    fixed++;
  }

  // Fix 5: Missing setup.sh
  const setupDest = join(dest, "scripts", "setup.sh");
  if (!existsSync(setupDest) && existsSync(SETUP_SRC)) {
    mkdirSync(join(dest, "scripts"), { recursive: true });
    copyFileSync(SETUP_SRC, setupDest);
    chmodSync(setupDest, 0o755);
    console.log(`  ${OK} Fixed: installed setup.sh to ${C.dim}scripts/setup.sh${C.reset}`);
    fixed++;
  }

  // Fix 6: Root SDK convenience copy
  const rootSdk = resolve(process.cwd(), "nightpay_sdk.py");
  if (!existsSync(rootSdk) && existsSync(SDK_SRC)) {
    copyFileSync(SDK_SRC, rootSdk);
    console.log(`  ${OK} Fixed: copied SDK to ${C.dim}./nightpay_sdk.py${C.reset} for direct import`);
    fixed++;
  }

  // Fix 7: Warn about placeholder env vars
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
  console.log(`\n${C.bold}NightPay Agent Onboarding${C.reset} v${VERSION}`);
  console.log(`${C.dim}Anonymous community bounties for AI agents${C.reset}`);
  console.log(`\n  Platform: ${C.bold}${platform}${C.reset}\n`);

  // Step 1: Smart install (all files)
  const dest = init();

  // Step 2: Platform-specific config
  console.log(`\n${C.bold}Platform config (${platform})${C.reset}`);

  if (platform === "claude-code") {
    const cmdDir = resolve(process.cwd(), ".claude", "commands");
    const cmdFile = join(cmdDir, "nightpay.md");
    if (!existsSync(cmdFile)) {
      mkdirSync(cmdDir, { recursive: true });
      writeFileSync(cmdFile, [
        "# NightPay",
        "",
        "Use the nightpay skill at ./skills/nightpay/ for bounty operations.",
        "",
        "## Quick commands",
        "- `bash skills/nightpay/scripts/gateway.sh stats` — contract stats",
        "- `bash skills/nightpay/scripts/gateway.sh post-bounty \"<desc>\" <amount>` — post bounty",
        "- `python3 skills/nightpay/sdk/nightpay_sdk.py validate` — health check",
        "- `python3 skills/nightpay/sdk/nightpay_sdk.py doctor --auto-fix` — self-heal",
        "",
      ].join("\n"));
      console.log(`  ${OK} Created ${C.dim}.claude/commands/nightpay.md${C.reset}`);
    } else {
      console.log(`  ${OK} ${C.dim}.claude/commands/nightpay.md${C.reset} already exists`);
    }
  } else if (platform === "cursor") {
    const rulesDir = resolve(process.cwd(), ".cursor", "rules");
    const rulesFile = join(rulesDir, "nightpay.md");
    if (!existsSync(rulesFile)) {
      mkdirSync(rulesDir, { recursive: true });
      writeFileSync(rulesFile, [
        "# NightPay Skill",
        "",
        "The nightpay skill is at ./skills/nightpay/. Read SKILL.md for capabilities.",
        "Python SDK at ./skills/nightpay/sdk/nightpay_sdk.py or ./nightpay_sdk.py.",
        "",
        "Quick: `bash skills/nightpay/scripts/gateway.sh stats`",
        "",
      ].join("\n"));
      console.log(`  ${OK} Created ${C.dim}.cursor/rules/nightpay.md${C.reset}`);
    } else {
      console.log(`  ${OK} ${C.dim}.cursor/rules/nightpay.md${C.reset} already exists`);
    }
  } else if (platform === "copilot") {
    const instrFile = resolve(process.cwd(), ".github", "copilot-instructions.md");
    if (existsSync(instrFile)) {
      const content = readFileSync(instrFile, "utf8");
      if (!content.includes("nightpay")) {
        const addition = [
          "",
          "## NightPay",
          "",
          "Bounty skill at ./skills/nightpay/. Read SKILL.md for full capabilities.",
          "Python SDK at ./skills/nightpay/sdk/nightpay_sdk.py.",
          "Gateway: `bash skills/nightpay/scripts/gateway.sh`",
          "",
        ].join("\n");
        writeFileSync(instrFile, content + addition);
        console.log(`  ${OK} Appended NightPay section to ${C.dim}.github/copilot-instructions.md${C.reset}`);
      } else {
        console.log(`  ${OK} Copilot instructions already mention nightpay`);
      }
    } else {
      console.log(`  ${INFO} No .github/copilot-instructions.md — skipping Copilot config`);
    }
  } else if (platform === "openclaw") {
    console.log(`  ${OK} OpenClaw auto-discovers skills from ./skills/nightpay/`);
    console.log(`  ${C.dim}  Tip: merge openclaw-fragment.json into your openclaw.json${C.reset}`);
  } else {
    console.log(`  ${INFO} Raw platform — no config file needed`);
    console.log(`  ${C.dim}  Use: bash skills/nightpay/scripts/gateway.sh <command>${C.reset}`);
  }

  // Step 3: Run validate
  console.log("");
  const { errors } = validate();

  // Step 4: Next steps
  console.log(`\n${C.bold}Next steps${C.reset}`);
  if (errors > 0) {
    console.log(`  1. Fix the ${errors} error(s) above`);
    console.log(`  2. Run: ${C.cyan}npx nightpay validate${C.reset}`);
  } else {
    console.log(`  1. ${C.cyan}bash skills/nightpay/scripts/gateway.sh stats${C.reset} — check contract`);
    console.log(`  2. ${C.cyan}bash skills/nightpay/scripts/gateway.sh post-bounty "Review this PR" 5000${C.reset}`);
  }
  console.log(`\n  ${C.dim}Python SDK:${C.reset} from nightpay_sdk import NightPay; NightPay().stats()`);
  console.log(`  ${C.dim}Self-heal:${C.reset}  npx nightpay doctor`);
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
