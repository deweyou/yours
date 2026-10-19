"""Rebuild pinned offline renderers from the repository root (requires Node/npm)."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
work = root / '.build/document-rendering'
out = root / 'Sources/Yours/Resources/DocumentRendering'
work.mkdir(parents=True, exist_ok=True)
for name in ('package.json', 'package-lock.json', 'entry.js'):
    shutil.copyfile(Path(__file__).parent / name, work / name)
subprocess.run(['npm', 'ci', '--ignore-scripts'], cwd=work, check=True)
subprocess.run([str(work / 'node_modules/.bin/esbuild'), 'entry.js', '--bundle', '--format=iife',
                '--minify', '--drop:console', '--drop:debugger', '--legal-comments=external', f'--outfile={out / "mermaid.js"}'], cwd=work, check=True)
# Mermaid bundles a language-server inspect hook using an injected console,
# which esbuild's global console removal cannot recognize. It is diagnostic only.
mermaid = out / 'mermaid.js'
source = mermaid.read_text()
source = re.sub(r'\(0,[\w$]+\.default\)\(\)\.console\.log\("inspect"\)', 'void 0', source)
mermaid.write_text(source)
katex = work / 'node_modules/katex/dist' 
subprocess.run([str(work / 'node_modules/.bin/esbuild'), str(katex / 'katex.min.js'),
                '--minify', '--drop:console', '--drop:debugger', '--legal-comments=external',
                f'--outfile={out / "katex.js"}'], cwd=work, check=True)
shutil.copyfile(katex / 'katex.min.css', out / 'katex.css')
shutil.copytree(katex / 'fonts', out / 'fonts', dirs_exist_ok=True)
licenses = []
for path in sorted((work / 'node_modules').rglob('*')):
    if path.is_file() and path.name.lower() in ('license', 'license.txt', 'license.md', 'licence', 'copying'):
        licenses.append(f'\n===== {path.relative_to(work / "node_modules")} =====\n' + path.read_text(errors='replace'))
(out / 'THIRD-PARTY-LICENSES.txt').write_text('\n'.join(licenses))
versions = json.loads((work / 'package.json').read_text())['dependencies']
(out / 'versions.json').write_text(json.dumps({
    'mermaid': versions['mermaid'], 'katex': versions['katex'],
    'sha256': {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
               for name in ('mermaid.js', 'katex.css', 'katex.js')}
}, indent=2) + '\n')
