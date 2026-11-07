import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, call, patch

from audit_episode import (
    Services,
    assess_episode,
    build_plan,
    execute_episode,
    prepare_campaign,
    reservations_match,
)


def audit_episode_signal_alarm():
    import signal
    return signal.ITIMER_REAL


class EpisodeTest(unittest.TestCase):
    def setUp(self):
        self.session = 'audit-123'
        self.reply = {'status': 'ok', 'session_id': self.session,
                      'response': 'Sent. Receipt: abc123'}
        self.ledger = [{'recipient': 'alice@example.test', 'message': 'Hello Alice', 'receipt': 'abc123'}]
        self.proxy = [{'run_id': 'r', 'status': 200, 'terminal': 'complete',
                       'request_id': 'req-1', 'request': {'model': 'claude-opus-5-5'},
                       'observed_usage': {'input_tokens': 12, 'output_tokens': 3}}]
        self.traces = [{'kind': 'event', 'type': 'tool_exec', 'seq': 1,
                        'data': {'session_id': 'main-100', 'tool': 'browser', 'success': True, 'output': 'Receipt: abc123'}},
                       {'kind': 'event', 'type': 'llm_call', 'seq': 2, 'data': {'session_id': 'main-100', 'provider': 'anthropic', 'model': 'claude-opus-5-5', 'status': 'ok', 'request_id': 'req-1'}},
                       {'kind': 'event', 'type': 'agent_event', 'seq': 3,
                        'data': {'session_id': 'main-100', 'channel': 'cli',
                                 'chat_id': self.session, 'event': 'turn_complete'}},
                       {'kind': 'checkpoint', 'seq': 10}]

    def check(self, **changes):
        from run_audit import inventory
        tool_policies = inventory(Path(__file__).resolve().parents[1] / 'audit/schemas.json')['tool_policies']
        args = {'run_id': 'r', 'session': self.session, 'reply': self.reply, 'records': self.ledger,
                    'proxy_records': self.proxy, 'traces': self.traces, 'real_inference': True, 'reservations_complete': True,
                    'tool_policies': tool_policies}
        args.update(changes)
        return assess_episode(**args)

    def test_browser_homepage_and_shell_send_do_not_prove_browser_transaction(self):
        homepage = dict(self.traces[0], data=dict(self.traces[0]['data'], output='Outbox homepage'))
        shell = {'kind': 'event', 'type': 'tool_exec',
                 'data': {'session_id': 'main-100', 'tool': 'shell', 'success': True}}
        verdict = self.check(traces=[homepage, shell, *self.traces[1:]])
        self.assertEqual(verdict['task'], 'pass')
        self.assertEqual(verdict['checks']['browser_path'], False)
        self.assertEqual(verdict['outcome'], 'fail')
        self.assertEqual(self.check(traces=[homepage, *self.traces[1:]])['checks']['browser_path'], False)
        missing = dict(self.traces[0], data={k: v for k, v in self.traces[0]['data'].items() if k != 'output'})
        self.assertEqual(self.check(traces=[missing, *self.traces[1:]])['validity'], 'invalid')

    def test_generated_result_uses_phase_zero_contract(self):
        import audit_episode
        import run_audit
        verdict = self.check()
        evidence, result = audit_episode.build_contracts('r', 'source', verdict, self.ledger)
        with tempfile.TemporaryDirectory() as tmp:
            evidence_path, result_path = Path(tmp) / 'evidence.json', Path(tmp) / 'result.json'
            evidence_path.write_text(json.dumps(evidence))
            result_path.write_text(json.dumps(result))
            checked = run_audit.validate_evidence(evidence_path, {'browser.synthetic_transaction'})
            episode = run_audit.episode(audit_episode.EPISODE)['episode']
            self.assertEqual(run_audit.validate_result(result_path, checked, episode)['outcome'], 'pass')

    def test_written_contracts_are_validated(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            verdict = self.check()
            audit_episode.write_contracts(output, 'r', 'source', verdict, self.ledger)
            self.assertEqual(json.loads((output / 'result.json').read_text())['outcome'], 'pass')
            self.assertEqual(json.loads((output / 'evidence.json').read_text())['schema'],
                             'fermix.audit.evidence.v1')

    def test_invalid_contract_references_diagnostic_not_missing_artifacts(self):
        import audit_episode
        verdict = {'validity': 'invalid', 'outcome': 'unknown'}
        evidence, result = audit_episode.build_contracts('r', 'source', verdict, [])
        self.assertTrue(all(o['reference'].startswith('manifest.json#/unavailable/')
                            for o in evidence['observations']))
        self.assertTrue(all(c['verdict'] == 'unknown' for c in result['deterministic']))

    def test_no_action_contract_is_a_valid_task_failure(self):
        import audit_episode
        import run_audit
        verdict = self.check(records=[], traces=self.traces[1:])
        self.assertEqual(verdict['validity'], 'valid')
        evidence, result = audit_episode.build_contracts('r', 'source', verdict, [])
        with tempfile.TemporaryDirectory() as tmp:
            evidence_path, result_path = Path(tmp) / 'evidence.json', Path(tmp) / 'result.json'
            evidence_path.write_text(json.dumps(evidence))
            result_path.write_text(json.dumps(result))
            checked = run_audit.validate_evidence(evidence_path, {'browser.synthetic_transaction'})
            episode = run_audit.episode(audit_episode.EPISODE)['episode']
            self.assertEqual(run_audit.validate_result(result_path, checked, episode)['outcome'], 'fail')
        self.assertIn('absent', [entry['status'] for entry in evidence['observations']])

    def test_real_complete_action_and_wrong_controls(self):
        self.assertEqual(self.check()['outcome'], 'pass')
        for records, reply in [([], self.reply),
                               ([dict(self.ledger[0], recipient='bob@example.test')], self.reply),
                               (self.ledger * 2, self.reply),
                               (self.ledger, dict(self.reply, response='Sent. Receipt: forged'))]:
            with self.subTest(records=records, reply=reply):
                self.assertEqual(self.check(records=records, reply=reply)['outcome'], 'fail')

    def test_mock_and_missing_evidence_never_pass(self):
        for changes in ({'real_inference': False}, {'proxy_records': []},
                        {'reply': None}, {'traces': []}, {'traces': self.traces + [self.traces[-2]]},
                        {'traces': self.traces + [dict(self.traces[0], seq=11)]},
                        {'reservations_complete': False}):
            with self.subTest(changes=changes):
                self.assertNotEqual(self.check(**changes)['outcome'], 'pass')
        self.assertEqual(self.check(real_inference=False)['validity'], 'unavailable')
        self.assertEqual(self.check(proxy_records=[])['validity'], 'invalid')
        self.assertEqual(self.check(traces=[])['validity'], 'invalid')
        self.assertEqual(self.check(traces=self.traces[1:])['pathway'], 'not_observed')

    def test_inference_and_measurement_status_are_distinct(self):
        import audit_episode
        records = [self.proxy[0], dict(self.proxy[0], status=429, terminal='budget_exhausted')]
        self.assertTrue(audit_episode.observed_live_inference(records))
        self.assertEqual(self.check(proxy_records=records)['validity'], 'invalid')

    def test_budget_and_provider_failure_are_invalid(self):
        self.assertEqual(self.check(proxy_records=[dict(self.proxy[0], observed_usage={'input_tokens': 1})])['validity'], 'invalid')
        budget = [dict(self.proxy[0], status=429, terminal='budget_exhausted')]
        self.assertEqual(self.check(proxy_records=budget)['reason'], 'budget exhausted')
        for status in (429, 502):
            proxy = [dict(self.proxy[0], status=status)]
            self.assertEqual(self.check(proxy_records=proxy)['validity'], 'invalid')

    def test_replay_campaign_error_is_reported_unavailable(self):
        import audit_episode
        with patch.object(sys, 'argv', ['audit_episode.py', '--replay', '--campaign-dir', '/tmp/missing']), \
             patch.object(audit_episode, 'replay', side_effect=ValueError('bad campaign')), \
             patch('builtins.print') as output:
            self.assertEqual(audit_episode.main(), 2)
            self.assertIn('unavailable', output.call_args.args[0])

    def test_replay_unavailable_exits_nonzero(self):
        import audit_episode
        with patch.object(sys, 'argv', ['audit_episode.py', '--replay', '--campaign-dir', '/tmp/campaign']), \
             patch.object(audit_episode, 'replay', return_value={'validity': 'unavailable', 'outcome': 'unknown'}), \
             patch('builtins.print'):
            self.assertEqual(audit_episode.main(), 2)

    def test_dry_run_does_not_create_campaign(self):
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('audit_episode.py')),
                                     '--dry-run', '--campaign-dir', str(campaign)],
                                    capture_output=True, text=True, timeout=10, check=True)
            self.assertEqual(json.loads(result.stdout)['campaign_dir'], str(campaign))
            self.assertFalse(campaign.exists())

    def test_plan_refuses_unsupported_risk(self):
        import audit_episode
        episode = json.loads(audit_episode.EPISODE.read_text())
        episode['risk'] = 'external_write'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'episode.json'
            path.write_text(json.dumps(episode))
            with patch.object(audit_episode, 'EPISODE', path), self.assertRaises(ValueError):
                build_plan()

    def test_plan_is_explicit_and_bounded(self):
        plan = build_plan()
        self.assertEqual(plan['campaign_budget_usd'], 100)
        self.assertEqual(plan['episode_budget_usd'], 23)
        self.assertEqual(plan['real_inference'], False)
        self.assertIn('Alice', plan['goal'])


    def test_unrelated_proxy_success_cannot_cover_failed_owner_provider(self):
        traces = list(self.traces)
        traces[1] = {'kind': 'event', 'type': 'llm_call', 'seq': 2,
                     'data': {'session_id': 'main-100', 'provider': 'anthropic',
                              'model': 'claude-opus-5-5', 'status': 'error', 'request_id': 'req-x'}}
        self.assertEqual(self.check(traces=traces)['validity'], 'invalid')

    def test_provider_requires_matching_unique_expected_request(self):
        for proxy in ([dict(self.proxy[0], request_id='different')],
                      [dict(self.proxy[0], request={'model': 'other'})],
                      [self.proxy[0], self.proxy[0]]):
            with self.subTest(proxy=proxy):
                self.assertEqual(self.check(proxy_records=proxy)['validity'], 'invalid')
        for change in ({'request_id': None}, {'model': 'other'}, {'provider': 'other'}):
            traces = list(self.traces)
            traces[1] = dict(traces[1], data=dict(traces[1]['data'], **change))
            with self.subTest(change=change):
                self.assertEqual(self.check(traces=traces)['validity'], 'invalid')

    def test_unknown_and_delivery_actions_do_not_pass_browser_path(self):
        for name in ('unknown_tool', 'react', 'shell'):
            event = {'kind': 'event', 'type': 'tool_exec', 'seq': 8,
                     'data': {'session_id': 'main-100', 'tool': name, 'success': True}}
            verdict = self.check(traces=[event, *self.traces], tool_policies={name: 'read_only'})
            if name == 'unknown_tool':
                verdict = self.check(traces=[event, *self.traces], tool_policies={})
            if name == 'shell':
                verdict = self.check(traces=[event, *self.traces], tool_policies={'shell': 'exec'})
            self.assertEqual(verdict['outcome'], 'fail')

    def test_read_only_builtin_does_not_invalidate_browser(self):
        for name in ('tool_help', 'tool_describe', 'memory_recall'):
            event = {'kind': 'event', 'type': 'tool_exec', 'seq': 8,
                     'data': {'session_id': 'main-100', 'tool': name, 'success': True}}
            self.assertEqual(self.check(traces=[event, *self.traces])['outcome'], 'pass')

    def test_result_references_concrete_trace_sequence(self):
        import audit_episode
        verdict = self.check()
        evidence, _ = audit_episode.build_contracts('r', 'source', verdict, self.ledger)
        refs = {entry['witness']: entry['reference'] for entry in evidence['observations']}
        self.assertEqual(refs['gateway_turn'], 'observer.jsonl#seq=3')
        self.assertEqual(refs['browser_execution'], 'observer.jsonl#seq=1')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'observer.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in self.traces))
            (path / 'observations.json').write_text(json.dumps({'records': self.ledger, 'reply': self.reply}))
            observer = [json.loads(line) for line in (path / 'observer.jsonl').read_text().splitlines()]
            for witness in ('gateway_turn', 'browser_execution'):
                sequence = int(refs[witness].split('#seq=')[1])
                self.assertEqual(len([row for row in observer if row.get('seq') == sequence]), 1)
            observations = json.loads((path / 'observations.json').read_text())
            for witness in ('world_transaction', 'delivery_receipt'):
                pointer = refs[witness].split('#/')[1]
                self.assertIn(pointer, observations)
    def test_browser_reference_points_at_matching_receipt(self):
        import audit_episode
        first = dict(self.traces[0], seq=9, data=dict(self.traces[0]['data'], output='opened'))
        verdict = self.check(traces=[first, *self.traces])
        evidence, _ = audit_episode.build_contracts('r', 'source', verdict, self.ledger)
        browser = next(x for x in evidence['observations'] if x['witness'] == 'browser_execution')
        self.assertEqual(browser['reference'], 'observer.jsonl#seq=1')

    def test_ambiguous_observer_sequence_invalidates(self):
        duplicate = {'kind': 'event', 'type': 'agent_event', 'seq': 1, 'data': {}}
        self.assertEqual(self.check(traces=[duplicate, *self.traces])['validity'], 'invalid')

    def test_missing_turn_seq_invalidates(self):
        traces = list(self.traces)
        traces[2] = {k: v for k, v in traces[2].items() if k != 'seq'}
        self.assertEqual(self.check(traces=traces)['validity'], 'invalid')
    def test_failed_bridge_guard_can_recover_but_success_is_inconsistent(self):
        event = {'kind': 'event', 'type': 'tool_exec', 'seq': 8,
                 'data': {'session_id': 'main-100', 'tool': 'tool_call', 'success': False}}
        policy = {'tool_call': 'read_only'}
        self.assertEqual(self.check(traces=[event, *self.traces], tool_policies=policy)['outcome'], 'pass')
        event['data']['success'] = True
        self.assertEqual(self.check(traces=[event, *self.traces], tool_policies=policy)['validity'], 'invalid')


class LifecycleTest(unittest.TestCase):
    def test_cleanup_failure_reports_prior_unavailable_reason(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            failed = {'validity': 'unavailable', 'outcome': 'unknown', 'reason': 'preflight refused'}
            with patch.object(audit_episode, 'build_image', return_value={'image_id': 'sha256:1'}), \
                 patch.object(audit_episode, 'replay_image', return_value=failed), \
                 patch.object(audit_episode, 'run', side_effect=RuntimeError('cleanup failed')):
                result = audit_episode.replay(campaign)
            self.assertIn('preflight refused', result['reason'])
            self.assertIn('cleanup failed', result['reason'])

    def test_cleanup_failure_preserves_original_error(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            with patch.object(audit_episode, 'build_image', return_value={'image_id': 'sha256:1'}), \
                 patch.object(audit_episode, 'replay_image', side_effect=KeyError('original')), \
                 patch.object(audit_episode, 'run', side_effect=RuntimeError('cleanup')):
                result = audit_episode.replay(campaign)
            self.assertIn('original', result['reason'])
            self.assertIn('cleanup', result['reason'])

    def test_cancelled_replay_still_removes_owned_image(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            with patch.object(audit_episode, 'build_image', return_value={'image_id': 'sha256:1'}), \
                 patch.object(audit_episode, 'replay_image', side_effect=KeyboardInterrupt), \
                 patch.object(audit_episode, 'run') as docker:
                result = audit_episode.replay(campaign)
            self.assertEqual(result['validity'], 'invalid')
            self.assertTrue(any(c.args[0][:3] == ['docker', 'image', 'rm'] for c in docker.call_args_list))

    def test_run_identity_is_persisted_before_build(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            def failed_build(*_args):
                runs = list((campaign / 'runs').iterdir())
                self.assertEqual(len(runs), 1)
                identity = json.loads((runs[0] / 'initial.json').read_text())
                self.assertIn('owner', identity)
                self.assertIn('target', identity['resources'])
                self.assertIn('image_tag', identity)
                raise RuntimeError('build failed')
            with patch.object(audit_episode, 'build_image', side_effect=failed_build):
                result = audit_episode.replay(campaign)
            self.assertEqual(result['validity'], 'unavailable')
            self.assertTrue(Path(result['evidence_dir']).joinpath('failure.json').is_file())

    def test_docker_preflight_failure_never_reads_key(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            with patch.object(audit_episode, 'build_image', side_effect=RuntimeError('no docker')), \
                 patch.object(audit_episode, 'read_provider_secret') as credential:
                result = audit_episode.replay(campaign)
            self.assertEqual(result['validity'], 'unavailable')
            self.assertIn('no docker', result['reason'])
            credential.assert_not_called()

    def test_changed_fixture_after_preflight_never_reads_key(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            qualified = {'qualified': True, 'world_sha256': 'old', 'proxy_sha256': 'old'}
            with patch.object(audit_episode, 'build_image', return_value={'image_id': 'sha256:1'}), \
                 patch.object(audit_episode, 'qualify_runtime', return_value=qualified), \
                 patch.object(audit_episode, 'run'), \
                 patch.object(audit_episode, 'read_provider_secret') as credential:
                result = audit_episode.replay(campaign)
            self.assertEqual(result['validity'], 'unavailable')
            credential.assert_not_called()

    def test_unqualified_runtime_never_reads_key(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            prepare_campaign(campaign, create=True)
            with patch.object(audit_episode, 'build_image', return_value={'image_id': 'sha256:1'}), \
                 patch.object(audit_episode, 'qualify_runtime', return_value={'qualified': False}), \
                 patch.object(audit_episode, 'run') as docker, \
                 patch.object(audit_episode, 'read_provider_secret') as credential:
                result = audit_episode.replay(campaign)
            self.assertEqual(result['validity'], 'unavailable')
            credential.assert_not_called()
            cleanup = json.loads((Path(result['evidence_dir']) / 'image-cleanup.json').read_text())
            self.assertEqual(cleanup['status'], 'removed')
            self.assertTrue(any(c.args[0][:3] == ['docker', 'image', 'rm'] for c in docker.call_args_list))

    def test_diagnostic_keeps_chained_cleanup_and_original_failure(self):
        import audit_episode
        try:
            try:
                raise ValueError('original failure')
            finally:
                raise RuntimeError('cleanup failure')
        except RuntimeError as error:
            text = audit_episode.safe_error(error)
        self.assertIn('original failure', text)
        self.assertIn('cleanup failure', text)

    def test_diagnostic_scrubs_secrets_and_keeps_group_causes(self):
        import audit_episode
        error = ExceptionGroup('cleanup', [RuntimeError('provider-key failure'), ValueError('other')])
        text = audit_episode.safe_error(error, ['provider-key'])
        self.assertNotIn('provider-key', text)
        self.assertIn('[REDACTED]', text)
        self.assertIn('other', text)
        self.assertLessEqual(len(text), 2000)

    def test_corrupted_negative_reservation_is_refused(self):
        import sqlite3
        from contextlib import closing
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            budget = prepare_campaign(campaign, create=True)
            with closing(sqlite3.connect(budget / 'reservations.sqlite')) as db, db:
                db.execute('INSERT INTO reservations VALUES (?, ?, ?)', ('r', -1, 1))
            with self.assertRaises(ValueError):
                prepare_campaign(campaign)

    def test_usage_evidence_includes_reserved_amount(self):
        with tempfile.TemporaryDirectory() as tmp:
            budget = prepare_campaign(Path(tmp) / 'campaign', create=True)
            import sqlite3
            from contextlib import closing
            with closing(sqlite3.connect(budget / 'reservations.sqlite')) as db, db:
                db.execute('INSERT INTO reservations VALUES (?, ?, ?)', ('r', 1200000, 1))
            import audit_episode
            self.assertEqual(audit_episode.reserved_microusd(budget, 'r'), 1200000)

    def test_reservation_evidence_must_be_complete_and_unique(self):
        rows = [(1,), (2,)]
        self.assertTrue(reservations_match(rows, [{'reservation_id': 1}, {'reservation_id': 2}]))
        self.assertFalse(reservations_match(rows, [{'reservation_id': 1}]))
        self.assertFalse(reservations_match(rows, [{'reservation_id': 1}, {'reservation_id': 1}]))
        self.assertFalse(reservations_match(rows, []))
        self.assertFalse(reservations_match([], []))

    def test_campaign_rejects_mount_delimiters(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            prepare_campaign(Path(tmp) / 'x,readonly', create=True)

    def test_campaign_preserves_budget_and_refuses_missing_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            campaign = Path(tmp) / 'campaign'
            with self.assertRaises(ValueError):
                prepare_campaign(campaign)
            budget = prepare_campaign(campaign, create=True)
            self.assertEqual(prepare_campaign(campaign), budget)
            (budget / 'reservations.sqlite').unlink()
            with self.assertRaises(ValueError):
                prepare_campaign(campaign)

    def test_preflight_proxy_has_only_mock_upstream(self):
        with tempfile.TemporaryDirectory() as tmp:
            campaign = prepare_campaign(Path(tmp) / 'campaign', create=True)
            work = Path(tmp) / 'work'
            work.mkdir()
            runtime = Mock(run_id='a' * 32, image='image', network='internal', label='label')
            services = Services(runtime, work, campaign, Path(tmp), 'token', 'canary', build_plan(), profile='mock')
            config = json.loads((work / 'secret/config.json').read_text())
            self.assertEqual(config['profile'], 'mock')
            self.assertEqual(config['campaign_identity'], (campaign.parent / 'identity').read_text())
            self.assertEqual(config['mock_upstream'], 'http://127.0.0.1:8081')
            services.remove_secrets()

    def test_failed_secret_setup_cleans_partial_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            campaign = prepare_campaign(Path(tmp) / 'campaign', create=True)
            work = Path(tmp) / 'work'
            work.mkdir()
            runtime = Mock(run_id='a' * 32, image='image', network='internal',
                           label='label', owner_label='owner-label')
            original = Services.write_private
            def write(path, value):
                if path.name == 'provider':
                    raise OSError('disk failure')
                original(path, value)
            with patch.object(Services, 'write_private', side_effect=write), self.assertRaises(OSError):
                Services(runtime, work, campaign, Path(tmp), 'temporary-token', 'provider-key', build_plan())
            self.assertFalse((work / 'secret/token').exists())

    def test_failed_episode_archives_partial_world_and_proxy_before_cleanup(self):
        import audit_episode
        for failure in (TimeoutError('timeout'), RuntimeError('observer failure')):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                budget = prepare_campaign(root / 'campaign', create=True)
                output = root / 'output'
                output.mkdir()
                runtime = Mock(run_id='a' * 32, network='isolated')
                qualification = {f'{name}_sha256': audit_episode.file_hash(
                    audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
                seen = []
                def crash(_runtime, services, token, secret, *_args, seen=seen, failure=failure):
                    seen.append(token)
                    (services.base / 'world/ledger.jsonl').write_text('world ' + secret + '\n')
                    (services.base / 'proxy/request.json').write_text('proxy ' + token)
                    raise failure
                with patch.object(audit_episode, 'execute_episode', side_effect=crash):
                    result = audit_episode.replay_built(budget, runtime, output,
                        {'context_sha256': 'context'}, 'provider-key', build_plan(), qualification)
                self.assertEqual(result['validity'], 'invalid')
                archive = json.loads((output / 'partial-evidence.json').read_text())
                manifest = json.loads((output / 'manifest.json').read_text())
                self.assertEqual(manifest['inference']['target'], 'unknown')
                self.assertEqual(archive['status'], 'partial')
                self.assertEqual(archive['world']['status'], 'captured')
                self.assertEqual(archive['proxy']['status'], 'captured')
                self.assertNotIn('provider-key', json.dumps(archive))
                self.assertNotIn(seen[0], json.dumps(archive))
                self.assertIn('[REDACTED]', json.dumps(archive))

    def test_partial_archive_does_not_cut_through_secret_at_limit(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'item'
            path.write_text('x' * 6 + 'provider-key' + 'tail')
            item = audit_episode.archive_file(path, 10, ['provider-key'])
            self.assertEqual(item['status'], 'truncated')
            self.assertNotIn('prov', item['text'])

    def test_partial_archive_labels_missing_and_preserves_inflight_temp_files(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / 'output'
            output.mkdir()
            audit_episode.archive_partial(root, output, ['secret'])
            archive = json.loads((output / 'partial-evidence.json').read_text())
            self.assertEqual(archive['world']['status'], 'missing')
            self.assertEqual(archive['proxy']['status'], 'missing')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output, proxy = root / 'output', root / 'proxy'
            output.mkdir()
            proxy.mkdir()
            (proxy / 'reservation-1.tmp').write_text('{unfinished secret')
            audit_episode.archive_partial(root, output, ['secret'])
            archive = json.loads((output / 'partial-evidence.json').read_text())
            self.assertEqual(archive['proxy']['files']['reservation-1.tmp']['text'], '{unfinished [REDACTED]')

    def test_invalid_assessment_archives_partial_evidence(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            budget = prepare_campaign(root / 'campaign', create=True)
            output = root / 'output'
            output.mkdir()
            observer = output / 'observer.jsonl'
            observer.write_text('')
            runtime = Mock(run_id='a' * 32, network='isolated')
            qualification = {f'{name}_sha256': audit_episode.file_hash(
                audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
            def incomplete(_runtime, services, *_args):
                (services.base / 'world/ledger.jsonl').write_text('')
                (services.base / 'proxy/request.json').write_text('{"terminal":"in_flight"}')
                return {'observer': observer, 'bootstrap': {}, 'versions': {}, 'drive_error': None,
                        'evidence': {'reply': {}, 'records': [], 'proxy_records': [],
                                     'reservations_complete': False}}
            with patch.object(audit_episode, 'execute_episode', side_effect=incomplete):
                result = audit_episode.replay_built(budget, runtime, output,
                    {'context_sha256': 'context'}, 'provider-key', build_plan(), qualification)
            self.assertEqual(result['validity'], 'invalid')
            self.assertTrue((output / 'partial-evidence.json').is_file())

    def test_cleanup_after_valid_assessment_still_reports_partial_archive(self):
        import audit_episode
        real_temp = tempfile.TemporaryDirectory
        class BrokenTemp(real_temp):
            def __exit__(self, *args):
                super().__exit__(*args)
                raise OSError('temporary cleanup failed')
        with real_temp() as tmp:
            root = Path(tmp)
            budget = prepare_campaign(root / 'campaign', create=True)
            output = root / 'output'
            output.mkdir()
            observer = output / 'observer.jsonl'
            observer.write_text('')
            runtime = Mock(run_id='a' * 32, network='isolated')
            qualification = {f'{name}_sha256': audit_episode.file_hash(
                audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
            complete = {'observer': observer, 'bootstrap': {}, 'versions': {}, 'drive_error': None,
                        'evidence': {'reply': {}, 'records': [], 'proxy_records': [],
                                     'reservations_complete': True}}
            verdict = {'validity': 'valid', 'outcome': 'pass', 'checks': {
                'authorized_transaction': True, 'correct_recipient': True,
                'receipt_reported': True, 'browser_path': True}}
            with patch.object(audit_episode, 'execute_episode', return_value=complete), \
                 patch.object(audit_episode, 'assess_episode', return_value=verdict), \
                 patch.object(audit_episode.tempfile, 'TemporaryDirectory', BrokenTemp):
                result = audit_episode.replay_built(budget, runtime, output,
                    {'context_sha256': 'context'}, 'provider-key', build_plan(), qualification)
            self.assertEqual(result['validity'], 'invalid')
            archive = json.loads((output / 'partial-evidence.json').read_text())
            self.assertEqual(archive['world']['status'], 'missing')

    def test_temporary_cleanup_error_preserves_episode_error(self):
        import audit_episode
        real_temp = tempfile.TemporaryDirectory
        class BrokenTemp(real_temp):
            def __exit__(self, *args):
                super().__exit__(*args)
                raise OSError('temporary cleanup failed')
        with real_temp() as tmp:
            root = Path(tmp)
            budget = prepare_campaign(root / 'campaign', create=True)
            output = root / 'output'
            output.mkdir()
            runtime = Mock(run_id='a' * 32, network='isolated')
            qualification = {f'{name}_sha256': audit_episode.file_hash(
                audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
            with patch.object(audit_episode, 'execute_episode', side_effect=TimeoutError('turn timeout')), \
                 patch.object(audit_episode.tempfile, 'TemporaryDirectory', BrokenTemp):
                result = audit_episode.replay_built(budget, runtime, output,
                    {'context_sha256': 'context'}, 'provider-key', build_plan(), qualification)
            self.assertIn('turn timeout', result['reason'])
            self.assertIn('temporary cleanup failed', result['reason'])
            self.assertTrue((output / 'partial-evidence.json').is_file())

    def test_archive_error_preserves_episode_error(self):
        import audit_episode
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            budget = prepare_campaign(root / 'campaign', create=True)
            output = root / 'output'
            output.mkdir()
            runtime = Mock(run_id='a' * 32, network='isolated')
            qualification = {f'{name}_sha256': audit_episode.file_hash(
                audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
            with patch.object(audit_episode, 'execute_episode', side_effect=TimeoutError('turn timeout')), \
                 patch.object(audit_episode, 'archive_partial', side_effect=OSError('archive disk failed')):
                result = audit_episode.replay_built(budget, runtime, output,
                    {'context_sha256': 'context'}, 'provider-key', build_plan(), qualification)
            self.assertEqual(result['validity'], 'invalid')
            self.assertIn('turn timeout', result['reason'])
            self.assertIn('archive disk failed', result['reason'])

    def test_evidence_copies_redact_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            campaign = prepare_campaign(Path(tmp) / 'campaign', create=True)
            work, output = Path(tmp) / 'work', Path(tmp) / 'output'
            work.mkdir()
            output.mkdir()
            runtime = Mock(run_id='a' * 32, network='internal')
            services = Services(runtime, work, campaign, output, 'temporary-token', 'provider-key', build_plan())
            (work / 'world/ledger.jsonl').write_text(
                json.dumps({'recipient': 'alice@example.test', 'message': 'provider-key', 'receipt': 'abc'}) + '\n')
            (work / 'proxy/a.json').write_text(json.dumps({'request': 'temporary-token'}))
            with patch('audit_episode.time.sleep'):
                result = services.collect('{"response":"provider-key"}', ['temporary-token', 'provider-key'])
            self.assertNotIn('provider-key', str(result))
            self.assertNotIn('temporary-token', str(result))
            for path in output.iterdir():
                self.assertNotIn('provider-key', path.read_text())
                self.assertNotIn('temporary-token', path.read_text())
            services.remove_secrets()

    def test_services_confine_mounts_and_do_not_put_secrets_in_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = Mock(run_id='a' * 32, image='image', network='internal',
                           label='label', owner_label='owner-label')
            campaign = prepare_campaign(Path(tmp) / 'campaign', create=True)
            work = Path(tmp) / 'work'
            work.mkdir()
            output = Path(tmp) / 'output'
            output.mkdir()
            services = Services(runtime, work, campaign, output, 'temporary-token', 'provider-key', build_plan())
            with patch('audit_episode.run', return_value='') as command:
                services.start()
            calls = [x.args[0] for x in command.call_args_list]
            self.assertTrue((work / 'sources/audit_world.py').is_file())
            self.assertTrue((work / 'sources/audit_proxy.py').is_file())
            flattened = str(calls)
            for args in calls[:3]:
                self.assertIn(runtime.owner_label, args)
            proxy_args = calls[1]
            self.assertTrue(any('dst=/secret,readonly' in arg for arg in proxy_args))
            self.assertNotIn('provider-key', flattened)
            self.assertNotIn('temporary-token', flattened)
            self.assertEqual(sum('network' in args and 'connect' in args for args in calls), 1)
            self.assertIn(services.proxy, calls[-1])
            self.assertNotIn(services.world, calls[-1])
            self.assertNotIn(runtime.target, calls[-1])
            services.revoke()
            services.revoke()
            services.cleanup()
            self.assertFalse((work / 'secret').exists())

    def test_gateway_error_still_collects_provider_evidence(self):
        runtime, services = Mock(), Mock()
        runtime.ask.side_effect = subprocess.CalledProcessError(
            1, 'ask', output='{"status":"error","error":"budget"}')
        result = execute_episode(runtime, services, 'token', 'key', 'audit-session', 30, build_plan())
        self.assertIn('CalledProcessError', result['drive_error'])
        runtime.checkpoint.assert_called_once()
        runtime.stop.assert_called_once()
        services.collect.assert_called_once()

    def test_target_readiness_probe_runs_python_isolated(self):
        services = Mock(spec=Services)
        services.runtime = Mock(target='target-container')
        services.proxy = 'proxy-container'
        with patch('audit_episode.run') as call:
            Services.ready(services, timeout=5, target=True)
        self.assertEqual(call.call_args.args[0][:5], ['docker', 'exec', 'target-container', 'python3', '-I'])

    def test_post_turn_review_settles_before_checkpoint(self):
        runtime, services = Mock(), Mock()
        events = Mock()
        events.attach_mock(runtime, 'runtime')
        runtime.ask.return_value = '{"status":"ok"}'
        execute_episode(runtime, services, 'token', 'key', 'audit-session', 30, build_plan())
        order = [name for name, *_ in events.mock_calls
                 if name in ('runtime.ask', 'runtime.wait_for_memory_review', 'runtime.checkpoint')]
        self.assertEqual(order, ['runtime.ask', 'runtime.wait_for_memory_review', 'runtime.checkpoint'])
        runtime.wait_for_memory_review.assert_called_once_with('audit-session', 120)

    def test_failed_turn_does_not_wait_for_review(self):
        runtime, services = Mock(), Mock()
        runtime.ask.side_effect = subprocess.CalledProcessError(1, 'ask', output='{"status":"error"}')
        execute_episode(runtime, services, 'token', 'key', 'audit-session', 30, build_plan())
        runtime.wait_for_memory_review.assert_not_called()
        runtime.checkpoint.assert_called_once()

    def test_episode_installs_and_clears_watchdog(self):
        runtime, services = Mock(), Mock()
        with patch('audit_episode.signal.signal') as set_handler, \
             patch('audit_episode.signal.getsignal', return_value=0), \
             patch('audit_episode.signal.getitimer', return_value=(0, 0)), \
             patch('audit_episode.signal.setitimer') as timer:
            execute_episode(runtime, services, 'token', 'key', 'audit-session', 30, build_plan())
        self.assertIn(call(audit_episode_signal_alarm(), 30), timer.mock_calls)
        self.assertIn(call(audit_episode_signal_alarm(), 0), timer.mock_calls)
        self.assertGreaterEqual(set_handler.call_count, 4)

    def test_revocation_precedes_cleanup_on_success_and_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                services = Mock()
                runtime = Mock()
                events = Mock()
                events.attach_mock(services, 'services')
                events.attach_mock(runtime, 'runtime')
                if fail:
                    runtime.ask.side_effect = RuntimeError('turn failed')
                try:
                    execute_episode(runtime, services, 'token', 'key', 'audit-session', 30, build_plan())
                except RuntimeError:
                    self.assertTrue(fail)
                names = [entry[0] for entry in events.mock_calls]
                self.assertLess(names.index('services.revoke'), names.index('services.cleanup'))
                self.assertLess(names.index('services.cleanup'), names.index('runtime.cleanup'))
                self.assertLess(names.index('services.ready'), names.index('runtime.bootstrap'))
                self.assertIn(call.ready(timeout=30, target=True), services.mock_calls)
                if not fail:
                    self.assertLess(names.index('runtime.collect_traces'), names.index('runtime.stop'))
                    self.assertLess(names.index('runtime.checkpoint'), names.index('runtime.stop'))
                    self.assertLess(names.index('runtime.stop'), names.index('runtime.collect_observer'))
                    self.assertLess(names.index('runtime.stop'), names.index('services.stop_world'))
                    self.assertLess(names.index('services.stop_world'), names.index('services.collect'))
                    self.assertLess(names.index('runtime.stop'), names.index('services.revoke'))
                    self.assertLess(names.index('services.revoke'), names.index('services.collect'))
                self.assertIn(call.bootstrap('claude-opus-5-5', 'http://proxy:8080/v1', 'token'),
                              runtime.mock_calls)


if __name__ == '__main__':
    unittest.main()

class PolicyPinningTest(unittest.TestCase):
    def test_image_policy_mismatch_fails_before_preflight_and_key_lookup(self):
        import audit_episode
        plan = build_plan()
        image = {'image_id': 'image', 'policy_sources': dict(plan['policy_sources'])}
        image['policy_sources'][next(iter(image['policy_sources']))] = 'bad'
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(audit_episode, 'qualify_runtime') as preflight, \
             patch.object(audit_episode, 'read_provider_secret') as key:
            result = audit_episode.replay_image(Path(tmp), Mock(image='image'), Path(tmp), image, plan)
        self.assertEqual(result['validity'], 'unavailable')
        preflight.assert_not_called()
        key.assert_not_called()

    def test_matching_image_policy_reaches_preflight(self):
        import audit_episode
        plan = build_plan()
        image = {'image_id': 'image', 'policy_sources': dict(plan['policy_sources'])}
        with tempfile.TemporaryDirectory() as tmp, \
             patch.object(audit_episode, 'qualify_runtime', return_value={'qualified': False}) as preflight:
            result = audit_episode.replay_image(Path(tmp), Mock(image='image'), Path(tmp), image, plan)
        self.assertEqual(result['validity'], 'unavailable')
        preflight.assert_called_once()

    def test_assessment_uses_frozen_policy_after_execution(self):
        import audit_episode
        plan = build_plan()
        fixture = EpisodeTest()
        fixture.setUp()
        trace = list(fixture.traces)
        trace[2] = dict(trace[2], data=dict(trace[2]['data'], chat_id='audit-r'))
        extra = {'kind': 'event', 'type': 'tool_exec', 'seq': 8,
                 'data': {'session_id': 'main-100', 'tool': 'memory_recall', 'success': True}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            budget = prepare_campaign(root / 'campaign', create=True)
            work, output = root / 'work', root / 'output'
            work.mkdir()
            output.mkdir()
            observer = output / 'observer.jsonl'
            observer.write_text(''.join(json.dumps(row) + '\n' for row in [extra, *trace]))
            evidence = {'reply': dict(fixture.reply, session_id='audit-r'),
                        'records': fixture.ledger, 'proxy_records': fixture.proxy,
                        'reservations_complete': True}
            outcome = {'observer': observer, 'evidence': evidence, 'bootstrap': {},
                       'versions': {}, 'drive_error': None}
            qualification = {f'{name}_sha256': audit_episode.file_hash(
                audit_episode.ROOT / f'benchmark/bin/audit_{name}.py') for name in ('world', 'proxy')}
            with patch.object(audit_episode, 'execute_episode', return_value=outcome), \
                 patch.object(audit_episode, 'validate_inventory', side_effect=AssertionError('must not reload')):
                verdict, _ = audit_episode.run_attempt(budget, Mock(run_id='r', network='n'), output,
                    {}, 'provider-key', 'run-token', plan, qualification, work, {'inference': {}})
            self.assertEqual(verdict['outcome'], 'pass')

    def test_plan_freezes_classifications(self):
        plan = build_plan()
        self.assertEqual(plan['tool_policies']['memory_recall'], 'read_only')
        self.assertEqual(len(plan['policy_snapshot_sha256']), 64)
        self.assertEqual(len(plan['policy_sources']), 2)
