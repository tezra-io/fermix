import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import audit_isolation


def inspection():
    return {'Image': 'sha256:abc', 'Config': {'User': '10001', 'Labels': {'fermix.audit.run': 'run', 'fermix.audit.owner': 'owner'}},
            'Mounts': [{'Type': 'volume', 'Name': 'home', 'Destination': '/home/audit/fermix'}],
            'HostConfig': {'Privileged': False, 'NetworkMode': 'internal', 'PidMode': '',
                           'IpcMode': 'private', 'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges']},
            'NetworkSettings': {'Networks': {'internal': {'GlobalIPv6Address': ''}}}}


class InspectionTest(unittest.TestCase):
    def test_valid_target(self):
        audit_isolation.check_target(inspection(), 'sha256:abc', 'run', 'owner', 'internal', 'home')

    def test_rejects_mount_identity_and_escape(self):
        cases = []
        target = inspection(); target['Mounts'].append({'Type': 'bind', 'Source': '/var/run/docker.sock', 'Destination': '/sock'}); cases.append(target)
        target = inspection(); target['Image'] = 'sha256:foreign'; cases.append(target)
        target = inspection(); target['HostConfig']['Privileged'] = True; cases.append(target)
        target = inspection(); target['Config']['User'] = 'root'; cases.append(target)
        target = inspection(); target['HostConfig']['SecurityOpt'].append('seccomp=unconfined'); cases.append(target)
        target = inspection(); target['NetworkSettings']['Networks']['internal']['GlobalIPv6Address'] = '::1'; cases.append(target)
        target = inspection(); target['NetworkSettings']['Networks']['egress'] = {}; cases.append(target)
        for target in cases:
            with self.subTest(target=target), self.assertRaises(ValueError):
                audit_isolation.check_target(target, 'sha256:abc', 'run', 'owner', 'internal', 'home')

    def test_failed_egress_probe_cleans_owned_canary(self):
        runtime = SimpleNamespace(target='target', run_id='run', owner='owner', network='internal', volume='home')
        services = SimpleNamespace(proxy='proxy', world='world', egress='egress')
        target = inspection()
        proxy = {'Config': target['Config'], 'NetworkSettings': {'Networks': {'internal': {}, 'egress': {}}}}
        world = {'Config': target['Config'], 'NetworkSettings': {'Networks': {'internal': {}}}}
        networks = [{'Labels': target['Config']['Labels'], 'Internal': value, 'EnableIPv6': False, 'Options': {'com.docker.network.bridge.gateway_mode_ipv4': 'isolated'}} for value in (True, False)]
        server, thread, timer = Mock(), Mock(), Mock()
        with (patch.object(audit_isolation, 'inspect', side_effect=[target, proxy, world, *networks]),
              patch.object(audit_isolation, 'host_canary', return_value=(server, thread, timer)),
              patch.object(audit_isolation, 'start_canary', return_value='172.22.0.2'),
              patch.object(audit_isolation, 'wait_ready', side_effect=ValueError('unreachable')),
              patch.object(audit_isolation, 'close_host') as close_host,
              patch.object(audit_isolation, 'cleanup_canary') as cleanup,
              self.assertRaises(ValueError)):
            audit_isolation.qualify(runtime, services, 'sha256:abc')
        close_host.assert_called_once_with(server, thread, timer)
        cleanup.assert_called_once_with(runtime, 'internal-canary')

    def test_cleanup_preserves_original_failure(self):
        runtime = SimpleNamespace(target='target', run_id='run', owner='owner', network='internal', volume='home')
        services = SimpleNamespace(proxy='proxy', world='world', egress='egress')
        target = inspection()
        proxy = {'Config': target['Config'], 'NetworkSettings': {'Networks': {'internal': {}, 'egress': {}}}}
        world = {'Config': target['Config'], 'NetworkSettings': {'Networks': {'internal': {}}}}
        networks = [{'Labels': target['Config']['Labels'], 'Internal': value, 'EnableIPv6': False, 'Options': {'com.docker.network.bridge.gateway_mode_ipv4': 'isolated'}}
                    for value in (True, False)]
        with (patch.object(audit_isolation, 'inspect', side_effect=[target, proxy, world, *networks]),
              patch.object(audit_isolation, 'host_canary', return_value=(Mock(), Mock(), Mock())),
              patch.object(audit_isolation, 'start_canary', return_value='172.22.0.2'),
              patch.object(audit_isolation, 'wait_ready', side_effect=ValueError('probe failure')),
              patch.object(audit_isolation, 'close_host', side_effect=RuntimeError('cleanup failure')),
              patch.object(audit_isolation, 'cleanup_canary'),
              self.assertRaises(ExceptionGroup) as caught):
            audit_isolation.qualify(runtime, services, 'sha256:abc')
        self.assertEqual(str(caught.exception.exceptions[0]), 'probe failure')
        self.assertIsInstance(caught.exception.exceptions[1], ExceptionGroup)

    def test_gateway_mode_must_be_isolated(self):
        egress = {'Internal': False, 'EnableIPv6': False}
        for options in ({}, {'com.docker.network.bridge.gateway_mode_ipv4': 'nat'}):
            internal = {'Internal': True, 'EnableIPv6': False, 'Options': options}
            with self.assertRaises(ValueError):
                audit_isolation.check_networks(internal, egress)

    def test_ipv6_network_rejected(self):
        with self.assertRaises(ValueError):
            audit_isolation.check_networks({'Internal': True, 'EnableIPv6': True},
                                           {'Internal': False, 'EnableIPv6': False})

    def test_probe_requires_explicit_result(self):
        self.assertTrue(audit_isolation.probe_result('{"ok": true}', True))
        self.assertTrue(audit_isolation.probe_result('{"ok": false}', False))
        for output in ('', '{}', '{"ok": true}'):
            with self.assertRaises(ValueError):
                audit_isolation.probe_result(output, False)


if __name__ == '__main__':
    unittest.main()
