defmodule FermixCore.Tools.PlaceSearch.BackendTest do
  @moduledoc """
  The one place search backend choice (M72 §14.1): the resolver per platform,
  with the platform named; the section's normalizer and its inverse; the
  save then load round trip; and the settings rows that offer it, per host.

  `async: false`: the settings cases write a settings file under their own
  `FERMIX_HOME` and read and restore the global sections they touch.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Backend
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.PlaceSearch.Config
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @core_keys [:tools, :memory, :secret_writer]

  describe "resolve/2" do
    test "unset, the platform decides: Apple Maps on a Mac, Brave elsewhere" do
      assert Backend.resolve(%{backend: nil}, macos?: true) ==
               %{name: :apple_maps, module: AppleMaps, source: :platform_default}

      assert Backend.resolve(%{backend: nil}, macos?: false) ==
               %{name: :brave, module: Brave, source: :platform_default}
    end

    test "a configured backend wins on either platform, and says so" do
      for macos? <- [true, false], backend <- [:apple_maps, :brave] do
        assert %{name: ^backend, source: :configured} =
                 Backend.resolve(%{backend: backend}, macos?: macos?)
      end
    end

    test "a Mac can run both backends and Linux runs Brave alone" do
      assert Backend.available(true) == [:apple_maps, :brave]
      assert Backend.available(false) == [:brave]
    end
  end

  describe "ready/2" do
    test "Apple Maps off a Mac fails loud, before the helper is looked at" do
      resolution = Backend.resolve(%{backend: :apple_maps}, macos?: false)

      assert {:error, reason} =
               Backend.ready(resolution, macos?: false, helper_path: "/bin/sh")

      assert reason =~ "provider_error: Apple Maps place search runs only on macOS"
      assert reason =~ ~s(backend = "brave")
    end

    test "Apple Maps on a Mac is ready only with its helper on disk" do
      resolution = Backend.resolve(%{backend: nil}, macos?: true)

      assert :ok = Backend.ready(resolution, macos?: true, helper_path: "/bin/sh")

      assert {:error, "provider_error: this build carries no Apple Maps helper" <> _} =
               Backend.ready(resolution, macos?: true, helper_path: "/nonexistent/fermix-maps")
    end

    test "Brave is ready only with a resolvable key" do
      resolution = Backend.resolve(%{backend: :brave}, macos?: true)

      assert :ok = Backend.ready(resolution, brave_api_key: "brave-secret")
      assert {:error, "auth_failed: missing Brave API key"} = Backend.ready(resolution, [])

      assert {:error, "auth_failed: missing Brave API key"} =
               Backend.ready(resolution, brave_api_key: "@keyring")
    end
  end

  describe "Config" do
    test "the file's strings and the environment's atoms normalize to one choice" do
      assert Config.normalize(%{"backend" => "apple_maps"}) == %{backend: :apple_maps}
      assert Config.normalize(%{"backend" => " Brave "}) == %{backend: :brave}
      assert Config.normalize(backend: :apple_maps) == %{backend: :apple_maps}
      assert Config.normalize(backend: "brave") == %{backend: :brave}
      assert Config.normalize([]) == %{backend: nil}
      assert Config.normalize(nil) == %{backend: nil}
    end

    test "to_keyword/1 is normalize/1's inverse, in the strings TOML can hold" do
      for backend <- [nil | Config.backends()] do
        config = %{backend: backend}
        persisted = Config.to_keyword(config)

        assert Enum.all?(persisted, fn {_key, value} -> is_binary(value) end)
        assert Config.normalize(persisted) == config
      end
    end

    test "an unknown backend or key refuses the load by name" do
      assert_raise ArgumentError, ~r/unknown backend: "google".*apple_maps, brave/s, fn ->
        Config.normalize(%{"backend" => "google"})
      end

      assert_raise ArgumentError, ~r/unknown key\(s\): country/, fn ->
        Config.normalize(%{"backend" => "brave", "country" => "US"})
      end
    end
  end

  describe "the settings file and the search section" do
    setup do
      home = System.get_env("FERMIX_HOME")
      core = Map.new(@core_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)

      Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
      SecretWriterStub.reset()
      tmp = SafeRm.make_tmp_dir!("place_search_backend_home")
      System.put_env("FERMIX_HOME", tmp)
      :ok = RestartState.record_persisted_baseline()

      on_exit(fn ->
        Enum.each(core, fn {key, value} -> restore(key, value) end)
        SecretWriterStub.reset()

        case home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        SafeRm.rm_rf!(tmp)
        :ok = RestartState.record_persisted_baseline()
      end)

      Application.put_env(:fermix_core, :tools, web_search: [backend: :duckduckgo])
      :ok
    end

    # AGENTS.md, Config round-trips: seeded with the shape the writer leaves in
    # application environment (an atom), saved by an unrelated write, loaded
    # back, and normalized to the same choice.
    test "a backend in its normalized app-env shape survives save then load" do
      Application.put_env(:fermix_core, :tools,
        web_search: [backend: :duckduckgo],
        place_search: [backend: :brave]
      )

      assert {:ok, _result} = Settings.apply("memory", %{"review_interval_hours" => 6})
      assert {:ok, reloaded} = ConfigStore.load_runtime_config()

      tools = reloaded |> Map.get(:fermix_core, []) |> Keyword.get(:tools, [])
      assert tools[:place_search] == [backend: "brave"]
      assert Config.normalize(tools[:place_search]) == %{backend: :brave}
    end

    test "the place search row writes the backend, and it reads back as written" do
      assert {:ok, result} =
               Settings.apply("web_search", %{"place_search_backend" => "brave"}, macos?: true)

      assert result["applied"] == ["place_search_backend"]
      assert Config.current() == %{backend: :brave}
      assert %{"value" => "brave"} = row("place_search_backend", true)

      assert {:ok, reloaded} = ConfigStore.load_runtime_config()
      assert reloaded.fermix_core[:tools][:place_search] == [backend: "brave"]
    end

    test "unset, the row shows the platform's default as the value in force" do
      assert %{"value" => "apple_maps"} = row("place_search_backend", true)
      assert %{"value" => "brave"} = row("place_search_backend", false)
    end

    test "a Mac offers both backends and Linux offers Brave alone" do
      mac = row("place_search_backend", true)
      linux = row("place_search_backend", false)

      assert mac["label"] == "Place search"

      assert Enum.map(mac["options"], &{&1["value"], &1["label"], &1["hint"]}) ==
               [{"apple_maps", "Apple Maps", "Needs no key"}, {"brave", "Brave", nil}]

      assert Enum.map(linux["options"], & &1["value"]) == ["brave"]
    end

    test "Linux refuses Apple Maps in the row's own sentence, and writes nothing" do
      assert {:error, {:invalid_params, "place_search_backend", sentence}} =
               Settings.apply("web_search", %{"place_search_backend" => "apple_maps"},
                 macos?: false
               )

      assert sentence == "This setting takes one of its published values."
      assert Config.current() == %{backend: nil}
    end

    test "the Brave key row stands whenever web or place search uses Brave" do
      cases = [
        {:duckduckgo, nil, true, []},
        {:duckduckgo, :brave, true, [{"brave_api_key", "Powers place search."}]},
        {:duckduckgo, nil, false, [{"brave_api_key", "Powers place search."}]},
        {:brave, :apple_maps, true, [{"brave_api_key", nil}]},
        {:brave, :brave, true, [{"brave_api_key", "Also powers place search."}]},
        {:tavily, :brave, true,
         [{"tavily_api_key", nil}, {"brave_api_key", "Powers place search."}]}
      ]

      for {web, place, macos?, expected} <- cases do
        place_search = if place, do: [backend: place], else: []

        Application.put_env(:fermix_core, :tools,
          web_search: [backend: web],
          place_search: place_search
        )

        secrets =
          macos?
          |> section_rows()
          |> Enum.filter(&(&1["kind"] == "secret"))
          |> Enum.map(&{&1["key"], &1["footer"]})

        assert secrets == expected, "web #{web}, place #{inspect(place)}, macos? #{macos?}"
      end
    end
  end

  defp section_rows(macos?) do
    {:ok, %{"rows" => rows}} = Settings.get("web_search", macos?: macos?)
    rows
  end

  defp row(key, macos?),
    do: Enum.find(section_rows(macos?), &(&1["key"] == key)) || flunk("no #{key} row")

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
