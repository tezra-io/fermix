# capture_log: passing tests stay silent (failure-path tests log error/warning
# lines that CI renders as a wall of red); a failing test still prints its log.
#
# assert_receive_timeout: see apps/fermix_core/test/test_helper.exs for why the
# 100 ms default is not this repo's bound for a message-arrival assertion.
ExUnit.start(capture_log: true, assert_receive_timeout: 2_000)
