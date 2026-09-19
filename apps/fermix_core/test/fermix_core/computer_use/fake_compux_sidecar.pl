#!/usr/bin/env perl
# Test-only fake compux sidecar for the fermix PortDriver adapter. Autoflush so a
# one-line reply reaches the Port immediately.
#
# It speaks protocol 7 framing: every inbound line is a tagged `request` or
# `control` frame carrying a `request_id`, and every reply echoes that id inside a
# tagged `response` or `control_ack`.
#
# The stdin loop NEVER blocks on a request it cannot answer yet, which is the
# whole point of the control channel: `defer` records the id and keeps reading, so
# a control arriving afterwards is answered WHILE that request is still open and
# its ack can name it. A fake that slept here would let a Fermix adapter which
# serialised controls behind actions pass every test.
#
# Actions:
#   hello       the identity handshake
#   hang        sleep, never reply           (the action deadline)
#   boom        exit 7                       (a sidecar that dies mid-request)
#   defer       record the id, answer only once a control releases it
#   refuse      ok:false + error + a not_sent receipt (a refused mutation)
#   no_receipt  ok:true with NO receipt on a mutating action (the protocol fault)
#   anything else -> ok + pong, with a receipt when the action is mutating
#
# Env: FAKE_PROTO (reported protocol_version), FAKE_SIDECAR_GENERATION,
#      FAKE_CONTROL_MODE ("ack" default, "refuse" to answer ok:false).
use strict;
use warnings;
$| = 1;

my $proto        = $ENV{FAKE_PROTO} // 7;
my $BOOT         = $ENV{FAKE_SIDECAR_GENERATION} // 'boot-fake';
my $CONTROL_MODE = $ENV{FAKE_CONTROL_MODE} // 'ack';

# Both sides start at 1 and the gate owns every later value, which it publishes in
# each ack. Walking it — rather than answering a constant — is what proves a
# consumer reads the ack's number instead of assuming one.
my $AUTH = 1;
my $deferred;

# Mirrors Compux.Protocol's read-only set, plus the operational verbs that are not
# model actions: only a mutating action carries a receipt.
my %READ_ONLY = map { $_ => 1 } qw(
    screenshot mouse_move wait inspect wait_for_change elements windows
    hello probe idle_ms wait_for_idle hang defer no_receipt
);

sub envelope {
    my ($id) = @_;
    return qq("request_id":"$id","sidecar_generation":"$BOOT","session_generation":1);
}

sub receipt {
    my ($dispatch) = @_;
    return qq("receipt":{"dispatch":"$dispatch","effect":"unknown",)
        . qq("input_method":"foreground_hid","timings_ms":{"input":1,"settle":0,"capture":0}});
}

sub control {
    my ($id, $action) = @_;
    my $ok = ($CONTROL_MODE eq 'refuse') ? 'false' : 'true';
    $AUTH++;

    my $in_flight = defined $deferred ? qq("$deferred") : 'null';
    print qq({"type":"control_ack",) . envelope($id)
        . qq(,"action":"$action","ok":$ok,)
        . qq("authorization_generation":$AUTH,"in_flight_request_id":$in_flight}\n);

    # The barrier is installed, so the held request answers as a cancelled one:
    # some of its input reached the screen, which is what `partial` says.
    if (defined $deferred && $ok eq 'true') {
        print qq({"type":"response",) . envelope($deferred)
            . qq(,"ok":false,"error":"cancelled",) . receipt("partial") . qq(}\n);
        undef $deferred;
    }
}

sub request {
    my ($id, $action) = @_;

    if ($action eq 'hello') {
        # hello answers through the SAME envelope as every other response, so it
        # carries the session generation as well as the boot one.
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,"protocol_version":$proto,)
            . qq("compux_version":"0.0.0-fake","actions":[],)
            . qq("capabilities":{"input_methods":["foreground_hid"],)
            . qq("controls":["pause","resume","release"]}}\n);
    }
    elsif ($action eq 'hang')  { sleep 10; }
    elsif ($action eq 'boom')  { exit 7; }
    elsif ($action eq 'defer') { $deferred = $id; }
    elsif ($action eq 'refuse') {
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":false,"error":"paused","detail":"a pause is installed",)
            . receipt("not_sent") . qq(}\n);
    }
    elsif ($action eq 'no_receipt') {
        print qq({"type":"response",) . envelope($id) . qq(,"ok":true,"pong":true}\n);
    }
    else {
        my $receipt = $READ_ONLY{$action} ? '' : ',' . receipt('sent');
        print qq({"type":"response",) . envelope($id) . qq(,"ok":true,"pong":true$receipt}\n);
    }
}

while (my $line = <STDIN>) {
    my ($type)   = $line =~ /"type":"([^"]*)"/;
    my ($id)     = $line =~ /"request_id":"([^"]*)"/;
    my ($action) = $line =~ /"action":"([^"]*)"/;
    $type   = '' unless defined $type;
    $id     = '' unless defined $id;
    $action = '' unless defined $action;

    if ($type eq 'control') { control($id, $action); }
    else                    { request($id, $action); }
}
