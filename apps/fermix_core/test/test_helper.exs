Code.require_file("../../../test/support/safe_rm.ex", __DIR__)
Code.require_file("../../../test/support/secret_writer_stub.ex", __DIR__)
Code.require_file("../../../test/support/host_runtime_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_fetcher_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_verifier_stub.ex", __DIR__)
Code.require_file("../../../test/support/dist_fixtures.ex", __DIR__)
Code.require_file("../../../test/support/fake_vendor_cli.ex", __DIR__)
Code.require_file("../../../test/support/fake_cloud_cli.ex", __DIR__)

# capture_log: passing tests stay silent — this suite intentionally logs many
# error/warning lines while exercising failure paths, which CI renders as a
# wall of red. A failing test still prints its captured log.
ExUnit.start(capture_log: true)
