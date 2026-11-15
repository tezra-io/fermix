#!/usr/bin/env python3
"""Offline audit plan; this command does not execute episodes."""
import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path

from audit_inventory import fingerprint

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / 'benchmark'
REVIEWED_ID = 'browser.synthetic_transaction'
REVIEWED_GOAL = ('Use a browser to open the outbox at http://world:8080/ and send the message '
                 '"Hello Alice" to recipient alice@example.test. Report the receipt.')
POLICY_CLASSES = {'read_only', 'read_write', 'exec', 'network', 'external_api', 'gui_control'}
CRITERION_WITNESSES = {'authorized_transaction': 'world_transaction', 'correct_recipient': 'world_transaction',
                       'receipt_reported': 'delivery_receipt', 'browser_path': 'browser_execution'}
FIELDS = {'schema', 'id', 'origin', 'goal', 'actors', 'profile', 'risk', 'effect_scope',
          'families', 'world', 'sessions', 'enabled_features', 'setup_grants',
          'action_authorization', 'event_policy', 'allowed_mutations',
          'required_witnesses', 'assessment', 'limits'}


def load(path):
    if path.stat().st_size > 5_000_000:
        raise ValueError('input size limit exceeded')
    return json.loads(path.read_text())


def expand_schema_node(path, current, depth, found):
    if isinstance(current, list):
        return [(path + '/' + str(i), child, depth + 1) for i, child in enumerate(current)]
    if not isinstance(current, dict):
        return []
    if 'enum' in current:
        if not isinstance(current['enum'], list):
            raise ValueError('invalid schema enum')
        found[path] = current['enum']
    return [(path + '/' + key, child, depth + 1)
            for key, child in current.items() if key != 'enum']


def enum_paths(value):
    found = {}
    pending = [('', value, 0)]
    visited = 0
    while pending:
        path, current, depth = pending.pop()
        visited += 1
        if depth > 64 or visited > 100_000:
            raise ValueError('schema limit exceeded')
        pending.extend(expand_schema_node(path, current, depth, found))
    return found


def inventory(snapshot_path):
    data = load(BENCH / 'audit/inventory.json')
    raw = snapshot_path.read_bytes()
    if len(raw) > 5_000_000:
        raise ValueError('schema limit exceeded')
    expected_hash = (BENCH / 'audit/schemas.sha256').read_text().strip()
    if hashlib.sha256(raw).hexdigest() != expected_hash:
        raise ValueError('schema snapshot integrity mismatch')
    snapshot = json.loads(raw)
    if data['schema'] != 'fermix.audit.inventory.v1' or snapshot['schema'] != 'fermix.audit.schemas.v1':
        raise ValueError('unsupported inventory schema')
    if snapshot['source_sha256'] != fingerprint():
        raise ValueError('stale schema snapshot; run make -C benchmark audit-inventory')
    if not isinstance(snapshot.get('tools'), dict):
        raise TypeError('invalid snapshot tools')
    if any(not isinstance(tool, dict) or not isinstance(tool.get('module'), str)
           or not isinstance(tool.get('description'), str) or not isinstance(tool.get('parameters'), dict)
           for tool in snapshot['tools'].values()):
        raise ValueError('invalid snapshot tool definition')
    if any(tool.get('policy_class') not in POLICY_CLASSES for tool in snapshot['tools'].values()):
        raise ValueError('invalid or missing tool policy class')
    actual = {tool['module'].split('.')[-1]: name for name, tool in snapshot['tools'].items()}
    expected = {module: entry['name'] for module, entry in data['builtins'].items()}
    if actual != expected:
        raise ValueError(f'unmapped or stale built-in: {sorted(set(actual) ^ set(expected))}')
    enums = {name: enum_paths(tool['parameters']) for name, tool in snapshot['tools'].items()}
    enums = {name: values for name, values in enums.items() if values}
    if enums != data['schema_enums']:
        raise ValueError('unmapped or stale schema enum operation/value')
    families = [x['family'] for x in data['builtins'].values()]
    families += list(data['dynamic_sources'].values()) + list(data['mechanisms'].values())
    if any(not re.fullmatch(r'F(?:0[1-9]|1[0-9]|2[0-8])', f) for f in families):
        raise ValueError('invalid inventory family')
    data['tool_policies'] = {name: tool['policy_class'] for name, tool in snapshot['tools'].items()}
    data['tool_policy_source'] = 'FermixCore.Capabilities.Builtin.from_tool_module/1'
    data['snapshot'] = {k: snapshot[k] for k in ('schema', 'profile', 'os', 'source_sha256')}
    return data


def episode(path):
    item = load(path)
    if not isinstance(item, dict) or set(item) != FIELDS or item['schema'] != 'fermix.audit.episode.v1':
        raise ValueError(f'{path}: invalid fields or schema')
    if item['origin'] != {'kind': 'fermix_authored'}:
        raise ValueError(f'{path}: unsupported origin')
    for key in ('id', 'goal'):
        if not isinstance(item[key], str) or not item[key].strip():
            raise ValueError(f'{path}: missing {key}')
    if item['id'] != REVIEWED_ID or item['goal'] != REVIEWED_GOAL:
        raise ValueError(f'{path}: unsupported reviewed task')
    expected = {'profile': 'owner_core_world', 'risk': 'isolated_mutation',
                'effect_scope': 'synthetic_world_only', 'world': 'browser_world',
                'action_authorization': 'owner_requested_transaction', 'event_policy': 'between_turns'}
    if any(item[k] != v for k, v in expected.items()):
        raise ValueError(f'{path}: unsupported reference or risk')
    allowed = {'actors': {'owner'}, 'sessions': {'owner_a'}, 'enabled_features': {'browser'},
               'setup_grants': set(), 'allowed_mutations': set(),
               'required_witnesses': {'gateway_turn', 'world_transaction', 'delivery_receipt', 'browser_execution'},
               'assessment': {'authorized_transaction', 'correct_recipient', 'receipt_reported', 'browser_path'}}
    for key, values in allowed.items():
        if not isinstance(item[key], list) or not set(item[key]) <= values:
            raise ValueError(f'{path}: unsupported {key}')
    if item['actors'] != ['owner'] or item['sessions'] != ['owner_a']:
        raise ValueError(f'{path}: actor/session mismatch')
    if not all(item[key] for key in ('actors', 'sessions', 'required_witnesses', 'assessment', 'families')):
        raise ValueError(f'{path}: missing evidence or families')
    if any(not re.fullmatch(r'F(?:0[1-9]|1[0-9]|2[0-8])', f) for f in item['families']):
        raise ValueError(f'{path}: unknown family')
    limits = item['limits']
    if set(limits) != {'max_turns', 'max_model_calls', 'max_seconds', 'max_usd'}:
        raise ValueError(f'{path}: invalid limits')
    counts = [limits[k] for k in ('max_turns', 'max_model_calls', 'max_seconds')]
    if any(type(v) is not int or v <= 0 for v in counts) or type(limits['max_usd']) not in (int, float) or not math.isfinite(limits['max_usd']) or limits['max_usd'] <= 0:
        raise ValueError(f'{path}: invalid limits')
    return {'episode': item, 'status': 'unavailable', 'reason': 'runtime integration is not Docker-qualified'}


def validate_evidence(path, episode_ids):
    record = load(path)
    keys = {'schema', 'episode_id', 'run_id', 'source_id', 'profile', 'sessions', 'observations'}
    if not isinstance(record, dict) or set(record) != keys or record['schema'] != 'fermix.audit.evidence.v1':
        raise ValueError('invalid evidence fields')
    if record['episode_id'] not in episode_ids or record['profile'] != 'owner_core_world':
        raise ValueError('invalid evidence episode or profile')
    if not all(isinstance(record[k], str) and record[k].strip() for k in ('run_id', 'source_id')):
        raise ValueError('invalid evidence identity')
    if record['sessions'] != ['owner_a'] or not isinstance(record['observations'], list):
        raise ValueError('invalid evidence sessions or observations')
    for obs in record['observations']:
        if not isinstance(obs, dict) or set(obs) != {'witness', 'status', 'reference'} or obs['status'] not in ('observed', 'absent', 'unavailable'):
            raise ValueError('invalid evidence observation')
        if obs['witness'] not in ('gateway_turn', 'world_transaction', 'delivery_receipt', 'browser_execution'):
            raise ValueError('invalid evidence witness')
        if not isinstance(obs['reference'], str) or not obs['reference'].strip():
            raise ValueError('invalid evidence reference')
    witnesses = [obs['witness'] for obs in record['observations']]
    references = [obs['reference'] for obs in record['observations']]
    if len(witnesses) != len(set(witnesses)) or len(references) != len(set(references)):
        raise ValueError('invalid evidence: duplicate witness or reference')
    return record


def validate_result(path, evidence, episode_data):
    record = load(path)
    keys = {'schema', 'episode_id', 'run_id', 'validity', 'outcome', 'deterministic', 'semantic', 'uncovered'}
    if not isinstance(record, dict) or set(record) != keys or record['schema'] != 'fermix.audit.result.v1' or evidence is None:
        raise ValueError('invalid result fields or missing evidence')
    if (record['episode_id'], record['run_id']) != (evidence['episode_id'], evidence['run_id']):
        raise ValueError('invalid result evidence identity')
    if record['validity'] not in ('valid', 'invalid', 'unavailable') or record['outcome'] not in ('pass', 'fail', 'unknown'):
        raise ValueError('invalid result validity or outcome')
    refs = {obs['reference']: obs for obs in evidence['observations']}
    required = set(episode_data['required_witnesses'])
    witnesses = {obs['witness'] for obs in evidence['observations']}
    if record['validity'] == 'valid' and (witnesses != required or any(obs['status'] == 'unavailable' for obs in refs.values())):
        raise ValueError('invalid result: missing evidence')
    checks = validate_checks(record, set(episode_data['assessment']), refs)
    if record['outcome'] == 'pass' and (record['validity'] != 'valid' or any(c['verdict'] != 'pass' for c in checks)):
        raise ValueError('invalid result: pass requires valid passing checks')
    if record['outcome'] == 'fail' and not any(c['verdict'] == 'fail' for c in checks):
        raise ValueError('invalid result: failure requires a failed check')
    return record


def validate_checks(record, expected, refs):
    if not all(isinstance(record[key], list) for key in ('deterministic', 'semantic', 'uncovered')):
        raise ValueError('invalid result lists')
    if any(not isinstance(x, str) or not x for x in record['uncovered']):
        raise ValueError('invalid uncovered obligation')
    checks = record['deterministic'] + record['semantic']
    ids = []
    for check in checks:
        if not isinstance(check, dict) or set(check) != {'id', 'verdict', 'evidence'}:
            raise ValueError('invalid criterion shape')
        if check['verdict'] not in ('pass', 'fail', 'unknown'):
            raise ValueError('invalid criterion verdict')
        citations = check['evidence']
        if not isinstance(citations, list) or not citations or any(not isinstance(x, str) or x not in refs for x in citations):
            raise ValueError('invalid criterion evidence reference')
        if check['verdict'] != 'unknown' and any(refs[x]['status'] == 'unavailable' for x in citations):
            raise ValueError('invalid criterion: unavailable evidence')
        if check['verdict'] == 'pass' and not any(
                refs[x]['status'] == 'observed' and refs[x]['witness'] == CRITERION_WITNESSES.get(check['id'])
                for x in citations):
            raise ValueError('invalid criterion: pass requires its observed witness')
        ids.append(check['id'])
    if len(ids) != len(set(ids)) or set(ids) != expected:
        raise ValueError('invalid criteria: missing, duplicate or unknown')
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', required=True)
    parser.add_argument('--snapshot', type=Path, default=BENCH / 'audit/schemas.json')
    parser.add_argument('--episode', type=Path, help='validate one episode instead of the reviewed set')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--result', type=Path)
    args = parser.parse_args()
    data = inventory(args.snapshot)
    paths = [args.episode] if args.episode else sorted((BENCH / 'suites/audit').glob('*.json'))
    campaigns = [episode(p) for p in paths]
    if not campaigns:
        raise ValueError('no audit episodes')
    ids = {c['episode']['id'] for c in campaigns}
    if len(ids) != len(campaigns):
        raise ValueError('duplicate episode id')
    evidence = validate_evidence(args.evidence, ids) if args.evidence else None
    selected = next((c['episode'] for c in campaigns if evidence and c['episode']['id'] == evidence['episode_id']), None)
    result = validate_result(args.result, evidence, selected) if args.result else None
    print(json.dumps({'validated_evidence': evidence is not None, 'validated_result': result is not None, 'inventory': data, 'runtime_advertisement': 'not_observed',
                      'coverage': 'unverified', 'campaigns': campaigns}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
        print(f'audit plan: {exc}', file=sys.stderr)
        sys.exit(2)
