#!/usr/bin/env perl
# Test-only fake fermix-stt sidecar. Speaks the NDJSON wire the real Rust
# sidecar implements, so Local.Sidecar and Local.StreamSession can be driven
# against a real OS process without a model or an ONNX runtime.
#
# Env knobs:
#   FAKE_STT_PROTO   hello protocol_version (default 1; set 2 for the mismatch refusal)
#   FAKE_STT_MODE    ok | error | hang | hang_hello | die | long
#
# Modes:
#   ok          batch replies "fake transcript"; stream replies one segment
#   error       batch and stream_start reply an error frame (code decode_failed)
#   hang        batch never replies (exercises the batch deadline)
#   hang_hello  no hello at all (exercises the hello deadline)
#   die         exits 3 on the first transcribe or audio frame
#   long        batch replies a transcript far longer than the port's line
#               window, so {:noeol, _} reassembly is exercised end to end
#
# Every mode exits on stdin EOF: the read loop is the only blocking point
# outside the deliberate sleeps.
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);

$| = 1;

my $proto = $ENV{FAKE_STT_PROTO} // 1;
my $mode  = $ENV{FAKE_STT_MODE}  // 'ok';

my $pcm_bytes = 0;

if ($mode eq 'hang_hello') {
    sleep 10;
    exit 0;
}

print qq({"event":"hello","protocol_version":$proto,"engine":"sherpa-onnx","stt_version":"0.0.0-fake"}\n);

sub id_of {
    my ($json) = @_;
    return $json =~ /"id"\s*:\s*"([^"]*)"/ ? $1 : "";
}

sub error_frame {
    my ($id) = @_;
    print qq({"event":"error","id":"$id","code":"decode_failed","message":"fake decode failure"}\n);
}

sub handle_transcribe {
    my ($id) = @_;

    if    ($mode eq 'error') { error_frame($id); }
    elsif ($mode eq 'hang')  { sleep 10; }
    elsif ($mode eq 'die')   { exit 3; }
    elsif ($mode eq 'long')  {
        my $text = "fake " x 30000;
        print qq({"event":"result","id":"$id","text":"$text","duration_ms":12}\n);
    }
    else {
        print qq({"event":"result","id":"$id","text":"fake transcript","duration_ms":12}\n);
    }
}

sub handle_stream_start {
    my ($id) = @_;
    return error_frame($id) if $mode eq 'error';
    print qq({"event":"stream_started","id":"$id"}\n);
}

sub handle_audio {
    my ($json) = @_;
    exit 3 if $mode eq 'die';
    my ($b64) = $json =~ /"pcm"\s*:\s*"([^"]*)"/;
    $pcm_bytes += length(decode_base64($b64 // ""));
}

sub handle_stream_end {
    my ($id) = @_;
    my $t1 = int($pcm_bytes / 32);
    print qq({"event":"segment","id":"$id","text":"fake segment","t0_ms":0,"t1_ms":$t1}\n);
    print qq({"event":"stream_done","id":"$id","segments":1}\n);
}

while (my $line = <STDIN>) {
    my $id = id_of($line);

    if    ($line =~ /"op"\s*:\s*"transcribe"/)   { handle_transcribe($id); }
    elsif ($line =~ /"op"\s*:\s*"stream_start"/) { handle_stream_start($id); }
    elsif ($line =~ /"op"\s*:\s*"audio"/)        { handle_audio($line); }
    elsif ($line =~ /"op"\s*:\s*"stream_end"/)   { handle_stream_end($id); }
    elsif ($line =~ /"op"\s*:\s*"shutdown"/)     { exit 0; }
    else { print qq({"event":"error","id":"$id","code":"bad_request","message":"unknown op"}\n); }
}

exit 0;
