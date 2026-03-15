#!/usr/bin/env node

import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const root = process.cwd();
const smokeScript = resolve(root, "test", "smoke.sh");

function canRun(command) {
  const check = spawnSync(command, ["--version"], {
    cwd: root,
    stdio: "ignore",
    shell: false,
  });
  return check.status === 0;
}

const candidates = [];
if (process.env.BASH_BIN) {
  candidates.push(process.env.BASH_BIN);
}
if (process.platform === "win32") {
  candidates.push(
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
    "bash"
  );
} else {
  candidates.push("bash");
}

const bashBin = candidates.find((candidate) => {
  if (candidate.includes("\\") || candidate.includes("/")) {
    return existsSync(candidate) && canRun(candidate);
  }
  return canRun(candidate);
});

if (!bashBin) {
  console.error(
    "ERROR: No working bash found. Install Git Bash/WSL or set BASH_BIN to a bash executable."
  );
  process.exit(1);
}

const run = spawnSync(bashBin, [smokeScript], {
  cwd: root,
  stdio: "inherit",
  shell: false,
});

if (typeof run.status === "number") {
  process.exit(run.status);
}
process.exit(1);

