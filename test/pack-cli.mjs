import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const packed = execFileSync('npm', ['pack', '--json', '--dry-run'], {
  encoding: 'utf8',
  shell: process.platform === 'win32',
});
const files = JSON.parse(packed)[0].files.map((file) => file.path);
for (const required of ['bin/cli.js', 'mcp/nightpay-mcp.mjs', 'skills/nightpay/SKILL.md', 'package.json']) {
  assert.ok(files.includes(required), `npm package is missing ${required}`);
}
const cli = readFileSync(new URL('../bin/cli.js', import.meta.url), 'utf8');
for (const snippet of ['agent-register', 'publish-profile', 'hire-service', '--confirm', '--dry-run', 'mcp']) {
  assert.ok(cli.includes(snippet), `CLI is missing ${snippet}`);
}
const version = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
assert.equal(JSON.parse(packed)[0].filename, `nightpay-${version}.tgz`);
console.log(`npm pack ${version} includes ${files.length} files and the agent marketplace CLI`);
