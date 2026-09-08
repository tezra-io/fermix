# capture_log: passing tests stay silent — this suite intentionally logs many
# error/warning lines while exercising failure paths, which CI renders as a
# wall of red. A failing test still prints its captured log.
#
# assert_receive_timeout: an `assert_receive` asserts that a message ARRIVES, not
# that it arrives inside a budget — a satisfied one returns the moment the message
# lands, so a larger bound costs a passing run nothing and only lengthens a genuine
# failure. ExUnit's 100 ms default was never this repo's choice: of the 747
# `assert_receive` calls that name a bound, 704 name 1_000, 2_000 or 5_000 ms and
# exactly 3 name 100, so whenever an author considered the question they concluded
# 100 ms was too small. The ~1_500 that say nothing inherit it anyway, and on the
# macos-x64 CI leg that inheritance is what fails: the same fermix_core async phase
# takes ~146 s there against ~52 s on linux-x64 at the same max_cases, and across
# eight runs on one branch ten different tests failed that way, five of them on a
# single commit. A test that asserts LATENCY still owns its own bound: this does not
# touch `refute_receive` (499 uses, whose whole meaning is a window) and it does not
# touch an explicit timeout anywhere.
ExUnit.start(capture_log: true, assert_receive_timeout: 2_000)
