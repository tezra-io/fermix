"""Initialize only the disposable target's home and launch the daemon."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def render_config(model, proxy_url):
    return f'''[fermix_core.providers.anthropic]
primary = true
default_model = {json.dumps(model)}
base_url = {json.dumps(proxy_url)}

[fermix_core.browser]
allowed_hosts = ["world"]

'''


def render_machine():
    """This computer's own settings, which the engine reads from machine.toml
    beside config.toml and never from config.toml (M97 §4)."""
    return '''[sandbox]
mode = "strict"
workspace_root = "/home/audit/fermix/workspace"
allowed_roots = ["/home/audit/fermix/skills"]

'''

def main():
    spec = json.load(sys.stdin)
    home = Path('/home/audit/fermix')
    if not home.is_dir() or any(home.iterdir()):
        raise ValueError("audit home volume must be empty")
    (home / 'workspace').mkdir()
    (home / 'skills').mkdir()
    subprocess.run(['git', 'init', '-q', str(home / 'workspace')], check=True)
    config = render_config(spec['model'], spec['proxy_url'])
    machine = render_machine()

    (home / 'config.toml').write_text(config)
    fd = os.open(home / 'machine.toml', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(machine)
    token_path = home / 'audit-token'
    fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(spec['token'])

    print(json.dumps({"config_sha256": hashlib.sha256(config.encode()).hexdigest(),
                      "machine_sha256": hashlib.sha256(machine.encode()).hexdigest()}))


if __name__ == '__main__':
    main()
