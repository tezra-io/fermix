import unittest
from unittest.mock import patch

from audit_runtime import AuditRuntime


class RuntimeTest(unittest.TestCase):
    def test_names_and_network_are_run_scoped(self):
        a = AuditRuntime('a' * 32, 'image')
        b = AuditRuntime('b' * 32, 'image')
        self.assertNotEqual(a.network, b.network)
        self.assertNotEqual(a.target, b.target)
        with self.assertRaises(ValueError):
            AuditRuntime('../host', 'image')

    def test_start_is_internal_with_only_owned_home_mount(self):
        runtime = AuditRuntime('a' * 32, 'image')
        import json
        labels = json.dumps({'fermix.audit.run': runtime.run_id, 'fermix.audit.owner': runtime.owner})
        with patch('audit_runtime.run', side_effect=['', labels, '', '']) as call:
            runtime.start()
        calls = [c.args[0] for c in call.call_args_list]
        self.assertIn('--internal', calls[2])
        self.assertIn(runtime.volume, ' '.join(calls[3]))
        self.assertIn('no-new-privileges', calls[3])

    def test_ask_keeps_session_and_uses_only_selected_container(self):
        runtime = AuditRuntime('a' * 32, 'image')
        with patch.object(runtime, '_client') as call:
            runtime.ask('hello', 'session-1', 10)
        self.assertIn('session-1', call.call_args.args[0])
        self.assertIn('hello', call.call_args.args[0])

class CleanupTest(unittest.TestCase):
    def test_cleanup_attempts_all_resources_after_failure(self):
        runtime = AuditRuntime('c' * 32, 'image')
        with patch.object(runtime, '_remove_owned', side_effect=[RuntimeError('failed'), None, None, None, None]) as call, self.assertRaises(ExceptionGroup):
            runtime.cleanup()
        self.assertEqual(call.call_count, 5)
        self.assertEqual(call.call_args.args, ('volume', runtime.volume))

    def test_cleanup_refuses_foreign_resource(self):
        runtime = AuditRuntime('c' * 32, 'image')
        with patch('audit_runtime.run', return_value='{}') as call, self.assertRaises(ExceptionGroup):
            runtime.cleanup()
        self.assertFalse(any('rm' in c.args[0] for c in call.call_args_list))

class ProfileTest(unittest.TestCase):
    def test_derived_profile_has_exactly_one_additional_rule(self):
        import json
        from pathlib import Path
        root = Path(__file__).resolve().parents[1] / 'audit/docker'
        base = json.loads((root / 'seccomp_profile.json').read_text())
        derived = json.loads((root / 'seccomp_audit.json').read_text())
        rule = derived['syscalls'].pop()
        self.assertEqual(rule, {'names': ['chroot'], 'action': 'SCMP_ACT_ALLOW', 'args': []})
        self.assertEqual(derived, base)

class TraceTest(unittest.TestCase):
    def test_collect_rejects_untrusted_paths(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as folder:
            runtime = AuditRuntime('e' * 32, 'image')
            with patch('audit_runtime.run', return_value='{"../escape.jsonl": "e30K"}'), self.assertRaises(ValueError):
                runtime.collect_traces(folder, redact_values=['dummy'])

class ContextTest(unittest.TestCase):
    def test_cleanup_failure_keeps_episode_error(self):
        runtime = AuditRuntime('f' * 32, 'image')
        with patch.object(runtime, 'start'), patch.object(runtime, 'cleanup', side_effect=RuntimeError('cleanup')), self.assertRaises(BaseExceptionGroup) as caught, runtime:
            raise ValueError('episode')
        self.assertEqual({str(e) for e in caught.exception.exceptions}, {'episode', 'cleanup'})

class IdempotenceTest(unittest.TestCase):
    def test_absent_resources_are_safe_to_clean_again(self):
        import subprocess
        runtime = AuditRuntime('f' * 32, 'image')
        absent_container = subprocess.CalledProcessError(1, 'docker', stderr='Error: No such container')
        absent_network = subprocess.CalledProcessError(1, 'docker', stderr='Error: network x not found')
        with patch('audit_runtime.run', side_effect=[absent_container, absent_container, absent_container, absent_network, absent_network]):
            runtime.cleanup()

class IngressTest(unittest.TestCase):
    def test_trusted_client_has_only_owned_home_and_no_network(self):
        runtime = AuditRuntime('e' * 32, 'image')
        with patch('audit_runtime.run', return_value='{}') as call, patch.object(runtime, '_remove_owned'):
            runtime._client(['python3', '-'], input='pass')
        args = call.call_args.args[0]
        self.assertIn('none', args)
        self.assertIn('container:' + runtime.target, args)
        self.assertIn(runtime.volume, ' '.join(args))
        self.assertNotIn('no-new-privileges', ' '.join(args))

class ClientFailureTest(unittest.TestCase):
    def test_timeout_and_cleanup_failures_are_both_reported(self):
        import subprocess
        runtime = AuditRuntime('d' * 32, 'image')
        with patch('audit_runtime.run', side_effect=subprocess.TimeoutExpired('docker', 1)), patch.object(runtime, '_remove_owned', side_effect=RuntimeError('cleanup')), self.assertRaises(BaseExceptionGroup) as caught:
            runtime._client(['python3', '-'], timeout=1)
        self.assertEqual(len(caught.exception.exceptions), 2)

class VolumeOwnershipTest(unittest.TestCase):
    def test_existing_foreign_volume_is_rejected_before_target_start(self):
        runtime = AuditRuntime('d' * 32, 'image')
        with patch('audit_runtime.run', side_effect=['volume', '{}']) as call, patch.object(runtime, 'cleanup'), self.assertRaises(RuntimeError):
            runtime.start()
        self.assertEqual(call.call_count, 2)

class BootstrapTest(unittest.TestCase):
    def test_returns_nonsecret_config_hash(self):
        runtime = AuditRuntime('d' * 32, 'image')
        with patch('audit_runtime.run', side_effect=['{"config_sha256":"' + 'a' * 64 + '"}', '']), patch.object(runtime, '_remove_owned'):
            self.assertEqual(runtime.bootstrap('model', 'http://proxy:8080/v1', 'dummy')['config_sha256'], 'a' * 64)

class BuildSpaceTest(unittest.TestCase):
    def test_low_space_fails_before_git_or_context_work(self):
        from collections import namedtuple

        from audit_runtime import build_image
        usage = namedtuple('usage', 'total used free')(10, 9, 1)
        with patch('audit_runtime.shutil.disk_usage', return_value=usage), patch('audit_runtime.run') as call, self.assertRaisesRegex(RuntimeError, 'required.*available'):
            build_image('.', 'image')
        call.assert_not_called()

class OutputLimitTest(unittest.TestCase):
    def test_oversized_command_output_is_terminated(self):
        import sys

        from audit_runtime import run
        with self.assertRaisesRegex(RuntimeError, 'output limit'):
            run([sys.executable, '-c', "print('x' * 1000000)"], max_output=4096)

class ClientConcurrencyTest(unittest.TestCase):
    def test_concurrent_client_cannot_remove_active_client(self):
        runtime = AuditRuntime('c' * 32, 'image')
        runtime._client_lock.acquire()
        try:
            with patch('audit_runtime.run') as call, self.assertRaises(TimeoutError):
                runtime._client(['python3', '-'], timeout=0.01)
            call.assert_not_called()
        finally:
            runtime._client_lock.release()

class TraceRedactionTest(unittest.TestCase):
    def test_secret_is_redacted_before_evidence_write(self):
        import base64
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('e' * 32, 'image')
        payload = base64.b64encode(b'{"message":"sensitive-token"}\n').decode()
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=json.dumps({'2026-11-05/agent_event.jsonl': payload})):
            dest = runtime.collect_traces(folder, redact_values=['sensitive-token'])
            self.assertNotIn('sensitive-token', (dest / '2026-11-05/agent_event.jsonl').read_text())

class ObserverCollectionTest(unittest.TestCase):
    def test_missing_sequence_rejected_before_evidence_write(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        records = [{'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 3, 'kind': 'event'}]
        logs = ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in records)
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(logs + 'FERMIX_AUDIT_DAEMON_EXIT 0\n', '')), patch.object(runtime, '_assert_stopped'), self.assertRaises(ValueError):
            runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 2}, redact_values=['dummy'])

class BrowserConfigTest(unittest.TestCase):
    def test_world_only_is_preapproved(self):
        import importlib.util
        import tomllib
        from pathlib import Path
        path = Path(__file__).resolve().parents[1] / 'audit/docker/audit_bootstrap.py'
        spec = importlib.util.spec_from_file_location('audit_bootstrap', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        config = tomllib.loads(module.render_config('model', 'http://proxy:8080/v1'))
        self.assertEqual(config['fermix_core']['browser']['allowed_hosts'], ['world'])
        self.assertEqual(set(config['fermix_core']), {'providers', 'browser'})
        self.assertEqual(config['fermix_core']['providers']['anthropic']['default_model'], 'model')
        self.assertEqual(config['fermix_core']['providers']['anthropic']['base_url'], 'http://proxy:8080/v1')
        self.assertNotIn('sandbox', config)

class BootstrapHomeTest(unittest.TestCase):
    # M97 §4: the sandbox is this computer's own setting, which the engine reads
    # from machine.toml beside config.toml and never from config.toml.
    def test_sandbox_is_written_to_the_machine_file_only(self):
        import hashlib
        import importlib.util
        import io
        import json
        import stat
        import tomllib
        from contextlib import redirect_stdout
        from pathlib import Path
        from tempfile import TemporaryDirectory
        path = Path(__file__).resolve().parents[1] / 'audit/docker/audit_bootstrap.py'
        spec = importlib.util.spec_from_file_location('audit_bootstrap', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        request = json.dumps({'model': 'model', 'proxy_url': 'http://proxy:8080/v1', 'token': 'dummy'})
        with TemporaryDirectory() as folder, patch.object(module, 'Path', return_value=Path(folder)), \
                patch('sys.stdin', io.StringIO(request)), redirect_stdout(io.StringIO()) as out:
            module.main()
            home = Path(folder)
            config = (home / 'config.toml').read_bytes()
            machine = (home / 'machine.toml').read_bytes()
            machine_mode = stat.S_IMODE((home / 'machine.toml').stat().st_mode)
        self.assertNotIn('sandbox', tomllib.loads(config.decode()))
        self.assertEqual(tomllib.loads(machine.decode()), {'sandbox': {
            'mode': 'strict', 'workspace_root': '/home/audit/fermix/workspace',
            'allowed_roots': ['/home/audit/fermix/skills']}})
        self.assertEqual(machine_mode, 0o600)
        self.assertEqual(json.loads(out.getvalue()), {
            'config_sha256': hashlib.sha256(config).hexdigest(),
            'machine_sha256': hashlib.sha256(machine).hexdigest()})

class ObserverValidationTest(unittest.TestCase):
    def test_secret_is_redacted_from_normalized_observer_record(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        records = [{'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 2, 'kind': 'event',
                    'type': 'agent_event', 'agent': 'main', 'data': {'output': 'sensitive-token'}},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 3, 'kind': 'checkpoint', 'nonce': 'a' * 16}]
        logs = ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in records)
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(logs + 'FERMIX_AUDIT_DAEMON_EXIT 0\n', '')), patch.object(runtime, '_assert_stopped'):
            result = runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 3}, redact_values=['sensitive-token'])
            self.assertNotIn('sensitive-token', result.read_text())

class DuplicateRunTest(unittest.TestCase):
    def test_same_run_different_owner_cannot_remove_resources(self):
        import json
        first = AuditRuntime('a' * 32, 'image')
        second = AuditRuntime(first.run_id, 'image')
        labels = json.dumps({'fermix.audit.run': first.run_id, 'fermix.audit.owner': first.owner})
        with patch('audit_runtime.run', return_value=labels) as call, self.assertRaises(ExceptionGroup):
            second.cleanup()
        self.assertFalse(any('rm' in c.args[0] for c in call.call_args_list))

class ObserverBarrierTest(unittest.TestCase):
    def test_missing_checkpoint_fails_closed(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        start = {'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'}
        logs = 'FERMIX_AUDIT_TRACE ' + json.dumps(start) + '\n'
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(logs + 'FERMIX_AUDIT_DAEMON_EXIT 0\n', '')), patch.object(runtime, '_assert_stopped'), self.assertRaises(ValueError):
            runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 2}, redact_values=['dummy'])

    def test_checkpoint_response_must_match_request(self):
        runtime = AuditRuntime('d' * 32, 'image')
        with patch.object(runtime, '_client', return_value='{"nonce":"wrong","seq":2}'), self.assertRaises(ValueError):
            runtime.checkpoint('a' * 16)

class TargetStopTest(unittest.TestCase):
    def test_stop_refuses_foreign_container(self):
        runtime = AuditRuntime('a' * 32, 'image')
        with patch('audit_runtime.run', return_value='{}') as call, self.assertRaises(RuntimeError):
            runtime.stop()
        self.assertFalse(any('stop' in item.args[0] for item in call.call_args_list))

class VersionTest(unittest.TestCase):
    def test_versions_uses_selected_target(self):
        runtime = AuditRuntime('a' * 32, 'image')
        with patch('audit_runtime.run', side_effect=['Chromium 123\n', 'Erlang OTP 28\nElixir 1.19\n']) as call:
            result = runtime.versions()
        self.assertEqual(result['chromium'], 'Chromium 123')
        self.assertTrue(all(runtime.target in item.args[0] for item in call.call_args_list))

class ObserverShapeTest(unittest.TestCase):
    def test_duplicate_start_is_rejected(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        records = [{'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 2, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 3, 'kind': 'checkpoint', 'nonce': 'a' * 16}]
        logs = ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in records)
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(logs + 'FERMIX_AUDIT_DAEMON_EXIT 0\n', '')), patch.object(runtime, '_assert_stopped'), self.assertRaises(ValueError):
            runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 3}, redact_values=['dummy'])

class PostCheckpointTest(unittest.TestCase):
    def test_records_after_checkpoint_are_retained(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        records = [{'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 2, 'kind': 'checkpoint', 'nonce': 'a' * 16},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 3, 'kind': 'event',
                    'type': 'agent_event', 'agent': 'main', 'data': {'value': 'after'}}]
        logs = ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in records)
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(logs + 'FERMIX_AUDIT_DAEMON_EXIT 0\n', '')), patch.object(runtime, '_assert_stopped'):
            output = runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 2}, redact_values=['dummy'])
            self.assertEqual(len(output.read_text().splitlines()), 3)

class ObserverFailureTest(unittest.TestCase):
    def test_stderr_failure_after_checkpoint_invalidates(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('d' * 32, 'image')
        records = [{'version': 1, 'run_id': runtime.run_id, 'seq': 1, 'kind': 'start'},
                   {'version': 1, 'run_id': runtime.run_id, 'seq': 2, 'kind': 'checkpoint', 'nonce': 'a' * 16}]
        stdout = ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in records)
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=(stdout, 'FERMIX_AUDIT_OBSERVER_FAILURE overflow\n')), patch.object(runtime, '_assert_stopped'), self.assertRaises(ValueError):
            runtime.collect_observer(folder, checkpoint={'nonce': 'a' * 16, 'seq': 2}, redact_values=['dummy'])

class ShutdownFailureTest(unittest.TestCase):
    def test_shutdown_failure_does_not_claim_graceful_stop(self):
        import json
        runtime = AuditRuntime('a' * 32, 'image')
        labels = json.dumps({'fermix.audit.run': runtime.run_id, 'fermix.audit.owner': runtime.owner})
        with patch('audit_runtime.run', side_effect=[labels, '']) as call, patch.object(runtime, '_client', side_effect=RuntimeError('daemon failed')), self.assertRaises(RuntimeError):
            runtime.stop()
        self.assertFalse(any('stop' in item.args[0] for item in call.call_args_list))

class ForegroundDaemonTest(unittest.TestCase):
    def test_start_creates_but_does_not_start_target(self):
        import json
        runtime = AuditRuntime('a' * 32, 'image')
        labels = json.dumps({'fermix.audit.run': runtime.run_id, 'fermix.audit.owner': runtime.owner})
        with patch('audit_runtime.run', side_effect=['', labels, '', '']) as call:
            runtime.start()
        commands = [item.args[0] for item in call.call_args_list]
        self.assertEqual(commands[-1][:2], ['docker', 'create'])
        self.assertIn('/src/audit_foreground.py', commands[-1])
        self.assertNotIn('sleep', commands[-1])

    def test_nonzero_daemon_exit_is_rejected(self):
        runtime = AuditRuntime('a' * 32, 'image')
        with patch('audit_runtime.run', return_value='{"Status":"exited","OOMKilled":false,"ExitCode":70,"Error":""}'), self.assertRaises(ValueError):
            runtime._assert_stopped()

class IsolatedGatewayTest(unittest.TestCase):
    def test_target_network_requires_isolated_gateway(self):
        import json
        runtime = AuditRuntime('a' * 32, 'image')
        labels = json.dumps({'fermix.audit.run': runtime.run_id, 'fermix.audit.owner': runtime.owner})
        with patch('audit_runtime.run', side_effect=['', labels, '', '']) as call:
            runtime.start()
        network = call.call_args_list[2].args[0]
        self.assertIn('--internal', network)
        self.assertIn('com.docker.network.bridge.gateway_mode_ipv4=isolated', network)


def review_logs(*rows, run_id='a' * 32):
    import json
    numbered = [{'run_id': run_id, **row, 'seq': index} for index, row in enumerate(rows, 1)]
    return ''.join('FERMIX_AUDIT_TRACE ' + json.dumps(row) + '\n' for row in numbered) + 'daemon log line\n'


def review_row(chat_id, event='memory_review', channel='cli'):
    return {'kind': 'event', 'type': 'agent_event', 'agent': 'main', 'seq': 5,
            'data': {'event': event, 'channel': channel, 'chat_id': chat_id, 'status': 'ok'}}


class MemoryReviewSettleTest(unittest.TestCase):
    def test_returns_once_this_conversation_review_closes(self):
        runtime = AuditRuntime('a' * 32, 'image')
        rows = (review_row('other-chat'), review_row('audit-chat', event='turn_complete'))
        pending = review_logs(*rows)
        closed = review_logs(*rows, review_row('audit-chat'))
        with patch('audit_runtime.run', side_effect=[pending, closed]) as call, \
             patch('audit_runtime.time.sleep'):
            runtime.wait_for_memory_review('audit-chat', 120)
        self.assertEqual(call.call_count, 2)
        self.assertEqual(call.call_args.args[0], ['docker', 'logs', runtime.target])

    def test_unclosed_review_times_out_without_waiting_on_the_clock(self):
        runtime = AuditRuntime('a' * 32, 'image')
        clock = iter(range(0, 1000, 50))
        with patch('audit_runtime.run', return_value=review_logs(review_row('other-chat'))), \
             patch('audit_runtime.time.monotonic', side_effect=lambda: next(clock)), \
             patch('audit_runtime.time.sleep'), \
             self.assertRaisesRegex(TimeoutError, 'memory review'):
            runtime.wait_for_memory_review('audit-chat', 120)

    def test_foreign_or_discontinuous_trace_lines_fail_closed(self):
        runtime = AuditRuntime('a' * 32, 'image')
        import json
        forged = review_logs(review_row('audit-chat'), run_id='b' * 32)
        gap = 'FERMIX_AUDIT_TRACE ' + json.dumps(dict(review_row('audit-chat'), run_id=runtime.run_id, seq=3)) + '\n'
        for name, logs in (('foreign run', forged), ('sequence gap', gap)):
            with self.subTest(name), patch('audit_runtime.run', return_value=logs), \
                 patch('audit_runtime.time.sleep'), self.assertRaises(ValueError):
                runtime.wait_for_memory_review('audit-chat', 120)

    def test_in_target_helpers_run_python_isolated(self):
        import json
        from tempfile import TemporaryDirectory
        runtime = AuditRuntime('a' * 32, 'image')
        with TemporaryDirectory() as folder, patch('audit_runtime.run', return_value=json.dumps({})) as call:
            runtime.collect_traces(folder, redact_values=['dummy'])
        self.assertEqual(call.call_args.args[0][-3:], ['python3', '-I', '-'])

    def test_rejects_invalid_arguments(self):
        runtime = AuditRuntime('a' * 32, 'image')
        for chat_id, timeout in (('', 120), ('audit-chat', 0), ('audit-chat', 1.5)):
            with self.subTest(chat_id=chat_id, timeout=timeout), self.assertRaises(ValueError):
                runtime.wait_for_memory_review(chat_id, timeout)


if __name__ == '__main__':
    unittest.main()

class CopiedPolicyHashTest(unittest.TestCase):
    def test_context_digest_uses_copied_bytes(self):
        import hashlib
        import tempfile
        from pathlib import Path
        from unittest.mock import patch

        from audit_runtime import _copy_build_inputs
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as target:
            root = Path(source)
            (root / 'file').write_text('before')
            def copy_then_change(path, destination):
                path.write_text('after')
                destination.write_bytes(path.read_bytes())
            digest = hashlib.sha256()
            with patch('audit_runtime.shutil.copy2', side_effect=copy_then_change):
                _copy_build_inputs(root, target, [('file', 'file')], digest)
            expected = hashlib.sha256(b'file\0' + hashlib.sha256(b'after').digest()).hexdigest()
            self.assertEqual(digest.hexdigest(), expected)

    def test_hashes_are_from_copied_files(self):
        import hashlib
        import tempfile
        from pathlib import Path

        from audit_runtime import policy_source_hashes
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in ('apps/fermix_core/lib/fermix_core/capabilities/builtin.ex',
                             'apps/fermix_core/lib/fermix_core/capabilities/capability.ex'):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('copied content')
            hashes = policy_source_hashes(root)
            self.assertEqual(set(hashes.values()), {hashlib.sha256(b'copied content').hexdigest()})
