#!/usr/bin/env perl
# Test-only fake compux sidecar for the fermix PortDriver adapter. Autoflush so a
# one-line reply reaches the Port immediately.
#
# It speaks protocol 11 framing: every inbound line is a tagged `request` or
# `control` frame carrying a `request_id`, and every reply echoes that id inside a
# tagged `response` or `control_ack`. A reply that hands back coordinates mints an
# `observation_id`; a pointer action that names none, or names one this fake has
# retired, is refused with a `not_sent` receipt exactly as the helper does.
#
# Protocol 9 added the references: `elements` hands back controls carrying an
# `element_ref`, `press` and `set_value` address one, and a pointer action may
# address one INSTEAD of a point. Every refusal the helper has for them is here
# too — a fake that refused LESS than the helper would let a request shape the
# helper rejects pass every test in this repo.
#
# Protocol 11 adds the bound window: `select_target` binds one window from a
# `windows` listing and answers a `target_id`, what it bound, by which methods it
# can be reached, whether its accessibility window was bound, and a first
# observation of that window alone; `release_target` ends it; every action inside
# it carries `target_id`. Every refusal the helper has for a bound window is here
# too — a window that went away, one that is minimized, one something covers, one
# with no accessibility window, a missing on-screen indicator and the two capture
# failures — because a fake that refused LESS than the helper would leave every
# one of those paths unproven. `idle_ms` answers `front_is_target` beside its
# reading, which is what tells the person working in THIS window from the person
# working elsewhere.
#
# Protocol 10 replaced `screenshot_after` with `check`, and a mutating success
# answers exactly what its request asked for: `image` returns the view the action
# acted in (this fake settles instantly, so its timings are zero), `semantic`
# returns the control read again as `element_after`, `none` returns the receipt
# alone. Every mutating success carries `check` AND `timings_ms` — a fake that
# omitted either, or that could never time out, would be KINDER than the helper
# and every test built on it would prove nothing.
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
#   cancel_check  ok:false + "cancelled" with a SENT receipt carrying no check:
#                 the input went out and the settle was cancelled under it
#   screenshot/windows -> a minted observation
#   elements    -> a minted observation plus the controls it named, one of each
#                  kind the summary has to render: pressable, settable, disabled
#   press       -> an `ax` receipt, effect not_observed (an AX return is a
#                  dispatch result, not an effect), plus the control read again
#   set_value   -> an `ax` receipt, effect verified (or not_observed for the
#                  secure field, which reads back masked)
#   anything else -> ok + pong, with a receipt when the action is mutating, and
#                  with the evidence its `check` asked for
#
# Env: FAKE_PROTO (reported protocol_version), FAKE_SIDECAR_GENERATION,
#      FAKE_CONTROL_MODE ("ack" default, "refuse" to answer ok:false),
#      FAKE_OBSERVATION_ERROR (an addressing/geometry code to refuse every
#      pointer action with, e.g. "expired_observation"),
#      FAKE_ELEMENT_ERROR (an element code to refuse every referenced action
#      with, e.g. "element_disabled"),
#      FAKE_FOREGROUND_CHANGED (1 to report that an AX action took the front),
#      FAKE_SETTLE ("stable" default, "timeout" for a view that never settled),
#      FAKE_CHANGED (1 default, 0 for a view identical to the one acted on),
#      FAKE_TARGET_ERROR (a bound-window code to refuse every action carrying a
#      `target_id` with, e.g. "target_minimized" — each of the bound-window
#      codes is a code of its own, never folded into a neighbour),
#      FAKE_NO_TARGETS (1 for a build that advertises no window binding),
#      FAKE_INDICATOR ("present" default, "missing" for a bundle with none),
#      FAKE_AX_BINDING ("bound" default; "unavailable" drops `ax` from methods),
#      FAKE_FRONT_IS_TARGET (1 to report the bound window as the front one),
#      FAKE_TARGET_CHILDREN (1 to report a second window of the same process).
use strict;
use warnings;
$| = 1;

my $proto        = $ENV{FAKE_PROTO} // 11;
my $BOOT         = $ENV{FAKE_SIDECAR_GENERATION} // 'boot-fake';
my $CONTROL_MODE = $ENV{FAKE_CONTROL_MODE} // 'ack';
my $OBS_ERROR    = $ENV{FAKE_OBSERVATION_ERROR};
my $ELEMENT_ERROR = $ENV{FAKE_ELEMENT_ERROR};
my $FOREGROUND   = $ENV{FAKE_FOREGROUND_CHANGED} ? 'true' : 'false';
my $SETTLE       = $ENV{FAKE_SETTLE} // 'stable';
my $CHANGED      = (defined $ENV{FAKE_CHANGED} && $ENV{FAKE_CHANGED} eq '0') ? 'false' : 'true';
my $TARGET_ERROR = $ENV{FAKE_TARGET_ERROR};
my $INDICATOR    = $ENV{FAKE_INDICATOR} // 'present';
my $AX_BINDING   = $ENV{FAKE_AX_BINDING} // 'bound';
my $FRONT        = $ENV{FAKE_FRONT_IS_TARGET} ? 'true' : 'false';
my $TARGETS      = $ENV{FAKE_NO_TARGETS} ? 'false' : 'true';
my $CHILDREN     = $ENV{FAKE_TARGET_CHILDREN}
    ? qq(,"children":[{"window_id":9,"app":"Fixture","title":"Second window"}])
    : '';

# The targets this fake has bound, in the order they were asked for. Mirrors the
# helper: one target at a time, and selecting again REPLACES it.
my $TARGET_SEQ = 0;
my $BOUND = 0;

# One counter per process, so an id from a sidecar that died can never resolve in
# its successor: the boot generation is part of the id.
my $OBS_SEQ = 0;

# Mirrors the helper's addressed set: each of these is aimed INTO an observation,
# so each needs an `observation_id` and refuses a `region`.
my %ADDRESSED = map { $_ => 1 } qw(
    left_click right_click double_click mouse_move left_click_drag scroll inspect
    press set_value
);

# Mirrors the helper's element set: addressed by a control, never by a point.
my %ELEMENT_ONLY = map { $_ => 1 } qw(press set_value);

# The references this fake has minted, and what each control answers to. `e1`
# presses, `e2` is a settable field, `e3` is the secure field whose read-back is
# masked, `e4` is disabled and `e5` offers no accessibility action at all.
my %ELEMENTS = map { $_ => 1 } qw(e1 e2 e3 e4 e5);

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
    select_target release_target
    hello probe idle_ms wait_for_idle hang defer no_receipt
);

# Mirrors the helper's targetable set: everything that looks at, or acts inside,
# ONE window. `windows` enumerates the desktop's, `wait` and `wait_for_change`
# have no target to name, and the two target verbs are not inside one.
my %TARGETABLE = map { $_ => 1 } qw(
    screenshot elements inspect left_click right_click double_click mouse_move
    left_click_drag scroll type key paste press set_value
);

sub envelope {
    my ($id) = @_;
    return qq("request_id":"$id","sidecar_generation":"$BOOT","session_generation":1);
}

# This fake settles instantly and encodes nothing, so every phase but the input
# costs zero — reported, never omitted: a mutating success without `timings_ms` is
# a shape the helper never sends.
my $TIMINGS = qq("timings_ms":{"input":1,"settle":0,"capture":0,"encode":0});

# The evidence a mutating success carries, which is the evidence its request asked
# for. An image check also says whether the view settled and whether it differs
# from the one acted on; a semantic check answers neither, being a reading of one
# control rather than a picture.
sub check_field {
    my ($kind) = @_;
    return qq("check":{"kind":"image","settle":"$SETTLE","changed":$CHANGED}) if $kind eq 'image';
    return qq("check":{"kind":"$kind"});
}

sub requested_check {
    my ($line) = @_;
    my ($kind) = $line =~ /"check":"([^"]*)"/;
    return defined $kind ? $kind : 'none';
}

sub receipt {
    my ($dispatch, $kind) = @_;
    my $check = defined $kind ? ',' . check_field($kind) : '';
    return qq("receipt":{"dispatch":"$dispatch","effect":"unknown",)
        . qq("input_method":"foreground_hid",$TIMINGS$check});
}

# The receipt an accessibility action earns: the `ax` method, the effect its own
# read-back proved, whether the action pulled its application to the front, and
# the control read again.
sub ax_receipt {
    my ($effect) = @_;
    return qq("receipt":{"dispatch":"sent","effect":"$effect","input_method":"ax",)
        . qq("foreground_changed":$FOREGROUND,$TIMINGS,) . check_field('semantic') . qq(});
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

# The addressing half of the wire (protocol 11), matching the helper on BOTH
# sides: an action aimed into an observation must name it and must not
# carry a rectangle; an action that aims at nothing must not name one at all; and
# a target named twice, or named by a reference nobody minted, is refused before
# anything is dispatched. A fake that refused LESS than the helper would let a
# request shape the helper rejects pass every test here. Any refusal below
# dispatched nothing. Returns 1 when the request was answered with a refusal.
sub refuse_addressing {
    my ($id, $action, $line) = @_;
    my $names_image = $line =~ /"observation_id":"[^"]/;
    my ($reference) = $line =~ /"element_ref":"([^"]*)"/;
    my $has_point = $line =~ /"(?:x|from|to)":/;
    my ($target) = $line =~ /"target_id":"([^"]*)"/;

    my $code;
    # v11: a target on an action that does not act inside one window is a field
    # the helper does not accept there, and an action INSIDE a bound window
    # carries every refusal the binding can produce.
    if (defined $target && !$TARGETABLE{$action}) { $code = 'unknown_field'; }
    elsif (defined $target && $TARGET_ERROR)      { $code = $TARGET_ERROR; }
    if (!defined $code) {
        if ($ADDRESSED{$action}) {
            if    ($line =~ /"region":/)                 { $code = 'unknown_field'; }
            elsif (!$names_image)                        { $code = 'observation_required'; }
            elsif (defined $reference && $has_point)     { $code = 'addressing_conflict'; }
            elsif ($ELEMENT_ONLY{$action} && !defined $reference) { $code = 'element_required'; }
            elsif (defined $reference && !$ELEMENTS{$reference})  { $code = 'stale_element'; }
            elsif (defined $reference && $ELEMENT_ERROR) { $code = $ELEMENT_ERROR; }
            elsif ($OBS_ERROR)                           { $code = $OBS_ERROR; }
        }
        elsif (defined $reference) {
            # `type`, `key`, `wait`, `windows` and the viewing actions address no
            # control, so a reference on one is a field the helper does not accept.
            $code = 'unknown_field';
        }
        elsif ($names_image && !$VIEWING{$action}) {
            # `type`, `key`, `wait`, `windows`, the operational verbs: they read no
            # coordinates, so an observation_id on one is a field the helper does not
            # accept there.
            $code = 'unknown_field';
        }
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

# The picture a mutating action's `check: "image"` answers with: an image like any
# other, minting its own id, which is the one the caller's next action names.
sub check_image {
    return observation('image')
        . qq(,"data":"cG5n","mime":"image/jpeg","width":100,"height":80,)
        . qq("region":{"x":0,"y":0,"w":100,"h":80});
}

# The control a `check: "semantic"` answers with, read again after the action.
# `present` is ALWAYS there and is the first thing the consumer reads: a control
# that no longer answers is `{"present": false}` and nothing else, which is the
# most informative thing the re-read has to say. A control whose value is withheld
# carries none at all rather than a masked one.
sub element_after {
    my ($role, $label, $enabled, $value) = @_;
    return qq("element_after":{"present":false}) unless defined $role;
    my $named = defined $label ? qq(,"label":"$label") : '';
    my $held  = defined $value ? qq(,"value":"$value") : '';
    return qq("element_after":{"present":true,"role":"$role"$named,"enabled":$enabled$held});
}

# One control of each kind the summary has to render, exactly as the helper lists
# them: a pressable button, a settable field, a secure field, a disabled button,
# and one that offers no accessibility action at all.
sub elements_body {
    return qq("elements":[)
        . qq({"element_ref":"e1","role":"AXButton","label":"Save",)
        . qq("enabled":true,"actions":["press"],"settable":false,)
        . qq("bounds":{"x":10,"y":20,"w":60,"h":24},"path":["Document","Toolbar"],)
        . qq("x":40,"y":32},)
        . qq({"element_ref":"e2","role":"AXTextField","label":"Search","value":"chess",)
        . qq("enabled":true,"actions":[],"settable":true,)
        . qq("bounds":{"x":10,"y":60,"w":200,"h":24},"path":["Toolbar"],"x":110,"y":72},)
        . qq({"element_ref":"e3","role":"AXSecureTextField","label":"Password",)
        . qq("enabled":true,"actions":[],"settable":true,)
        # A secure field's contents are never read, so it carries no `value` at all.
        . qq("bounds":{"x":10,"y":90,"w":200,"h":24},"path":["Toolbar"],"x":110,"y":102},)
        . qq({"element_ref":"e4","role":"AXButton","label":"Delete",)
        . qq("enabled":false,"actions":["press"],"settable":false,)
        . qq("bounds":{"x":10,"y":120,"w":60,"h":24},"path":["Document"],"x":40,"y":132},)
        . qq({"element_ref":"e5","role":"AXImage","label":"Board",)
        . qq("enabled":true,"actions":[],"settable":false,)
        . qq("bounds":{"x":10,"y":150,"w":60,"h":24},"path":["Document"],"x":40,"y":162})
        . qq(],"truncated":"nodes");
}

# The window this fake just bound, exactly as the helper answers one: what it
# bound (labels, never keys), by which methods it can be reached, whether its
# accessibility window was bound, and a first observation of that window alone.
sub target_body {
    my $methods = ($AX_BINDING eq 'bound')
        ? '["foreground_hid","ax"]'
        : '["foreground_hid"]';

    return qq("target_id":"t$TARGET_SEQ","target_generation":$TARGET_SEQ,)
        . qq("window_id":7,"app":"Fixture","title":"Fixture window",)
        . qq("methods":$methods,"ax_binding":"$AX_BINDING"$CHILDREN,)
        . observation('image')
        . qq(,"data":"cG5n","mime":"image/png","width":100,"height":80,)
        . qq("region":{"x":0,"y":0,"w":100,"h":80});
}

sub request {
    my ($id, $action, $line) = @_;

    return if refuse_addressing($id, $action, $line);

    # v11: binding and unbinding dispatch nothing, so they carry no receipt.
    if ($action eq 'select_target') {
        # The helper takes an INTEGER window id and nothing else: there is no
        # "desktop" window, there is the absence of a target.
        unless ($line =~ /"window_id":\s*\d+/) {
            print qq({"type":"response",) . envelope($id)
                . qq(,"ok":false,"error":"invalid_argument",)
                . qq("detail":"select_target needs window_id"}\n);
            return;
        }
        if ($TARGET_ERROR) {
            print qq({"type":"response",) . envelope($id)
                . qq(,"ok":false,"error":"$TARGET_ERROR",)
                . qq("detail":"the fake sidecar refused the binding"}\n);
            return;
        }
        $TARGET_SEQ++;
        $BOUND = 1;
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,) . target_body() . qq(}\n);
        return;
    }
    if ($action eq 'release_target') {
        # Idempotent, and a no-op when there was none: releasing nothing is what
        # the caller asked for either way, so it says so rather than refusing.
        my $released = $BOUND ? 'true' : 'false';
        $BOUND = 0;
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,"released":$released}\n);
        return;
    }

    # An accessibility action reports what IT observed; a pointer action addressed
    # by a reference still went out over the pointer, so it keeps the HID receipt.
    # The PAYLOADS are the helper's exactly — a press answers a bare ack, and a
    # set_value answers `verified` plus what the field holds NOW, withheld for a
    # secure field whose value is never read back rather than published as a row
    # of bullets. A fake that invented `pressed`/`value_set` keys would let this
    # side come to depend on fields the helper never sends.
    if ($action eq 'press') {
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,) . element_after('AXButton', 'Save', 'true', undef) . qq(,)
            . ax_receipt('not_observed') . qq(}\n);
        return;
    }
    if ($action eq 'set_value') {
        my ($reference) = $line =~ /"element_ref":"([^"]*)"/;
        my ($value)     = $line =~ /"value":"([^"]*)"/;
        $value = '' unless defined $value;
        my $secure    = ($reference eq 'e3');
        my $effect    = $secure ? 'not_observed' : 'verified';
        my $verified  = $secure ? 'false' : 'true';
        my $read_back = $secure ? '' : qq("value":"$value",);
        # A secure control's value is never read back, so its `element_after`
        # carries none either — the same withholding, on both halves of the frame.
        my $after = $secure
            ? element_after('AXTextField', 'Password', 'true', undef)
            : element_after('AXTextField', 'Search', 'true', $value);
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,"verified":$verified,$read_back$after,)
            . ax_receipt($effect) . qq(}\n);
        return;
    }

    if ($PRODUCES{$action}) {
        my $kind = ($action eq 'elements' || $action eq 'windows') ? 'semantic' : 'image';
        my $body = ($kind eq 'image')
            ? qq("data":"cG5n","mime":"image/png","width":100,"height":80)
            : ($action eq 'elements' ? elements_body() : qq("$action":[]));
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
            . qq("capture_methods":["display","window"],)
            . qq("targets":$TARGETS,"indicator":"$INDICATOR",)
            . qq("controls":["pause","resume","release"]}}\n);
    }
    elsif ($action eq 'idle_ms') {
        # v11: `front_is_target` rides the idle reading, so a caller can tell the
        # person working in THIS window from the person working elsewhere.
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,"idle_ms":10000,"front_is_target":$FRONT}\n);
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
    elsif ($action eq 'cancel_check') {
        # The input went out in full and the settle was cancelled under it, so the
        # frame is a refusal whose receipt says `sent` and carries NO check. The
        # helper is honest about both halves; so is this.
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":false,"error":"cancelled","detail":"the settle was cancelled",)
            . receipt('sent') . qq(}\n);
    }
    elsif ($READ_ONLY{$action}) {
        print qq({"type":"response",) . envelope($id) . qq(,"ok":true,"pong":true}\n);
    }
    else {
        # A mutating success answers the evidence its request asked for, and always
        # says which evidence that was.
        my $kind = requested_check($line);
        my $body = ($kind eq 'image') ? ',' . check_image() : '';
        print qq({"type":"response",) . envelope($id)
            . qq(,"ok":true,"pong":true$body,) . receipt('sent', $kind) . qq(}\n);
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
