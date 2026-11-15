"""Replace the container process with the real audit daemon."""
import os
from pathlib import Path

run_id = os.environ['FERMIX_AUDIT_RUN_ID']
token = Path('/home/audit/fermix/audit-token').read_text()
if not token or not run_id:
    raise ValueError('audit token and run ID are required')
env = dict(os.environ, ANTHROPIC_API_KEY=token)
os.execvpe('mix', ['mix', 'run', '--no-compile', '--no-start',
                   'benchmark/audit/docker/audit_observer_launch.exs'], env)
