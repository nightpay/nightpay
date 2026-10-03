"""Verify the deployable public UI artifact against its pinned source and manifest."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
root=Path(__file__).resolve().parents[1]
web=root/'web'
manifest=json.loads((web/'release-manifest.json').read_text())
pointer=subprocess.check_output(['git','ls-tree','HEAD','ui'],cwd=root,text=True).split()[2]
assert manifest['source_ui_sha']==pointer, 'UI artifact does not match pinned source'
assert manifest['skill_version']==json.loads((root/'package.json').read_text())['version']
for name, digest in manifest['files'].items():
    path=PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts
    assert path.suffix!='.map', 'Private source maps must not be published'
    assert hashlib.sha256((web/name).read_bytes()).hexdigest()==digest, name
assert (web/'skill.md').read_text(encoding='utf-8')==(root/'skills/nightpay/SKILL.md').read_text(encoding='utf-8')
assert (web/'legal/terms.md').read_text(encoding='utf-8')==(root/'docs/TERMS.md').read_text(encoding='utf-8')
assert (web/'legal/cookies.md').read_text(encoding='utf-8')==(root/'docs/COOKIES.md').read_text(encoding='utf-8')
actual={str(p.relative_to(web)).replace('\\','/') for p in web.rglob('*') if p.is_file() and p.name!='release-manifest.json'}
assert actual==set(manifest['files']), 'Unexpected or missing web assets'
print('Public web artifact hashes, source commit and skill mirror verified')
