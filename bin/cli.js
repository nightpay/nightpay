#!/usr/bin/env node

import { cpSync, existsSync, mkdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL_SRC = resolve(__dirname, "..", "skills", "nightpay");
const COMMANDS = ["init", "add", "list", "help"];

const command = process.argv[2] || "help";

if (!COMMANDS.includes(command)) {
  console.error(`Unknown command: ${command}\nRun: npx nightpay help`);
  process.exit(1);
}

if (command === "help") {
  console.log(`
nightpay — anonymous community bounties for AI agents

Commands:
  npx nightpay init          Copy nightpay skill into ./skills/nightpay
  npx nightpay add           Same as init
  npx nightpay list          Show skill info
  npx nightpay help          This message
`);
  process.exit(0);
}

if (command === "list") {
  console.log(`
Available skill:
  nightpay    Anonymous community bounty board (Midnight + Masumi + Cardano)
              Many funders pool shielded NIGHT → AI agent completes work → ZK receipt
`);
  process.exit(0);
}

// init / add
const dest = resolve(process.cwd(), "skills", "nightpay");

if (existsSync(dest)) {
  console.log(`nightpay skill already exists at ${dest}`);
  console.log("To reinstall, remove the directory first.");
  process.exit(0);
}

mkdirSync(resolve(process.cwd(), "skills"), { recursive: true });
cpSync(SKILL_SRC, dest, { recursive: true });

console.log(`Installed nightpay skill to ${dest}`);
console.log(`\nNext steps:`);
console.log(`  1. Set environment variables: MASUMI_API_KEY, OPERATOR_ADDRESS`);
console.log(`  2. Deploy receipt.compact to Midnight preprod`);
console.log(`  3. Tell your agent: "post a bounty"`);
