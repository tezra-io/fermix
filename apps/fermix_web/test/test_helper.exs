Code.require_file("../../../test/support/safe_rm.ex", __DIR__)
Code.require_file("../../../test/support/secret_writer_stub.ex", __DIR__)
Code.require_file("../../../test/support/host_runtime_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_fetcher_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_verifier_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_fixtures.ex", __DIR__)

# capture_log: passing tests stay silent (failure-path tests log error/warning
# lines that CI renders as a wall of red); a failing test still prints its log.
ExUnit.start(capture_log: true)
