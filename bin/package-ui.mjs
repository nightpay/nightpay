#!/usr/bin/env node
import { readdirSync, readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const sha = execFileSync('git', ['-C', 'ui', 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (execFileSync('git', ['-C', 'ui', 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Commit UI source before packaging its build');
const dist = 'ui/dist', target = 'web', files = {};
function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path);
    else if (entry.isFile() && !path.endsWith('.map')) {
      const name = relative(dist, path).replaceAll('\\', '/');
      if (name.includes('..') || /(?:^|\/)(?:\.env|.*\.pem|.*\.db)$/.test(name)) throw new Error('Unexpected private asset');
      const output = join(target, name); mkdirSync(join(output, '..'), { recursive: true });
      const content = readFileSync(path);
      const text = /\.(md|json|txt|html|js|css|svg|xml)$/.test(name);
      const published = text ? Buffer.from(content.toString('utf8').replaceAll('\r\n', '\n')) : content;
      writeFileSync(output, published); files[name] = createHash('sha256').update(published).digest('hex');
    }
  }
}
walk(dist);
writeFileSync(join(target, 'release-manifest.json'), JSON.stringify({ source_ui_sha: sha,
  ui_version: JSON.parse(readFileSync('ui/package.json')).version,
  skill_version: JSON.parse(readFileSync('package.json')).version,
  files }, null, 2) + '\n');
console.log(`Packaged ${Object.keys(files).length} public web assets from UI ${sha}`);
