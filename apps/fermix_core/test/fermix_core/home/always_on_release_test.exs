defmodule FermixCore.Home.AlwaysOnReleaseTest do
  @moduledoc """
  Always On is not in a release build yet: a build compiled for `:prod`
  serves none of it unless its home's settings file turns it on
  (`[fermix_core.always_on] enabled = true`), and a `:dev` or `:test` build
  serves all of it whatever the file says. The build's environment decides
  first, and within a `:prod` build the home's switch. Both branches are
  asked of the management wire here through the router's `:always_on` seam,
  which stands for the resolver's answer; the resolver itself is asked with
  each build environment named, and a home's own file is read through an
  explicit home, so nothing here touches application environment.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @sentence "Always On is not in this release of Fermix yet."
  @gated ~w(home.status home.enroll.approve home.enroll.deny home.act computers.rename
             computer.join.start computer.join.cancel computer.disconnect computer.journal.list
             computer.screen.stop)

  test "a prod build offers Always On only where its home turns it on, dev and test always" do
    refute AlwaysOnRelease.available?(:prod, [])
    refute AlwaysOnRelease.available?(:prod, enabled: false)
    assert AlwaysOnRelease.available?(:prod, enabled: true)

    for env <- [:dev, :test], config <- [[], [enabled: false], [enabled: true]] do
      assert AlwaysOnRelease.available?(env, config), inspect({env, config})
    end

    assert AlwaysOnRelease.methods() == @gated
    assert AlwaysOnRelease.sentence() == @sentence
  end

  test "a process with no engine reads the switch from the home's own settings file" do
    home = SafeRm.make_tmp_dir!("always_on_release_home")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    file = Path.join(home, "config.toml")

    # A fresh home has no settings file at all.
    assert AlwaysOnRelease.available_in(home, :prod) == {:ok, false}
    assert AlwaysOnRelease.available_in(home, :test) == {:ok, true}
    refute File.exists?(file)

    File.write!(file, ~s([fermix_core.engine]\nrole = "primary"\n))
    assert AlwaysOnRelease.available_in(home, :prod) == {:ok, false}

    File.write!(file, "[fermix_core.always_on]\nenabled = true\n")
    assert AlwaysOnRelease.available_in(home, :prod) == {:ok, true}
    assert AlwaysOnRelease.available_in(home) == AlwaysOnRelease.available_in(home, Mix.env())

    File.write!(file, "[fermix_core.always_on]\nenabled = false\n")
    assert AlwaysOnRelease.available_in(home, :prod) == {:ok, false}

    # A switch Fermix cannot read is named with its file, in every build,
    # never read as off: the engine of this home would not start on it either.
    File.write!(file, ~s([fermix_core.always_on]\nenabled = "yes"\n))

    for env <- [:prod, :dev, :test] do
      assert {:error, {:config, ^file, message}} = AlwaysOnRelease.available_in(home, env)
      assert message =~ "[fermix_core.always_on] enabled takes true or false"
    end
  end

  test "the section's two shapes are inverses, and a bad one is refused by name" do
    assert AlwaysOnRelease.normalize(nil) == []
    assert AlwaysOnRelease.normalize(%{"enabled" => true}) == [enabled: true]
    assert AlwaysOnRelease.normalize(%{"enabled" => false}) == [enabled: false]

    for app_env <- [[], [enabled: true], [enabled: false]] do
      assert AlwaysOnRelease.normalize(app_env) == app_env
      assert AlwaysOnRelease.normalize(AlwaysOnRelease.to_keyword(app_env)) == app_env
      assert AlwaysOnRelease.to_keyword(app_env) == app_env
    end

    error = assert_raise ArgumentError, fn -> AlwaysOnRelease.normalize(%{"enable" => true}) end
    assert error.message =~ "config.toml [fermix_core.always_on] has unknown key(s): enable"

    error = assert_raise ArgumentError, fn -> AlwaysOnRelease.normalize(%{"enabled" => 1}) end
    assert error.message =~ "[fermix_core.always_on] enabled takes true or false"

    error = assert_raise ArgumentError, fn -> AlwaysOnRelease.normalize(true) end
    assert error.message =~ "config.toml [fermix_core.always_on] is not a table"
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
