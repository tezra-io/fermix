#!/usr/bin/env perl
# Test-only fake of `fermix-meetbot signin`. Emits the NDJSON status lines the
# real sidecar writes and exits with a chosen code, so `Meetings.SignIn` can be
# driven without launching a real browser. The mode is the first argument
# (SignIn's `args:` seam supplies it): ok | cancelled | timeout | error.
use strict;
use warnings;
$| = 1;

my $mode = $ARGV[0] // 'ok';

print qq({"event":"signin_state","state":"launching"}\n);
print qq({"event":"signin_state","state":"awaiting_signin"}\n);

if ($mode eq 'ok') {
    print qq({"event":"signin_state","state":"signed_in"}\n);
    print qq({"event":"signin_result","status":"ok"}\n);
    exit 0;
} elsif ($mode eq 'cancelled') {
    print qq({"event":"signin_result","status":"cancelled"}\n);
    exit 2;
} elsif ($mode eq 'timeout') {
    print qq({"event":"signin_result","status":"timeout"}\n);
    exit 3;
} else {
    print qq({"event":"signin_result","status":"error"}\n);
    exit 1;
}
