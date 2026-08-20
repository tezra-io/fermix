#!/usr/bin/env perl
# Test-only fake of `fermix-meetbot install-browser`. Emits the NDJSON status
# lines the real sidecar writes and exits with a chosen code, so
# `Meetings.BrowserInstall` can be driven without a real Chromium download. The
# mode is the first argument (BrowserInstall's `args:` seam supplies it):
# ok | already | error.
use strict;
use warnings;
$| = 1;

my $mode = $ARGV[0] // 'ok';

print qq({"event":"browser_state","state":"checking"}\n);

if ($mode eq 'ok') {
    print qq({"event":"browser_state","state":"downloading"}\n);
    print qq({"event":"browser_state","state":"installed"}\n);
    print qq({"event":"browser_result","status":"ok"}\n);
    exit 0;
} elsif ($mode eq 'already') {
    print qq({"event":"browser_result","status":"ok","already":true}\n);
    exit 0;
} else {
    print qq({"event":"browser_result","status":"error"}\n);
    exit 1;
}
