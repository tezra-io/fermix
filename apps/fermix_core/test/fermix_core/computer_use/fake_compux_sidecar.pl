#!/usr/bin/env perl
# Test-only fake compux sidecar for the fermix PortDriver adapter. Autoflush so a
# one-line reply reaches the Port immediately. FAKE_PROTO overrides the reported
# protocol_version (to exercise the handshake-mismatch refusal).
use strict;
use warnings;
$| = 1;

my $proto = $ENV{FAKE_PROTO} // 5;

while (my $line = <STDIN>) {
    if ($line =~ /hello/) {
        print qq({"ok":true,"protocol_version":$proto,"compux_version":"0.0.0-fake","actions":[]}\n);
    }
    elsif ($line =~ /hang/) {
        sleep 10;
    }
    else {
        print qq({"ok":true,"pong":true}\n);
    }
}
