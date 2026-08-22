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

  test "builds a tokenized launch URL without changing the token" do
    assert Endpoint.launch_url(4030, "token/with spaces") ==
             {:ok, "http://127.0.0.1:4030/setup?t=token%2Fwith+spaces"}
  end
end
