#!/usr/bin/env python3
"""Prepare verified, pinned offline runtime resources; no npm or global installs."""
import base64
import hashlib
import json
import shutil
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build' / 'portless-downloads'
OUTPUT = ROOT / '.build' / 'portless-runtime'
LOCK = json.loads((ROOT / 'Resources/Portless/runtime-lock.json').read_text())


def download(url, name, algorithm, digest):
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / name
    if not target.exists():
        temporary = target.with_suffix('.download')
        with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as out:
            shutil.copyfileobj(response, out)
        temporary.replace(target)
    actual = hashlib.new(algorithm, target.read_bytes()).digest()
    if actual != digest:
        target.unlink()
        raise ValueError(f'Checksum mismatch: {name}')
    return target


def extract_member(archive, member, destination):
    with tarfile.open(archive) as package:
        item = package.getmember(member)
        if not item.isfile():
            raise ValueError(f'Not a regular file: {member}')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with package.extractfile(item) as source, destination.open('wb') as out:
            shutil.copyfileobj(source, out)


def prepare():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    version = LOCK['nodeVersion']
    for arch, checksum in LOCK['nodeSHA256'].items():
        name = f'node-v{version}-darwin-{arch}'
        archive = download(f'https://nodejs.org/dist/v{version}/{name}.tar.gz',
                           name + '.tar.gz', 'sha256', bytes.fromhex(checksum))
        node = OUTPUT / f'node-{arch}'
        extract_member(archive, name + '/bin/node', node)
        node.chmod(0o755)
        extract_member(archive, name + '/LICENSE', OUTPUT / f'NODE-LICENSE-{arch}')
    version = LOCK['portlessVersion']
    archive = download(f'https://registry.npmjs.org/portless/-/portless-{version}.tgz',
                       f'portless-{version}.tgz', 'sha512',
                       base64.b64decode(LOCK['portlessIntegrity'].split('-', 1)[1]))
    package_dir = OUTPUT / 'package'
    if package_dir.exists():
        shutil.rmtree(package_dir)
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            path = Path(member.name)
            if path.parts[0] != 'package' or '..' in path.parts or path.is_absolute():
                raise ValueError('Unsafe package path')
            if member.isfile():
                extract_member(archive, member.name, OUTPUT / path)
            elif not member.isdir():
                raise ValueError('Unsupported package member')
    # Deliberately small, guarded adaptations to the pinned upstream build.
    cli_path = package_dir / 'dist/cli.js'
    cli = cli_path.read_text()
    changes = {
        'var SERVICE_LABEL = "sh.portless.proxy";': 'var SERVICE_LABEL = "app.leftopen.portless.proxy";',
        'getRoutes: () => cachedRoutes,': 'getRoutes: () => gateRoutes(cachedRoutes, store.dir),',
    }
    for before, after in changes.items():
        if cli.count(before) != 1:
            raise ValueError('Pinned Portless CLI layout changed; review the adapter')
        cli = cli.replace(before, after)
    cli = cli.replace('#!/usr/bin/env node\n', '#!/usr/bin/env node\n// Modified by LeftOpen; see ../../LEFTOPEN-NOTICE.\nimport { gateRoutes } from "../../lease-gate.mjs";\n', 1)
    needle = '  const args = process.argv.slice(2);'
    if cli.count(needle) != 1:
        raise ValueError('Pinned CLI argument entry changed')
    cli = cli.replace(needle, needle + '\n' + '''
  if (args[0] === "--leftopen-project-info") {
    const config = loadAppConfig();
    const baseName = config?.name || inferProjectName().name;
    const worktree = detectWorktreePrefix();
    const script = config?.script || "dev";
    const workspaceRoot = findWorkspaceRoot();
    const workspace = workspaceRoot === process.cwd();
    const raw = resolveScriptRaw(script, process.cwd());
    const canStart = workspace
      ? discoverWorkspacePackages(workspaceRoot).some(pkg => pkg.scripts[script])
      : !!raw && !/(?:^|[ ;&|])portless(?:[ ;&|]|$)/.test(raw);
    console.log(JSON.stringify({ baseName, name: applyWorktreePrefix(baseName, worktree),
      script, canStart, workspace, worktreePrefix: worktree?.prefix || null }));
    return;
  }
''', 1)
    cli_path.write_text(cli)
    modified_hosts = 0
    for module in (package_dir / 'dist').glob('*.js'):
        value = module.read_text()
        if '"# portless-start"' in value:
            value = '// Hosts markers modified by LeftOpen; see ../../LEFTOPEN-NOTICE.\n' + value.replace('"# portless-start"', '"# leftopen-portless-start"').replace('"# portless-end"', '"# leftopen-portless-end"')
            module.write_text(value)
            modified_hosts += 1
    if modified_hosts != 1:
        raise ValueError('Pinned hosts module layout changed; review the adapter')
    for source in (ROOT / 'Resources/Portless').iterdir():
        if source.is_file():
            shutil.copy2(source, OUTPUT / source.name)
    print('Prepared pinned Portless engine and both Node architectures.')


if __name__ == '__main__':
    prepare()
