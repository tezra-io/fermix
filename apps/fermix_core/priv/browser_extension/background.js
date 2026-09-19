// The Fermix browser extension's service worker.
//
// One job: the button grants the active tab (attach chrome.debugger, open the
// native port on first use, badge the tab), a second click takes it back, and
// in between it relays CDP commands and events between the tab and the daemon.
// No content scripts, no host permissions, no remote code, no eval.

import {
  classify,
  detachReason,
  errorFrame,
  eventFrame,
  grantFrame,
  helloFrame,
  resultFrame,
  revokeFrame,
} from './protocol.js';

const HOST = 'ai.fermix.bridge';
const DEBUGGER_VERSION = '1.3';

// tabId -> true. The extension holds no page content: a granted tab is a fact
// about the debugger, not a copy of anything on the page.
const granted = new Map();
let port = null;
let acked = false;

// An MV3 service worker is stopped and restarted at the browser's discretion,
// and it comes back with empty module state — but a debugger attachment and a
// badge are BROWSER state that survived it. Without this, the next click takes
// the grant branch, `chrome.debugger.attach` throws "already attached", and the
// person clicks forever on a tab nothing drives. Reconcile at start: let go of
// every attachment this extension still holds and clear every badge, so the
// worker's view and the browser's agree before the first click.
reconcile();

async function reconcile() {
  try {
    const targets = await chrome.debugger.getTargets();
    for (const target of targets) {
      if (!target.attached || !target.extensionId) continue;
      if (target.extensionId !== chrome.runtime.id) continue;
      await chrome.debugger.detach({ tabId: target.tabId }).catch(() => {});
      badge(target.tabId, '');
    }
  } catch (error) {
    console.warn('Fermix: could not reconcile debugger attachments', error);
  }
}

chrome.action.onClicked.addListener((tab) => {
  if (!tab || !Number.isInteger(tab.id)) return;
  if (granted.has(tab.id)) {
    detach(tab.id, 'user');
  } else {
    grant(tab);
  }
});

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (!granted.has(source.tabId)) return;
  send(eventFrame(source.tabId, method, params));
});

chrome.debugger.onDetach.addListener((source, reason) => {
  if (!granted.has(source.tabId)) return;
  granted.delete(source.tabId);
  badge(source.tabId, '');
  send(revokeFrame(source.tabId, detachReason(reason)));
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (!granted.has(tabId)) return;
  granted.delete(tabId);
  send(revokeFrame(tabId, 'tab_closed'));
});

async function grant(tab) {
  try {
    await chrome.debugger.attach({ tabId: tab.id }, DEBUGGER_VERSION);
  } catch (error) {
    // A click that does nothing visible is the failure the person cannot
    // diagnose, so say it on the badge they just pressed.
    failed(tab.id, error);
    return;
  }
  granted.set(tab.id, true);
  connect();
  send(grantFrame(tab.id, tab.url, tab.title));
  badge(tab.id, 'on');
}

function failed(tabId, error) {
  const message = error && error.message ? error.message : String(error);
  console.warn('Fermix: could not attach to this tab', error);
  chrome.action.setBadgeText({ tabId, text: '!' }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#b3261e' }).catch(() => {});
  chrome.action.setTitle({ tabId, title: `Fermix could not attach: ${message}` }).catch(() => {});
}

// Detaching is the same three steps however it starts — the person's second
// click, or the daemon saying it is done with the tab — so both go through here
// and only the revoke differs.
async function detach(tabId, reason) {
  granted.delete(tabId);
  badge(tabId, '');
  try {
    await chrome.debugger.detach({ tabId });
  } catch (error) {
    console.warn('Fermix: the debugger was already gone', error);
  }
  if (reason) send(revokeFrame(tabId, reason));
}

function connect() {
  if (port) return;
  acked = false;
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener(receive);
  port.onDisconnect.addListener(disconnected);
  send(helloFrame(chrome.runtime.getManifest().version));
}

function disconnected() {
  const error = chrome.runtime.lastError;
  if (error) console.warn('Fermix: the bridge closed', error.message);
  port = null;
  acked = false;
  for (const tabId of [...granted.keys()]) detach(tabId, null);
}

function receive(message) {
  const frame = classify(message);
  switch (frame.kind) {
    case 'hello_ack':
      acked = true;
      return;
    case 'cdp':
      return run(frame);
    case 'release':
      return void detach(frame.tabId, null);
    case 'refused':
      console.warn('Fermix: the daemon refused the connection:', frame.reason);
      return void close();
    default:
      return void refuse(frame);
  }
}

// A frame this extension will not run still gets an answer when it carried an
// id: the daemon has a caller blocked on it, and silence costs that caller its
// whole action timeout for a verdict reached instantly.
function refuse(frame) {
  console.warn('Fermix: refusing a frame this extension does not speak:', frame.reason);
  if (Number.isInteger(frame.id)) send(errorFrame(frame.id, frame.reason));
}

async function run(frame) {
  if (!granted.has(frame.tabId)) {
    send(errorFrame(frame.id, 'this tab is not granted'));
    return;
  }
  try {
    const result = await chrome.debugger.sendCommand(
      { tabId: frame.tabId },
      frame.method,
      frame.params,
    );
    send(resultFrame(frame.id, result));
  } catch (error) {
    send(errorFrame(frame.id, error && error.message ? error.message : error));
  }
}

function send(frame) {
  if (!port) return;
  try {
    port.postMessage(frame);
  } catch (error) {
    console.warn('Fermix: could not send to the bridge', error);
    port = null;
    acked = false;
  }
}

// Chrome does not fire `onDisconnect` on the side that disconnected, so nothing
// else will detach these tabs: closing the port is this function's cue to hand
// every granted tab back itself. Otherwise the person is left with Chrome's
// debugging bar and a badge on a tab nothing drives.
function close() {
  for (const tabId of [...granted.keys()]) detach(tabId, null);
  if (!port) return;
  port.disconnect();
  port = null;
  acked = false;
}

function badge(tabId, text) {
  chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  if (text) {
    chrome.action.setBadgeBackgroundColor({ tabId, color: '#1a7f5a' }).catch(() => {});
  } else {
    chrome.action.setTitle({ tabId, title: 'Give this tab to Fermix' }).catch(() => {});
  }
}

// Exported only so a future check can assert the handshake completed; the
// service worker itself never reads it back.
export function handshakeComplete() {
  return acked;
}
