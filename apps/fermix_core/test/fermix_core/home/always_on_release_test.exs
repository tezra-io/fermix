defmodule FermixCore.Home.AlwaysOnReleaseTest do
  @moduledoc """
  Always On is not in a release build yet: a build compiled for `:prod`
  serves none of it, a `:dev` or `:test` build all of it, decided by the
  build's own environment and nothing else. Both branches are asked of the
  management wire here through the router's `:always_on` seam, which stands
  for what a prod build compiles in.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router

  @sentence "Always On is not in this release of Fermix yet."
  @gated ~w(home.status home.act home.provision.options)

  test "a prod build has no Always On, a dev or test build has all of it" do
    refute AlwaysOnRelease.available?(:prod)
    assert AlwaysOnRelease.available?(:dev)
    assert AlwaysOnRelease.available?(:test)
    assert AlwaysOnRelease.available?() == AlwaysOnRelease.available?(Mix.env())
    assert AlwaysOnRelease.methods() == @gated
    assert AlwaysOnRelease.sentence() == @sentence
  end

  test "where it is off, hello lists none of Always On's methods, and the rest as ever" do
    {:ok, on} = hello(true)
    {:ok, off} = hello(false)

    assert on["capabilities"]["methods"] == Protocol.methods()
    assert off["capabilities"]["methods"] == Protocol.methods() -- @gated

    assert Map.keys(off["capabilities"]["minimum_versions"]) -- @gated ==
             Map.keys(off["capabilities"]["minimum_versions"])

    assert Map.drop(on["capabilities"]["minimum_versions"], @gated) ==
             off["capabilities"]["minimum_versions"]
  end

  test "where it is off, the router refuses each of Always On's methods by name, in one sentence" do
    for method <- @gated do
      params = if method == "home.act", do: %{"action" => "cancel", "key" => "k"}, else: %{}

      assert Router.route(request(method, params), always_on: false) ==
               {:error, :unavailable,
                %{"capability" => "always_on", "method" => method, "sentence" => @sentence}}
    end
  end

  test "the refusal's golden is the router's own" do
    golden =
      :fermix_core
      |> Application.app_dir("priv/management/fixtures/errors.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["name"] == "unavailable_always_on_unreleased"))

    assert {:error, :unavailable, details} =
             Router.route(request("home.act", %{"action" => "cancel", "key" => "k"}),
               always_on: false
             )

    assert golden["response"]["error"]["details"] == details
  end

  test "where it is on, the router serves them as ever" do
    refute match?(
             {:error, :unavailable, %{"capability" => "always_on"}},
             Router.route(request("home.act", %{"action" => "learn_more", "key" => "k"}),
               always_on: true
             )
           )
  end

  defp hello(available?) do
    Router.route(request("hello", %{}),
      identity_provider: fn -> {:ok, identity()} end,
      endpoint_opts: [port: 4041],
      always_on: available?
    )
  end

  defp identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => "build-456",
      "source_commit" => "abcdef123456",
      "distribution_identity" => "macos_app",
      "artifact_target" => "macos_aarch64",
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end

  defp request(method, params),
    do: %{request_id: "req-1", protocol_version: 2, method: method, params: params}
end
