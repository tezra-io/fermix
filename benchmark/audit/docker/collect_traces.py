"""Read only bounded regular trace files from the disposable target."""
import base64
import json
import re
from pathlib import Path

root = Path('/home/audit/fermix/traces')
result = {}
total = 0
if root.is_symlink():
    raise ValueError('trace root is a symlink')
if root.exists():
    for day in sorted(root.iterdir()):
        if day.is_symlink() or not day.is_dir() or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day.name):
            raise ValueError(f'unsafe trace directory: {day.name}')
        for path in sorted(day.iterdir()):
            if path.is_symlink() or not path.is_file() or not re.fullmatch(r'[a-z_]+(?:\.bodies)?\.jsonl', path.name):
                raise ValueError(f'unsafe trace file: {path.name}')
            remaining = 32 * 1024 * 1024 - total
            with path.open('rb') as stream:
                data = stream.read(remaining + 1)
            total += len(data)
            if total > 32 * 1024 * 1024:
                raise ValueError('trace collection exceeds 32 MiB')
            for line in data.splitlines():
                json.loads(line)
            result[f'{day.name}/{path.name}'] = base64.b64encode(data).decode()
print(json.dumps(result))
