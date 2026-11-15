#!/usr/bin/env python3
"""Refresh or verify the offline schema snapshot from no-start callbacks."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIT = ROOT / 'benchmark/audit'


def fingerprint():
    core = ROOT / 'apps/fermix_core/lib/fermix_core'
    paths = sorted((core / 'tools').rglob('*.ex'))
    paths += [core / name for name in (
        'capabilities/builtin_seeder.ex', 'capabilities/builtin.ex', 'capabilities/capability.ex', 'browser.ex', 'checklists/registry.ex',
        'computer_use/helper_actions.ex', 'memory/admission.ex', 'open_loops/defaults.ex',
        'providers/model_catalog.ex', 'providers/reasoning_effort.ex', 'boot_profile.ex')]
    paths += sorted((ROOT / 'config').glob('*.exs'))
    paths += [ROOT / 'mix.lock', AUDIT / 'export_schemas.exs']
    digest = hashlib.sha256()
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0')
        digest.update(path.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


def refresh():
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / 'schemas.json'
        mix = shutil.which('mix')
        if not mix:
            raise RuntimeError('mix is required for inventory refresh')
        env = {'PATH': str(Path(mix).parent) + os.pathsep + os.defpath,
               'HOME': tmp, 'FERMIX_HOME': tmp + '/fermix', 'MIX_ENV': 'test',
               'MIX_ARCHIVES': str(Path.home() / '.mix/archives')}
        subprocess.run([mix, 'run', '--no-compile', '--no-start',
                        'benchmark/audit/export_schemas.exs', str(output)],
                       cwd=ROOT, env=env, check=True, timeout=180)
        snapshot = json.loads(output.read_text())
    snapshot['source_sha256'] = fingerprint()
    encoded = json.dumps(snapshot, indent=2, sort_keys=True) + '\n'
    (AUDIT / 'schemas.json').write_text(encoded)
    (AUDIT / 'schemas.sha256').write_text(hashlib.sha256(encoded.encode()).hexdigest() + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refresh', action='store_true', required=True)
    parser.parse_args()
    refresh()


if __name__ == '__main__':
    main()
