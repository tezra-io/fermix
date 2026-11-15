defmodule FermixCore.Tools.PlaceSearch.BackendTest do
  @moduledoc """
  The one place search backend choice (M72 §14.1, M89 D13): the resolver per
  platform and home, with the platform and the computers' records named; the
  section's normalizer and its inverse; the save then load round trip; and
  the settings rows that offer it, per host.

  `async: false`: the settings cases write a settings file under their own
  `FERMIX_HOME` and read and restore the global sections they touch.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Computers.Store
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixCore.Tools.PlaceSearch.Backend
  alias FermixCore.Tools.PlaceSearch.Brave
  alias FermixCore.Tools.PlaceSearch.Computer
  alias FermixCore.Tools.PlaceSearch.Config
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @core_keys [:tools, :memory, :secret_writer]
  @mac_app %{profile: :app_engine, os: :darwin}
  @mac_checkout %{profile: :source, os: :darwin}
  @brew_mac %{profile: :standalone_cli, os: :darwin}
  @brew_linux %{profile: :standalone_cli, os: :linux}
  @linux %{profile: :linux_package_cli, os: :linux}
  @linux_checkout %{profile: :source, os: :linux}
  @version "1.2.3"
  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @loft "c4a71e93-2b5d-4f08-9e6a-3d7b1f0c5a82"
  @places_on %{id: "places", state: :on, sentence: nil, detail: nil}
  @places_off %{id: "places", state: :off, sentence: "Waiting for you to review.", detail: nil}
  @files_on %{id: "files", state: :on, sentence: nil, detail: nil}

  # The computers' records as `Computers.Store.read_all/1` answers them: each
  # the latest offers its computer sent, and its engine version.
  defp records(entries), do: Map.new(entries)
  defp record(offers, version \\ @version), do: %{engine_version: version, offers: offers}

  # The home's computers as `Computers.fetch/1` joins them: a primary whose
  # link lists each record's computer, none connected.
  defp linked(records) do
    rows =
      for {id, _record} <- records,
          do: %{
            device_id: id,
            name: "Mac #{String.slice(id, 0, 4)}",
            platform: "macos",
            last_seen: ~U[2031-06-02 09:00:00Z],
            backups: true,
            connected: false,
            since: nil
          }

    [role: :primary, rows: fn -> {:ok, rows} end, live: %{}, records: records, version: @version]
  end

  # A home whose Mac's latest report offers places.
  defp mac_offers_places, do: linked(records([{@studio, record([@files_on, @places_on])}]))

  defp no_computers, do: linked(%{})

  describe "resolve/2" do
    # The build decides, never the helper file: the Mac app's engine carries
    # the helper, a Mac checkout builds it, and the Homebrew and Linux builds
    # are made off a Mac and carry none (M72 §14.1).
    test "unset, the build decides: Apple Maps where it carries the helper, Brave elsewhere" do
      for host <- [@mac_app, @mac_checkout] do
        assert Backend.resolve(%{backend: nil}, host: host) ==
                 %{name: :apple_maps, module: AppleMaps, source: :build_default}
      end

      for host <- [@brew_mac, @brew_linux, @linux, @linux_checkout] do
        assert Backend.resolve(%{backend: nil}, [host: host] ++ no_computers()) ==
                 %{name: :brave, module: Brave, source: :build_default},
               "#{inspect(host)} did not default to Brave"
      end
    end

    test "a configured backend wins on every build and home, and says so" do
      for host <- [@mac_app, @brew_mac, @linux],
          backend <- [:apple_maps, :computer, :brave],
          computers <- [no_computers(), mac_offers_places()] do
        assert %{name: ^backend, source: :configured} =
                 Backend.resolve(%{backend: backend}, [host: host] ++ computers)
      end
    end

    # M89 D13 A: helper or not, a computer offering places or not, an explicit
    # setting or not, and an offer the latest report no longer makes.
    test "unset, a build without the helper uses a Mac of the home that offers places" do
      for host <- [@brew_mac, @brew_linux, @linux, @linux_checkout] do
        assert Backend.resolve(%{backend: nil}, [host: host] ++ mac_offers_places()) ==
                 %{name: :computer, module: Computer, source: :linked_computer},
               "#{inspect(host)} did not use the Mac"

        assert %{name: :brave, source: :build_default} =
                 Backend.resolve(%{backend: nil}, [host: host] ++ no_computers())
      end

      # The build's own helper comes first: a Mac app never asks another Mac.
      for host <- [@mac_app, @mac_checkout] do
        assert %{name: :apple_maps, source: :build_default} =
                 Backend.resolve(%{backend: nil}, [host: host] ++ mac_offers_places())
      end
    end

    test "only a latest report with places on counts, from a computer this server serves" do
      # A stored offer from an engine that has since dropped it is not in its
      # latest report; one switched off, or one past the version window, is
      # no offer either.
      for records <- [
            records([{@studio, record([@files_on])}]),
            records([{@studio, record([@files_on, @places_off])}]),
            records([{@studio, record([@places_on], "0.1.0")}]),
            records([{@studio, record([@places_on], nil)}])
          ] do
        opts = [host: @linux] ++ linked(records)

        assert %{name: :brave} = Backend.resolve(%{backend: nil}, opts),
               "#{inspect(records)} counted as offering places"
      end

      # One of two computers is enough, connected or not: the record holds no
      # session.
      two = records([{@loft, record([@files_on])}, {@studio, record([@places_on])}])
      opts = [host: @linux] ++ linked(two)
      assert %{name: :computer} = Backend.resolve(%{backend: nil}, opts)

      # The link's rows decide which records are the home's computers: one
      # its link no longer lists is none.
      gone = Keyword.put(linked(two), :rows, fn -> {:ok, []} end)
      assert %{name: :brave} = Backend.resolve(%{backend: nil}, [host: @linux] ++ gone)
    end

    # AGENTS rule 12: computers that cannot be read are never taken for none.
    test "computers that cannot be read resolve to a named refusal, never to Brave" do
      for seams <- [
            Keyword.put(mac_offers_places(), :rows, fn -> {:error, :not_running} end),
            mac_offers_places() |> Keyword.delete(:records) |> Keyword.put(:home, bad_home())
          ] do
        resolution = Backend.resolve(%{backend: nil}, [host: @linux] ++ seams)
        assert resolution == %{name: :computer, module: Computer, source: :computers_unknown}

        assert {:error, "provider_error: Fermix cannot tell" <> _rest} =
                 Backend.ready(resolution, seams)
      end
    end

    test "a home with no computer record asks the link nothing" do
      seams = Keyword.put(no_computers(), :rows, fn -> raise "the link was asked" end)
      assert %{name: :brave} = Backend.resolve(%{backend: nil}, [host: @linux] ++ seams)
    end

    test "a build offers Apple Maps here only where it carries the helper, a Mac elsewhere" do
      assert Backend.available(@mac_app) == [:apple_maps, :brave]
      assert Backend.available(@mac_checkout) == [:apple_maps, :brave]

      for host <- [@brew_mac, @brew_linux, @linux, @linux_checkout] do
        assert Backend.available(host) == [:computer, :brave], "#{inspect(host)}"
      end
    end
  end

  describe "ready/2" do
    test "Apple Maps on a build without the helper refuses, naming the build, before any look" do
      for {host, build} <- [
            {@brew_mac, "the standalone Fermix that Homebrew installs"},
            {@linux, "the Linux package"},
            {@linux_checkout, "a source build off a Mac"}
          ] do
        resolution = Backend.resolve(%{backend: :apple_maps}, host: host)

        assert {:error, reason} = Backend.ready(resolution, host: host, helper_path: "/bin/sh")

        assert reason ==
                 "provider_error: this build (#{build}) carries no Apple Maps helper; the " <>
                   "Fermix Mac app does. Set [fermix_core.tools.place_search] backend = " <>
                   ~s("brave" to search through Brave)
      end
    end

    test "the Mac app's engine is ready only with its helper, and a missing one says reinstall" do
      resolution = Backend.resolve(%{backend: nil}, host: @mac_app)
      assert resolution.name == :apple_maps

      assert :ok = Backend.ready(resolution, host: @mac_app, helper_path: "/bin/sh")

      assert {:error, reason} =
               Backend.ready(resolution, host: @mac_app, helper_path: "/nonexistent/fermix-maps")

      assert reason =~ "provider_error: the Apple Maps helper (fermix-maps) is missing"
      assert reason =~ "reinstall"
    end

    test "a Mac of the home is ready while one offers places, connected or not" do
      resolution = Backend.resolve(%{backend: :computer}, host: @linux)

      assert :ok = Backend.ready(resolution, mac_offers_places())
      assert {:error, reason} = Backend.ready(resolution, no_computers())

      assert reason ==
               "provider_error: no computer of this home offers Apple Maps; link a Mac with the " <>
                 "Fermix app to this home, or set [fermix_core.tools.place_search] backend = " <>
                 ~s("brave" to search through Brave)
    end

    test "Brave is ready only with a resolvable key" do
      resolution = Backend.resolve(%{backend: :brave}, host: @mac_app)

      assert :ok = Backend.ready(resolution, brave_api_key: "brave-secret")
      assert {:error, "auth_failed: missing Brave API key"} = Backend.ready(resolution, [])

      assert {:error, "auth_failed: missing Brave API key"} =
               Backend.ready(resolution, brave_api_key: "@keyring")
    end
  end

  describe "Config" do
    test "the file's strings and the environment's atoms normalize to one choice" do
      assert Config.normalize(%{"backend" => "apple_maps"}) == %{backend: :apple_maps}
      assert Config.normalize(%{"backend" => "computer"}) == %{backend: :computer}
      assert Config.normalize(backend: :computer) == %{backend: :computer}
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
      assert_raise ArgumentError,
                   ~r/unknown backend: "google".*apple_maps, computer, brave/s,
                   fn ->
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
      for backend <- [:brave, :computer] do
        Application.put_env(:fermix_core, :tools,
          web_search: [backend: :duckduckgo],
          place_search: [backend: backend]
        )

        assert {:ok, _result} = Settings.apply("memory", %{"review_interval_hours" => 6})
        assert {:ok, reloaded} = ConfigStore.load_runtime_config()

        tools = reloaded |> Map.get(:fermix_core, []) |> Keyword.get(:tools, [])
        assert tools[:place_search] == [backend: Atom.to_string(backend)]
        assert Config.normalize(tools[:place_search]) == %{backend: backend}
      end
    end

    test "the place search row writes the backend, and it reads back as written" do
      assert {:ok, result} =
               Settings.apply("web_search", %{"place_search_backend" => "brave"}, host: @mac_app)

      assert result["applied"] == ["place_search_backend"]
      assert Config.current() == %{backend: :brave}
      assert %{"value" => "brave"} = row("place_search_backend", @mac_app)

      assert {:ok, reloaded} = ConfigStore.load_runtime_config()
      assert reloaded.fermix_core[:tools][:place_search] == [backend: "brave"]
    end

    test "unset, the row shows the home's default as the value in force" do
      assert %{"value" => "apple_maps"} = row("place_search_backend", @mac_app)
      assert %{"value" => "brave"} = row("place_search_backend", @brew_mac, no_computers())
      assert %{"value" => "brave"} = row("place_search_backend", @linux, no_computers())

      # A server's home whose Mac offers places publishes that it searches there.
      assert %{"value" => "computer"} =
               row("place_search_backend", @linux, mac_offers_places())
    end

    test "the Mac app offers Apple Maps and Brave; Homebrew and Linux a Mac of the home and Brave" do
      mac = row("place_search_backend", @mac_app)

      assert mac["label"] == "Place search"

      assert Enum.map(mac["options"], &{&1["value"], &1["label"], &1["hint"]}) ==
               [{"apple_maps", "Apple Maps", "Needs no key"}, {"brave", "Brave", nil}]

      for host <- [@brew_mac, @linux] do
        options = row("place_search_backend", host)["options"]

        assert Enum.map(options, &{&1["value"], &1["label"], &1["hint"]}) == [
                 {"computer", "Apple Maps on your Mac", "Needs a Mac with the Fermix app"},
                 {"brave", "Brave", nil}
               ],
               "#{inspect(host)}"
      end
    end

    test "the row writes a Mac of the home on a build without the helper, and reads it back" do
      assert {:ok, %{"applied" => ["place_search_backend"]}} =
               Settings.apply("web_search", %{"place_search_backend" => "computer"},
                 host: @linux,
                 computers_opts: no_computers()
               )

      assert Config.current() == %{backend: :computer}
      assert {:ok, reloaded} = ConfigStore.load_runtime_config()
      assert reloaded.fermix_core[:tools][:place_search] == [backend: "computer"]
    end

    test "a build without the helper refuses Apple Maps in the row's own sentence" do
      for host <- [@brew_mac, @linux] do
        assert {:error, {:invalid_params, "place_search_backend", sentence}} =
                 Settings.apply("web_search", %{"place_search_backend" => "apple_maps"},
                   host: host,
                   computers_opts: no_computers()
                 )

        assert sentence == "This setting takes one of its published values."
        assert Config.current() == %{backend: nil}
      end
    end

    test "the Brave key row stands whenever web or place search uses Brave" do
      cases = [
        {:duckduckgo, nil, @mac_app, []},
        {:duckduckgo, :brave, @mac_app, [{"brave_api_key", "Powers place search."}]},
        {:duckduckgo, nil, @linux, [{"brave_api_key", "Powers place search."}]},
        {:duckduckgo, nil, @brew_mac, [{"brave_api_key", "Powers place search."}]},
        {:brave, :apple_maps, @mac_app, [{"brave_api_key", nil}]},
        {:brave, :brave, @mac_app, [{"brave_api_key", "Also powers place search."}]},
        {:tavily, :brave, @mac_app,
         [{"tavily_api_key", nil}, {"brave_api_key", "Powers place search."}]}
      ]

      for {web, place, host, expected} <- cases do
        place_search = if place, do: [backend: place], else: []

        Application.put_env(:fermix_core, :tools,
          web_search: [backend: web],
          place_search: place_search
        )

        secrets =
          host
          |> section_rows()
          |> Enum.filter(&(&1["kind"] == "secret"))
          |> Enum.map(&{&1["key"], &1["footer"]})

        assert secrets == expected, "web #{web}, place #{inspect(place)}, #{inspect(host)}"
      end
    end
  end

  defp section_rows(host, computers \\ no_computers()) do
    {:ok, %{"rows" => rows}} = Settings.get("web_search", host: host, computers_opts: computers)
    rows
  end

  defp row(key, host, computers \\ no_computers()),
    do: Enum.find(section_rows(host, computers), &(&1["key"] == key)) || flunk("no #{key} row")

  defp bad_home do
    home = SafeRm.make_tmp_dir!("place_search_bad_records")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    dir = Store.dir(home)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{@studio}.json"), "{}")
    home
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
