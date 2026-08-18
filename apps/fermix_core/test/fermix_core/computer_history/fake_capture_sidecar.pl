#!/usr/bin/env perl
# Test-only fake compux sidecar in CAPTURE mode (MILESTONE_32 §8.4a). Unlike the
# computer-use fake (one request → one response), capture is an unsolicited push:
# on an `observe_start` request it emits a type-discriminated ack frame, then
# streams the newline-delimited event frames named by FAKE_EVENTS_FILE. Autoflush
# so frames reach the Port immediately. Env knobs (passed via the Port `env:`):
#   FAKE_PROTO        reported protocol_version in the ack (default 6)
#   FAKE_ACK_OK       "false" to refuse the start (ack ok:false)
#   FAKE_PRE_ACK_FILE NDJSON frames to stream BEFORE the ack (buffer-before-handshake)
#   FAKE_EVENTS_FILE  NDJSON frames to stream AFTER a successful ack
#   FAKE_EXIT_AFTER   "1" to exit once the post-ack stream is drained (sidecar-exit gap)
use strict;
use warnings;
$| = 1;

my $proto  = $ENV{FAKE_PROTO} // 6;
my $ack_ok = (($ENV{FAKE_ACK_OK} // "true") eq "false") ? "false" : "true";

sub stream_file {
    my ($path) = @_;
    return unless defined $path && -f $path;
    open(my $fh, "<", $path) or return;
    while (my $l = <$fh>) {
        chomp $l;
        next if $l eq "";
        print "$l\n";
    }
    close($fh);
}

while (my $line = <STDIN>) {
    if ($line =~ /observe_start/) {
        # Die before acking — models a sidecar that crashes on startup and never
        # completes a handshake, so the capturer's restart budget is not reset.
        exit(1) if ($ENV{FAKE_EXIT_BEFORE_ACK} // "") eq "1";

        # Ack + stream + exit on the FIRST incarnation, then die before acking on
        # every later one — a sidecar that ran and produced verified events, then
        # went bad, so the retry budget exhausts WITH verified content buffered.
        # A sentinel file carries the "already acked" state across restarts (each
        # retry is a fresh process, so in-process state cannot).
        if (($ENV{FAKE_ACK_ONCE} // "") eq "1") {
            my $sentinel = $ENV{FAKE_STATE_FILE};
            exit(1) if defined $sentinel && -f $sentinel;
            if (defined $sentinel and open(my $m, ">", $sentinel)) { close($m); }
            print qq({"type":"ack","action":"observe_start","ok":true,"protocol_version":$proto}\n);
            stream_file($ENV{FAKE_EVENTS_FILE});
            exit(0);
        }

        stream_file($ENV{FAKE_PRE_ACK_FILE});
        print qq({"type":"ack","action":"observe_start","ok":$ack_ok,"protocol_version":$proto}\n);

        if ($ack_ok eq "true") {
            stream_file($ENV{FAKE_EVENTS_FILE});
            exit(0) if ($ENV{FAKE_EXIT_AFTER} // "") eq "1";
        }
    }
    elsif ($line =~ /observe_stop/) {
        print qq({"type":"ack","action":"observe_stop","ok":true,"protocol_version":$proto}\n);
    }
}
