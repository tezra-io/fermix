#!/usr/bin/env python3
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'benchmark/bin/run_audit.py'

class AuditPlanTest(unittest.TestCase):
    def run_plan(self, *args):
        return subprocess.run([sys.executable, str(CLI), '--dry-run', *args],
                              check=False, capture_output=True, text=True, cwd=ROOT, timeout=30)

    def test_plan_is_offline_and_explicit(self):
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertTrue(plan['inventory']['builtins'])
        self.assertEqual(plan['runtime_advertisement'], 'not_observed')
        self.assertTrue(plan['campaigns'])
        self.assertTrue(all(c['status'] == 'unavailable' for c in plan['campaigns']))

    def test_invalid_evidence_and_result_refused(self):
        for option, record in [('--evidence', {'schema': 'fermix.audit.evidence.v1'}),
                               ('--result', {'schema': 'fermix.audit.result.v1'})]:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'record.json'
                path.write_text(json.dumps(record))
                result = self.run_plan(option, str(path))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('invalid', result.stderr)

    def test_complete_ledger_can_prove_task_failed(self):
        evidence = {'schema': 'fermix.audit.evidence.v1', 'episode_id': 'browser.synthetic_transaction',
                    'run_id': 'run-1', 'source_id': 'source-1', 'profile': 'owner_core_world',
                    'sessions': ['owner_a'], 'observations': [
                        {'witness': 'gateway_turn', 'status': 'observed', 'reference': 'turn'},
                        {'witness': 'world_transaction', 'status': 'absent', 'reference': 'ledger'},
                        {'witness': 'delivery_receipt', 'status': 'observed', 'reference': 'delivery'}]}
        result = {'schema': 'fermix.audit.result.v1', 'episode_id': evidence['episode_id'],
                  'run_id': evidence['run_id'], 'validity': 'valid', 'outcome': 'fail',
                  'deterministic': [
                      {'id': 'authorized_transaction', 'verdict': 'fail', 'evidence': ['ledger']},
                      {'id': 'correct_recipient', 'verdict': 'fail', 'evidence': ['ledger']}],
                  'semantic': [], 'uncovered': []}
        with tempfile.TemporaryDirectory() as tmp:
            evidence_path, result_path = Path(tmp) / 'evidence.json', Path(tmp) / 'result.json'
            evidence_path.write_text(json.dumps(evidence))
            def check():
                result_path.write_text(json.dumps(result))
                return self.run_plan('--evidence', str(evidence_path), '--result', str(result_path))
            plan = check()
            self.assertEqual(plan.returncode, 0, plan.stderr)
            result['outcome'] = 'pass'
            self.assertNotEqual(check().returncode, 0)
            result['outcome'] = 'fail'
            result['deterministic'][0]['evidence'] = ['forged']
            self.assertNotEqual(check().returncode, 0)
            result['deterministic'][0]['evidence'] = ['ledger']
            result['deterministic'][1]['id'] = 'authorized_transaction'
            self.assertNotEqual(check().returncode, 0)
            result['deterministic'][1]['id'] = 'unknown_criterion'
            self.assertNotEqual(check().returncode, 0)
            result['deterministic'][1]['id'] = 'correct_recipient'
            result['validity'], result['outcome'] = 'invalid', 'pass'
            self.assertNotEqual(check().returncode, 0)
            result['validity'], result['outcome'] = 'valid', 'fail'
            result['deterministic'].pop()
            self.assertNotEqual(check().returncode, 0)
            evidence['observations'][1]['status'] = 'unavailable'
            evidence_path.write_text(json.dumps(evidence))
            self.assertNotEqual(check().returncode, 0)

    def test_invalid_budget_and_risk_refused(self):
        original = json.loads((ROOT / 'benchmark/suites/audit/core.json').read_text())
        for key, value in [('max_turns', 1.5), ('max_turns', True), ('max_usd', float('inf'))]:
            case = json.loads(json.dumps(original))
            case['limits'][key] = value
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'episode.json'
                path.write_text(json.dumps(case))
                plan = self.run_plan('--episode', str(path))
                self.assertNotEqual(plan.returncode, 0)
                self.assertIn('invalid limits', plan.stderr)
        original['risk'] = 'external_write'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'episode.json'
            path.write_text(json.dumps(original))
            self.assertIn('unsupported reference or risk', self.run_plan('--episode', str(path)).stderr)

    def test_snapshot_content_tampering_is_refused(self):
        snapshot = json.loads((ROOT / 'benchmark/audit/schemas.json').read_text())
        snapshot['tools']['browser']['parameters']['description'] = 'tampered'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'schemas.json'
            path.write_text(json.dumps(snapshot))
            self.assertIn('integrity', self.run_plan('--snapshot', str(path)).stderr)

    def test_changed_schema_dependency_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ('benchmark/audit', 'benchmark/bin', 'benchmark/suites/audit',
                              'apps/fermix_core/lib', 'config'):
                shutil.copytree(ROOT / directory, root / directory)
            shutil.copy(ROOT / 'mix.lock', root / 'mix.lock')
            registry = root / 'apps/fermix_core/lib/fermix_core/checklists/registry.ex'
            registry.write_text(registry.read_text().replace('@ops ~w(create ', '@ops ~w(new_op create '))
            result = subprocess.run([sys.executable, str(root / 'benchmark/bin/run_audit.py'), '--dry-run'],
                                    check=False, capture_output=True, text=True, cwd=root, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('stale schema snapshot', result.stderr)

    def run_changed_snapshot(self, change):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ('benchmark/audit', 'benchmark/bin', 'benchmark/suites/audit',
                              'apps/fermix_core/lib', 'config'):
                shutil.copytree(ROOT / directory, root / directory)
            shutil.copy(ROOT / 'mix.lock', root / 'mix.lock')
            path = root / 'benchmark/audit/schemas.json'
            snapshot = json.loads(path.read_text())
            change(snapshot)
            encoded = json.dumps(snapshot).encode()
            path.write_bytes(encoded)
            (root / 'benchmark/audit/schemas.sha256').write_text(hashlib.sha256(encoded).hexdigest())
            return subprocess.run([sys.executable, str(root / 'benchmark/bin/run_audit.py'), '--dry-run'],
                                  check=False, capture_output=True, text=True, cwd=root, timeout=30)

    def test_malformed_snapshot_fails_cleanly(self):
        def corrupt(snapshot):
            snapshot['tools'] = []
        result = self.run_changed_snapshot(corrupt)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid snapshot', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_excessive_schema_nesting_fails_cleanly(self):
        def nest(snapshot):
            value = {}
            for _ in range(70):
                value = {'child': value}
            snapshot['tools']['browser']['parameters'] = value
        result = self.run_changed_snapshot(nest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('schema limit', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_snapshot_operation_without_mapping_is_refused(self):
        def add_operation(snapshot):
            schema = snapshot['tools']['checklist_edit']['parameters']
            schema['properties']['changes']['items']['properties']['ops']['items']['properties']['op']['enum'].append('unmapped_control')
        result = self.run_changed_snapshot(add_operation)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unmapped', result.stderr)

    def test_unmapped_builtin_refused_by_cli(self):
        def add_tool(snapshot):
            snapshot['tools']['unmapped_control'] = {'module': 'FermixCore.Tools.UnmappedControl', 'description': 'control', 'parameters': {}}
        result = self.run_changed_snapshot(add_tool)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('UnmappedControl', result.stderr)

if __name__ == '__main__':
    unittest.main()
