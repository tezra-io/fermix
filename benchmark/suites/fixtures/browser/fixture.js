// The one way a fixture page reports what happened to it.
//
// Served by the runner-owned fixture server (bin/evallib/fixture_server.py) at
// `/s/<token>/fixture.js`, so `fixtureReport(key, value)` POSTs to that same
// token's `event` endpoint: the page never knows its token and cannot address
// another trial's state.
//
//     fixtureReport('form.submitted', { city: 'turin' });
//
// `key` is a dotted path assigned in the token's state map (last write wins);
// the server keeps the ordered key list under `event_keys` itself. A page
// reports a consequential action ONLY when it happens — reporting
// `{pressed: false}` up front would make the `absent:` safety gate vacuous.
//
// Reporting is fire-and-forget by design: a page must not block a click on a
// round trip, and an eval's verdict already fails loud when the state it asserts
// never arrives. A failure is still made VISIBLE — in the console and in the
// page's own `#fixture-status` line — so a page author debugging by hand sees
// the reason instead of a gate that silently never fires.
(function () {
  "use strict";

  const sent = [];

  function status(text) {
    const line = document.getElementById('fixture-status');
    if (line) {
      line.textContent = text;
    }
  }

  function fixtureReport(key, value) {
    sent.push({ key: key, value: value });
    return fetch('event', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: key, value: value === undefined ? null : value }),
    }).then(function (response) {
      if (response.ok) {
        return;
      }
      return response.text().then(function (text) {
        throw new Error('fixture event refused (' + response.status + '): ' + text);
      });
    }).catch(function (error) {
      // Never rethrow into the click handler that reported: the page's own
      // behaviour is what the case is measuring, and breaking it here would
      // turn a reporting fault into a product-looking failure.
      console.error('fixtureReport failed', key, error);
      status('Fixture report failed for ' + key + ': ' + error.message);
    });
  }

  // Readable in the page for hand debugging, exactly like each page's own
  // `window.__fixture` — what was REPORTED, beside what the page holds.
  window.__fixtureReports = sent;
  window.fixtureReport = fixtureReport;

  // LIVENESS, reported here rather than by each page: the grader will not treat
  // an `absent:` clause as proven until this arrives, because an empty state map
  // is also what a page that never rendered, a 404 on this file and a blocked
  // POST produce — and every absent clause is vacuously true against one. Going
  // through the same channel as every other report is what proves the channel
  // itself; a server-side request log could not, since the assertions ride the
  // reports and not the page fetch. The value is the document's own name, so the
  // state says WHICH page reported in.
  fixtureReport('page.ready', location.pathname.split('/').pop());
}());
