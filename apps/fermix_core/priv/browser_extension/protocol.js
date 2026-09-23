// The parts of the bridge protocol with no browser in them: what a frame from
// the daemon is, what Chrome's detach reasons are called on the wire, and the
// frames this extension sends. Kept separate from background.js so `node --test`
// can drive them without a browser.

export const PROTOCOL = 1;

// The domains the daemon is allowed to send. The daemon refuses anything else
// before it transmits; this is the same list on the near side, so a frame that
// should never have arrived is refused rather than handed to chrome.debugger.
const ALLOWED_DOMAINS = ['Page', 'Runtime', 'DOM', 'Input', 'Accessibility'];

export function helloFrame(version) {
  return { type: 'hello', protocol: PROTOCOL, browser: 'chromium', extension_version: version };
}

export function grantFrame(tabId, url, title) {
  return { type: 'grant', tab_id: tabId, url: url ?? '', title: title ?? '' };
}

export function revokeFrame(tabId, reason) {
  return { type: 'revoke', tab_id: tabId, reason };
}

export function resultFrame(id, result) {
  return { type: 'cdp_result', id, result: result ?? null };
}

export function errorFrame(id, message) {
  return { type: 'cdp_error', id, message: String(message) };
}

export function eventFrame(tabId, method, params) {
  return { type: 'event', tab_id: tabId, method, params: params ?? {} };
}

// One shape in, one verdict out. Every unknown or malformed frame is `invalid`
// with a reason — never a guess at what the daemon might have meant.
export function classify(message) {
  if (message === null || typeof message !== 'object') {
    return { kind: 'invalid', reason: 'not_an_object' };
  }
  switch (message.type) {
    case 'hello_ack':
      return message.protocol === PROTOCOL
        ? { kind: 'hello_ack' }
        : { kind: 'invalid', reason: 'unsupported_protocol' };
    case 'refused':
      return { kind: 'refused', reason: String(message.reason ?? 'unknown') };
    case 'cdp':
      return classifyCommand(message);
    case 'release':
      return Number.isInteger(message.tab_id)
        ? { kind: 'release', tabId: message.tab_id }
        : { kind: 'invalid', reason: 'bad_tab_id' };
    default:
      return { kind: 'invalid', reason: 'unknown_type' };
  }
}

function classifyCommand(message) {
  if (!Number.isInteger(message.id) || !Number.isInteger(message.tab_id)) {
    return { kind: 'invalid', reason: 'bad_id' };
  }
  // The id travels with the refusal: a command this side will not run still has
  // a caller on the other end of it, and a reply it never gets is a caller
  // sitting out its whole timeout for an answer that was decided instantly.
  if (typeof message.method !== 'string' || !allowedMethod(message.method)) {
    return { kind: 'invalid', reason: 'method_not_allowed', id: message.id };
  }
  return {
    kind: 'cdp',
    id: message.id,
    tabId: message.tab_id,
    method: message.method,
    params: message.params ?? {},
  };
}

function allowedMethod(method) {
  const domain = method.split('.')[0];
  return method.includes('.') && ALLOWED_DOMAINS.includes(domain);
}

// Chrome's own words for why a debugger went away, in the daemon's vocabulary.
// The daemon turns each of these into a different sentence for the person, so
// collapsing them would lose the one fact that says what to do next.
export function detachReason(chromeReason) {
  switch (chromeReason) {
    case 'target_closed':
      return 'tab_closed';
    case 'replaced_with_devtools':
      return 'devtools_opened';
    case 'canceled_by_user':
      return 'debugger_detached';
    default:
      return 'user';
  }
}
