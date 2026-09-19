import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PROTOCOL,
  classify,
  detachReason,
  errorFrame,
  eventFrame,
  grantFrame,
  helloFrame,
  resultFrame,
  revokeFrame,
} from './protocol.js';

test('hello carries the one protocol number this extension speaks', () => {
  assert.deepEqual(helloFrame('1.0.0'), {
    type: 'hello',
    protocol: PROTOCOL,
    browser: 'chromium',
    extension_version: '1.0.0',
  });
});

test('an ack for another protocol is invalid, never assumed compatible', () => {
  assert.deepEqual(classify({ type: 'hello_ack', protocol: PROTOCOL }), { kind: 'hello_ack' });
  assert.deepEqual(classify({ type: 'hello_ack', protocol: 2 }), {
    kind: 'invalid',
    reason: 'unsupported_protocol',
  });
});

test('a command outside the allowed domains is refused on this side too', () => {
  const allowed = classify({ type: 'cdp', id: 1, tab_id: 7, method: 'Page.navigate' });
  assert.equal(allowed.kind, 'cdp');
  assert.equal(allowed.method, 'Page.navigate');
  assert.deepEqual(allowed.params, {});

  for (const method of ['Browser.setDownloadBehavior', 'Target.createTarget', 'Network.getAllCookies']) {
    assert.deepEqual(classify({ type: 'cdp', id: 1, tab_id: 7, method }), {
      kind: 'invalid',
      reason: 'method_not_allowed',
      id: 1,
    });
  }
});

// The refusal carries the id so the daemon's caller is answered instead of
// sitting out its whole timeout for a verdict reached instantly.
test('a refused method keeps its id so the caller can be answered', () => {
  const refused = classify({ type: 'cdp', id: 42, tab_id: 7, method: 'Target.createTarget' });
  assert.equal(refused.id, 42);
  assert.deepEqual(errorFrame(refused.id, refused.reason), {
    type: 'cdp_error',
    id: 42,
    message: 'method_not_allowed',
  });
});

test('a command with no usable id or tab is invalid', () => {
  assert.deepEqual(classify({ type: 'cdp', id: '1', tab_id: 7, method: 'Page.navigate' }), {
    kind: 'invalid',
    reason: 'bad_id',
  });
  assert.deepEqual(classify({ type: 'cdp', id: 1, method: 'Page.navigate' }), {
    kind: 'invalid',
    reason: 'bad_id',
  });
});

test('an unknown frame type is named, not guessed at', () => {
  assert.deepEqual(classify({ type: 'evaluate_everything' }), {
    kind: 'invalid',
    reason: 'unknown_type',
  });
  assert.deepEqual(classify(null), { kind: 'invalid', reason: 'not_an_object' });
  assert.deepEqual(classify('cdp'), { kind: 'invalid', reason: 'not_an_object' });
});

test('release names the tab it releases', () => {
  assert.deepEqual(classify({ type: 'release', tab_id: 7 }), { kind: 'release', tabId: 7 });
  assert.deepEqual(classify({ type: 'release' }), { kind: 'invalid', reason: 'bad_tab_id' });
});

test("Chrome's detach reasons keep their distinct meanings", () => {
  assert.equal(detachReason('target_closed'), 'tab_closed');
  assert.equal(detachReason('replaced_with_devtools'), 'devtools_opened');
  assert.equal(detachReason('canceled_by_user'), 'debugger_detached');
  assert.equal(detachReason('something_new'), 'user');
});

test('outbound frames carry the fields the daemon matches on', () => {
  assert.deepEqual(grantFrame(7, 'https://example.com', 'Example'), {
    type: 'grant',
    tab_id: 7,
    url: 'https://example.com',
    title: 'Example',
  });
  assert.deepEqual(grantFrame(7, undefined, undefined), {
    type: 'grant',
    tab_id: 7,
    url: '',
    title: '',
  });
  assert.deepEqual(revokeFrame(7, 'tab_closed'), { type: 'revoke', tab_id: 7, reason: 'tab_closed' });
  assert.deepEqual(resultFrame(3, { ok: true }), { type: 'cdp_result', id: 3, result: { ok: true } });
  assert.deepEqual(resultFrame(3, undefined), { type: 'cdp_result', id: 3, result: null });
  assert.deepEqual(errorFrame(3, new Error('boom')), { type: 'cdp_error', id: 3, message: 'Error: boom' });
  assert.deepEqual(eventFrame(7, 'Page.loadEventFired', undefined), {
    type: 'event',
    tab_id: 7,
    method: 'Page.loadEventFired',
    params: {},
  });
});
