#!/usr/bin/env perl
# Test-only fake compux sidecar for the fermix PortDriver adapter. Autoflush so a
# one-line reply reaches the Port immediately.
#
# It speaks protocol 8 framing: every inbound line is a tagged `request` or
# `control` frame carrying a `request_id`, and every reply echoes that id inside a
# tagged `response` or `control_ack`. A reply that hands back coordinates mints an
# `observation_id`; a pointer action that names none, or names one this fake has
# retired, is refused with a `not_sent` receipt exactly as the helper does.
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
#   screenshot/elements/windows -> a minted observation
#   anything else -> ok + pong, with a receipt when the action is mutating
#
# Env: FAKE_PROTO (reported protocol_version), FAKE_SIDECAR_GENERATION,
#      FAKE_CONTROL_MODE ("ack" default, "refuse" to answer ok:false),
#      FAKE_OBSERVATION_ERROR (an addressing/geometry code to refuse every
#      pointer action with, e.g. "expired_observation").
use strict;
use warnings;
$| = 1;

my $proto        = $ENV{FAKE_PROTO} // 8;
my $BOOT         = $ENV{FAKE_SIDECAR_GENERATION} // 'boot-fake';
my $CONTROL_MODE = $ENV{FAKE_CONTROL_MODE} // 'ack';
my $OBS_ERROR    = $ENV{FAKE_OBSERVATION_ERROR};

# One counter per process, so an id from a sidecar that died can never resolve in
# its successor: the boot generation is part of the id.
my $OBS_SEQ = 0;

# Mirrors the helper's addressed set: each of these needs an `observation_id` and
# refuses a `region`.
my %ADDRESSED = map { $_ => 1 } qw(
    left_click right_click double_click mouse_move left_click_drag scroll inspect
);

# Mirrors the helper's producing set: each of these MINTS an observation.
my %PRODUCES = map { $_ => 1 } qw(screenshot elements windows wait_for_change);

# Mirrors the helper's viewing set: these may NAME an image beside their region,
# which says the rectangle is read in that image's pixels. `windows` is not one of
# them — it answers in the full display's own space and takes no id.
my %VIEWING = map { $_ => 1 } qw(screenshot elements wait_for_change);

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

# The addressing half of the wire (protocol 8), matching the helper on BOTH sides:
# an action that reads coordinates must name an image and must not carry a
# rectangle, and an action that reads none must not name an image at all. A fake
# that refused LESS than the helper would let a request shape the helper rejects
# pass every test here. Any refusal below dispatched nothing.
# Returns 1 when the request was answered with a refusal.
sub refuse_addressing {
    my ($id, $action, $line) = @_;
    my $names_image = $line =~ /"observation_id":"[^"]/;

    my $code;
    if ($ADDRESSED{$action}) {
        if    ($line =~ /"region":/) { $code = 'unknown_field'; }
        elsif (!$names_image)        { $code = 'observation_required'; }
        elsif ($OBS_ERROR)           { $code = $OBS_ERROR; }
    }
    elsif ($names_image && !$VIEWING{$action}) {
        # `type`, `key`, `wait`, `windows`, the operational verbs: they read no
        # coordinates, so an observation_id on one is a field the helper does not
        # accept there.
        $code = 'unknown_field';
    }
    return 0 unless $code;

    print qq({"type":"response",) . envelope($id)
        . qq(,"ok":false,"error":"$code","detail":"the fake sidecar refused it",)
        . receipt("not_sent") . qq(}\n);
    return 1;
}

sub observation {
    my ($kind) = @_;
    $OBS_SEQ++;
    return qq("observation_id":"$BOOT-$OBS_SEQ","observation_kind":"$kind",)
        . qq("captured_at_monotonic_ns":1000);
}

sub request {
    my ($id, $action, $line) = @_;

    return if refuse_addressing($id, $action, $line);

    if ($PRODUCES{$action}) {
        my $kind = ($action eq 'elements' || $action eq 'windows') ? 'semantic' : 'image';
        my $body = ($kind eq 'image')
            ? qq("data":"cG5n","mime":"image/png","width":100,"height":80)
            : qq("$action":[]);
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,) . observation($kind) . qq(,$body}\n);
        return;
    }

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
    else                    { request($id, $action, $line); }
}
