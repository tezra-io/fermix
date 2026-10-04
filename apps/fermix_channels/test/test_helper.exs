# capture_log: passing tests stay silent (failure-path tests log error/warning
# lines that CI renders as a wall of red); a failing test still prints its log.
#
# assert_receive_timeout: see apps/fermix_core/test/test_helper.exs for why the
# 100 ms default is not this repo's bound for a message-arrival assertion.
#
# Shared fakes of this app's own seams live under test/support/ as `*_helper.exs`
# (which `mix test` neither loads as tests nor warns about) and are loaded
# here, before any test module that names them is compiled.
Code.require_file("support/imessage_fake_helper.exs", __DIR__)

ExUnit.start(capture_log: true, assert_receive_timeout: 2_000)
