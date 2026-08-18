#!/usr/bin/env perl
# Test-only fake meetbot sidecar. Speaks the packet-4 wire of priv/meetbot/PROTOCOL.md
# so Sidecar.Port can be driven against a real OS process without a browser.
#
# Env knobs:
#   FAKE_PROTO     hello protocol_version (default 1; set 2 to exercise the mismatch refusal)
#   FAKE_SCENARIO  happy | denied | signin_required | crash_after_admit | hang_hello | wedge
#
# Every scenario exits on stdin EOF (the daemon's teardown contract): the read
# loop is the only blocking point, so EOF ends the process immediately.
use strict;
use warnings;

binmode(STDIN);
binmode(STDOUT);
$| = 1;

my $proto    = $ENV{FAKE_PROTO} // 1;
my $scenario = $ENV{FAKE_SCENARIO} // 'happy';

my $tone;

sub tone {
    unless (defined $tone) {
        $tone = "";
        # 1600 samples = 100 ms of a 440 Hz sine at 16 kHz s16le.
        for my $i (0 .. 1599) {
            $tone .= pack("s<", int(8000 * sin(2 * 3.14159265358979 * 440 * $i / 16000)));
        }
    }
    return $tone;
}

sub send_frame {
    my ($type, $payload) = @_;
    print pack("N", 1 + length($payload)) . chr($type) . $payload;
}

sub control { send_frame(0x01, $_[0]); }
sub audio   { send_frame(0x02, tone()); }

sub read_exact {
    my ($want) = @_;
    my $buf = "";
    while (length($buf) < $want) {
        my $chunk = "";
        my $got = read(STDIN, $chunk, $want - length($buf));
        return undef unless defined $got && $got > 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub read_frame {
    my $header = read_exact(4);
    return undef unless defined $header;
    return read_exact(unpack("N", $header));
}

sub handle_join {
    if ($scenario eq 'denied' || $scenario eq 'signin_required') {
        control(qq({"type":"state","phase":"joining"}));
        control(qq({"type":"join_result","status":"$scenario"}));
        return;
    }

    control(qq({"type":"state","phase":"joining"}));
    control(qq({"type":"join_result","status":"admitted"}));

    if ($scenario eq 'wedge') {
        return;
    }

    control(
        qq({"type":"roster","participants":[{"id":"p_ab12","name":"Ada Lovelace"},)
      . qq({"id":"p_cd34","name":"Fermix Notetaker"}]}));
    control(qq({"type":"active_speaker","id":"p_ab12","t_ms":0}));

    if ($scenario eq 'crash_after_admit') {
        audio();
        exit 1;
    }

    audio() for (1 .. 3);
}

sub handle_leave {
    return if $scenario eq 'wedge';
    control(qq({"type":"meeting_ended","reason":"left"}));
    exit 0;
}

control(
    qq({"type":"hello","protocol_version":$proto,"sidecar_version":"0.0.0-fake","platforms":["meet"]})
) unless $scenario eq 'hang_hello';

while (defined(my $frame = read_frame())) {
    next unless length($frame) > 0 && ord(substr($frame, 0, 1)) == 0x01;
    my $json = substr($frame, 1);

    if    ($json =~ /"type"\s*:\s*"join"/)  { handle_join(); }
    elsif ($json =~ /"type"\s*:\s*"leave"/) { handle_leave(); }
    elsif ($json =~ /"type"\s*:\s*"ping"/)  { control(qq({"type":"pong"})) unless $scenario eq 'wedge'; }
}

exit 0;
