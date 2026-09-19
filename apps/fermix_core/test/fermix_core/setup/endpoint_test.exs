defmodule FermixCore.Setup.EndpointTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.Endpoint

  test "resolves an explicit port before the environment" do
    assert Endpoint.port(port: 4041, port_env: "4545") == {:ok, 4041}
  end

  test "resolves the environment port before the default" do
    assert Endpoint.port(port_env: "4545") == {:ok, 4545}
    assert Endpoint.port(port_env: nil) == {:ok, 4030}
    assert Endpoint.port(port_env: "") == {:ok, 4030}
  end

  test "rejects invalid explicit and environment ports" do
    assert Endpoint.port(port: 0, port_env: "4545") ==
             {:error, {:invalid_port, :explicit, 0}}

    assert Endpoint.port(port_env: "70000") ==
             {:error, {:invalid_port, :environment, "70000"}}
  end

  test "publishes the loopback setup endpoint" do
    assert Endpoint.path() == "/setup"
    assert Endpoint.origin(4030) == {:ok, "http://127.0.0.1:4030"}

    assert Endpoint.describe(port: 4030) ==
             {:ok, %{"origin" => "http://127.0.0.1:4030", "path" => "/setup"}}
  end

  # M38 §4.7: the setup origin and the daemon's own listener are one resolver's
  # answer, so `hello`'s published origin cannot name a port nothing listens on.
  test "resolves the persisted setting when no environment port is supplied" do
    assert Endpoint.port(port_env: nil, configured: 4555) == {:ok, 4555}

    assert Endpoint.describe(port_env: nil, configured: 4555) ==
             {:ok, %{"origin" => "http://127.0.0.1:4555", "path" => "/setup"}}
  end

  # The refusal keeps its own reason: a `PORT` a packaged engine does not read is
  # not a `PORT` this resolver parsed and disliked, and calling it invalid would
  # send an operator to fix a number that was never wrong.
  test "a packaged engine reads the setting and refuses a PORT override" do
    assert Endpoint.port(distribution: "linux_package", port_env: nil, configured: 4555) ==
             {:ok, 4555}

    assert {:error, {:port_not_used, sentence}} =
             Endpoint.port(distribution: "linux_package", port_env: "4040", configured: 4555)

    assert sentence =~ "PORT is not used by the packaged engine"
    refute sentence =~ "fermix:"
  end

  test "builds a tokenized launch URL without changing the token" do
    assert Endpoint.launch_url(4030, "token/with spaces") ==
             {:ok, "http://127.0.0.1:4030/setup?t=token%2Fwith+spaces"}
  end
end
