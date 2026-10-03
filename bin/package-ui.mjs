#!/usr/bin/env node
import { existsSync, lstatSync, readdirSync, readFileSync, realpathSync, writeFileSync, mkdirSync, unlinkSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const sha = execFileSync('git', ['-C', 'ui', 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (execFileSync('git', ['-C', 'ui', 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Commit UI source before packaging its build');
const dist = 'ui/dist', target = 'web', files = {};
const targetRoot = resolve(target);
mkdirSync(targetRoot, { recursive: true });
if (realpathSync(targetRoot) !== targetRoot) throw new Error('Web artifact directory must not be a link');
const manifestPath = join(targetRoot, 'release-manifest.json');
const previous = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')).files : {};
function ownedPath(name) {
  const path = resolve(targetRoot, name);
  if (!path.startsWith(targetRoot + sep) || name.includes('..')) throw new Error('Unexpected artifact path');
  if (existsSync(path) && (lstatSync(path).isSymbolicLink() || realpathSync(path) !== path)) throw new Error('Linked artifact path');
  return path;
}
function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path);
    else if (entry.isFile() && !path.endsWith('.map')) {
      const name = relative(dist, path).replaceAll('\\', '/');
      if (name.includes('..') || /(?:^|\/)(?:\.env|.*\.pem|.*\.db)$/.test(name)) throw new Error('Unexpected private asset');
      const output = ownedPath(name); mkdirSync(join(output, '..'), { recursive: true });
      const content = readFileSync(path);
      const text = /\.(md|json|txt|html|js|css|svg|xml)$/.test(name);
      const published = text ? Buffer.from(content.toString('utf8').replaceAll('\r\n', '\n')) : content;
      writeFileSync(output, published); files[name] = createHash('sha256').update(published).digest('hex');
    }
  }
}
walk(dist);
// Remove only obsolete files owned by the previous manifest, never a directory
// or modified/user-created file. Git retains the prior release for recovery.
for (const [name, digest] of Object.entries(previous ?? {})) {
  if (name in files) continue;
  const path = ownedPath(name);
  if (!existsSync(path)) continue;
  if (!lstatSync(path).isFile() || createHash('sha256').update(readFileSync(path)).digest('hex') !== digest) {
    throw new Error(`Refusing to remove modified artifact: ${name}`);
  }
  unlinkSync(path);
}
writeFileSync(join(target, 'release-manifest.json'), JSON.stringify({ source_ui_sha: sha,
  ui_version: JSON.parse(readFileSync('ui/package.json')).version,
  skill_version: JSON.parse(readFileSync('package.json')).version,
  files }, null, 2) + '\n');
console.log(`Packaged ${Object.keys(files).length} public web assets from UI ${sha}`);
