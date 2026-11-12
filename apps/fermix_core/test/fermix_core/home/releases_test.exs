defmodule FermixCore.Home.ReleasesTest do
  # M97 §3.4, the server leads: the release table fermix.ai serves gains
  # `app <engine_version> <system> <app_version>` rows and (D16)
  # `home_format <engine_version> <home_format>` rows, and a server takes the
  # newest release whose home a published app reads for every system that
  # keeps its backup copies. test/fixtures/release_tables is a byte copy of
  # tests/fixtures/release-tables in tezra-io/fermix-site, whose parser reads
  # the same tables; both suites check the copy's combined digest. The site
  # refuses every row it does not know; this reader ignores one, as the
  # installer does, so a newer table never stops an older server.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Releases

  @fixtures Path.expand("../../fixtures/release_tables", __DIR__)
  # sha256 over each fixture, in name order, as "<name>\n<contents>"; the
  # site's test states the same constant.
  @shared_fixtures_sha256 "18ebacc769950f683b51bb443f97234a8eabd956528c6099d7fb9dea90461736"

  # What apps.txt lists, in its order.
  @apps [
    %{engine: "4.1.0", system: :macos, version: "7.3.0"},
    %{engine: "4.0.3", system: :macos, version: "7.2.1"},
    %{engine: "4.0.3", system: :macos, version: "7.2.0"},
    %{engine: "4.0.3", system: :linux, version: "2.7.0"}
  ]

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp table!(name) do
    assert {:ok, table} = Releases.parse(fixture(name))
    table
  end

  defp header(latest), do: "format 1\nlatest #{latest}\n"

  # The engine that runs, writing the home format given (this engine's own
  # when none is).
  defp running(version, format \\ 1), do: %{engine_version: version, home_format: format}
  defp digest(version, file), do: "#{version} #{String.duplicate("e", 64)} #{file}\n"

  describe "parse/1" do
    test "the shared fixtures are the site's copy, byte for byte" do
      names = @fixtures |> File.ls!() |> Enum.sort()
      hashed = :crypto.hash(:sha256, Enum.map(names, &[&1, "\n", fixture(&1)]))

      assert Base.encode16(hashed, case: :lower) == @shared_fixtures_sha256, inspect(names)
    end

    test "reads latest, each release's files and the app rows" do
      table = table!("apps.txt")

      assert table.latest == "4.2.0"
      assert table.releases |> Map.keys() |> Enum.sort() == ["4.0.3", "4.1.0", "4.2.0"]
      assert map_size(table.releases["4.0.3"]) == 9
      assert table.releases["4.0.3"]["fermix_always_on.sh"] =~ ~r/\A[0-9a-f]{64}\z/
      assert table.apps == @apps
    end

    test "a table with no app rows has no apps" do
      table = table!("no_apps.txt")

      assert table.apps == []
      assert Map.keys(table.releases) == Map.keys(table!("apps.txt").releases)
    end

    test "rows it does not know are ignored, as install.sh ignores them" do
      # A channel row, and an app row for a system no computer of a home
      # runs: the same table as without them. unknown_rows.txt also carries
      # a home_format row, which this reader now knows (M97 D16).
      assert table!("unknown_rows.txt") == %{table!("apps.txt") | formats: %{"4.2.0" => 3}}
      assert table!("app_other_system.txt") == table!("apps.txt")
    end

    # M97 D16: the home format each engine release reads and writes, once a
    # release; one with none is from before home formats.
    test "reads the home format rows" do
      assert table!("home_formats.txt").formats == %{"4.1.0" => 1, "4.2.0" => 1}
      assert table!("apps.txt").formats == %{}
    end

    test "a malformed home format row, or formats out of order, refuse the table by name" do
      row = ~s(is not "home_format <engine_version> <home_format>")

      cases = %{
        "home_format_not_a_number.txt" => ~s("home_format 4.1.0 one" #{row}),
        "home_format_missing_field.txt" => ~s("home_format 4.1.0" #{row}),
        "home_format_listed_twice.txt" => "the home format of 4.1.0 is listed twice",
        "home_format_not_pinned.txt" =>
          "a home format is given for engine 4.3.0, which the table does not pin",
        "home_format_gap.txt" => "4.1.0 names no home format, though the older 4.0.3 does",
        "home_format_falls.txt" => "4.2.0's home format 1 is below the older 4.1.0's 2"
      }

      for {name, reason} <- cases do
        assert Releases.parse(fixture(name)) == {:error, {:invalid_table, reason}}, name
      end

      for format <- ["0", "01", "-1", "1.0"] do
        text = header("4.1.0") <> digest("4.1.0", "fermix_linux_x86_64")
        bad = "home_format 4.1.0 #{format}"

        assert Releases.parse(text <> bad <> "\n") ==
                 {:error, {:invalid_table, ~s("#{bad}" #{row})}}
      end
    end

    test "a malformed app row refuses the table by name" do
      app_row = ~s(is not "app <engine_version> <system> <app_version>")

      cases = %{
        "app_engine_not_pinned.txt" =>
          "macos app 7.4.0 carries engine 4.3.0, which the table does not pin",
        "app_engine_not_a_version.txt" => ~s("app 4.1 macos 7.3.0" #{app_row}),
        "app_version_not_a_version.txt" => ~s("app 4.1.0 macos v7.3.0" #{app_row}),
        "app_missing_field.txt" => ~s("app 4.1.0 macos" #{app_row}),
        "app_extra_field.txt" => ~s("app 4.1.0 macos 7.3.0 universal" #{app_row}),
        "app_listed_twice.txt" => "macos app 7.3.0 is listed twice"
      }

      for {name, reason} <- cases do
        assert Releases.parse(fixture(name)) == {:error, {:invalid_table, reason}}, name
      end
    end

    test "an app release carries one engine: a second row for it is refused whichever engine it names" do
      text =
        header("4.1.0") <>
          digest("4.1.0", "fermix_linux_x86_64") <>
          digest("4.0.3", "fermix_linux_x86_64") <>
          "app 4.1.0 linux 2.8.0\napp 4.0.3 linux 2.8.0\n"

      assert Releases.parse(text) == {:error, {:invalid_table, "linux app 2.8.0 is listed twice"}}
    end

    test "a malformed table, header or digest row is refused by name" do
      good = header("4.1.0") <> digest("4.1.0", "fermix_linux_x86_64")
      row = "4.1.0 #{String.duplicate("e", 64)} fermix_linux_x86_64"

      cases = %{
        String.trim_trailing(good) => "does not end with a newline",
        "format 2\nlatest 4.1.0\n" => ~s(the first line is not "format 1"),
        "" => "does not end with a newline",
        "\n" => ~s(the first line is not "format 1"),
        "format 1\n#{row}\n" => ~s(the second line is not "latest <version>"),
        "format 1\nlatest 4.1\n#{row}\n" => ~s(the second line is not "latest <version>"),
        header("4.1.0") => "lists no release",
        (header("4.2.0") <> "#{row}\n") =>
          "latest is 4.2.0, not the highest listed release 4.1.0",
        (good <> "#{row}\n") => "fermix_linux_x86_64 of 4.1.0 is listed twice",
        (good <> "4.1.0 #{String.duplicate("E", 64)} fermix_macos_x86_64\n") =>
          ~s("4.1.0 #{String.duplicate("E", 64)} fermix_macos_x86_64" is not "<version> <sha256> <file>"),
        (good <> "4.1.0 #{String.duplicate("e", 64)}\n") =>
          ~s("4.1.0 #{String.duplicate("e", 64)}" is not "<version> <sha256> <file>"),
        (good <> "4.1.0 #{String.duplicate("e", 64)} fermix_macos_x86_64 4096\n") =>
          ~s("4.1.0 #{String.duplicate("e", 64)} fermix_macos_x86_64 4096" is not "<version> <sha256> <file>"),
        (good <> "latest 4.1.0\n") => ~s("latest 4.1.0" repeats the latest line),
        (good <> "format 1\n") => ~s("format 1" repeats the format line)
      }

      for {text, reason} <- cases do
        assert Releases.parse(text) == {:error, {:invalid_table, reason}}, inspect(text)
      end
    end

    test "versions are compared as numbers, so 4.10.0 is the latest above 4.9.0" do
      text =
        header("4.10.0") <>
          digest("4.9.0", "fermix_linux_x86_64") <> digest("4.10.0", "fermix_linux_x86_64")

      assert {:ok, %Releases{latest: "4.10.0"}} = Releases.parse(text)

      assert Releases.parse(String.replace(text, "latest 4.10.0", "latest 4.9.0")) ==
               {:error,
                {:invalid_table, "latest is 4.9.0, not the highest listed release 4.10.0"}}
    end
  end

  describe "restorable?/3" do
    test "whether a published app for a system reads a home, by format or by version" do
      table = table!("home_formats.txt")

      assert Releases.restorable?(table, :macos, %{home_format: 1, engine_version: "9.0.0"})
      refute Releases.restorable?(table, :macos, %{home_format: 2, engine_version: "4.2.0"})
      assert Releases.restorable?(table, :macos, %{home_format: nil, engine_version: "3.0.0"})

      # The Linux app carries 4.0.3, from before home formats: by version.
      assert Releases.restorable?(table, :linux, %{home_format: 1, engine_version: "4.0.3"})
      refute Releases.restorable?(table, :linux, %{home_format: 1, engine_version: "4.1.0"})

      refute Releases.restorable?(table, :unknown, %{home_format: 1, engine_version: "1.0.0"})
    end
  end

  describe "eligible/3" do
    test "with no backup systems the latest release is eligible" do
      assert Releases.eligible(table!("apps.txt"), running("4.0.3"), []) ==
               %{eligible: "4.2.0", held: nil, ahead_of_apps: false}

      assert Releases.eligible(table!("no_apps.txt"), running("4.0.3"), []) ==
               %{eligible: "4.2.0", held: nil, ahead_of_apps: false}
    end

    test "one system with its app published: the newest release that app carries" do
      assert Releases.eligible(table!("apps.txt"), running("4.0.3"), [:macos]) ==
               %{
                 eligible: "4.1.0",
                 held: %{version: "4.2.0", waits_for: [:macos]},
                 ahead_of_apps: false
               }
    end

    test "a missing macOS app holds the release" do
      # The shape of the table served today: no app rows yet, so every
      # release waits, and the server is not called ahead of apps the table
      # says nothing about.
      assert Releases.eligible(table!("no_apps.txt"), running("4.0.3"), [:macos]) ==
               %{
                 eligible: nil,
                 held: %{version: "4.2.0", waits_for: [:macos]},
                 ahead_of_apps: false
               }

      # A table with app rows, none of them for macOS.
      linux_only = only_apps(table!("apps.txt"), :linux)

      assert Releases.eligible(linux_only, running("4.0.3"), [:macos]) ==
               %{
                 eligible: nil,
                 held: %{version: "4.2.0", waits_for: [:macos]},
                 ahead_of_apps: true
               }
    end

    test "two systems where one lags: the newest release both apps carry" do
      # 4.1.0 has its macOS app and waits for Linux; 4.0.3 has both.
      result = %{
        eligible: "4.0.3",
        held: %{version: "4.2.0", waits_for: [:macos, :linux]},
        ahead_of_apps: false
      }

      assert Releases.eligible(table!("apps.txt"), running("4.0.3"), [:macos, :linux]) == result

      assert Releases.eligible(table!("apps.txt"), running("4.0.3"), [:linux, :macos, :linux]) ==
               result

      assert Releases.eligible(table!("apps.txt"), running("4.0.3"), [:linux]) ==
               %{
                 eligible: "4.0.3",
                 held: %{version: "4.2.0", waits_for: [:linux]},
                 ahead_of_apps: false
               }
    end

    test "running ahead of the apps: nothing is eligible, and nothing below it ever is" do
      # Installed past the gate: no app carries 4.2.0 yet.
      assert Releases.eligible(table!("apps.txt"), running("4.2.0"), [:macos]) ==
               %{eligible: nil, held: nil, ahead_of_apps: true}

      # 4.1.0 waits for Linux, and 4.0.3, which both carry, is below it.
      assert Releases.eligible(table!("apps.txt"), running("4.1.0"), [:macos, :linux]) ==
               %{
                 eligible: nil,
                 held: %{version: "4.2.0", waits_for: [:macos, :linux]},
                 ahead_of_apps: true
               }

      assert Releases.eligible(table!("apps.txt"), running("9.0.0"), []) ==
               %{eligible: nil, held: nil, ahead_of_apps: false}
    end

    test "running the eligible release itself: it stays" do
      assert Releases.eligible(table!("apps.txt"), running("4.1.0"), [:macos]) ==
               %{
                 eligible: "4.1.0",
                 held: %{version: "4.2.0", waits_for: [:macos]},
                 ahead_of_apps: false
               }
    end

    test "ahead of the apps only above the newest engine some listed system's app carries" do
      table = table!("apps.txt")

      # Below the oldest app row: every app carries a newer engine.
      assert Releases.eligible(table, running("3.9.0"), [:macos, :linux]) ==
               %{
                 eligible: "4.0.3",
                 held: %{version: "4.2.0", waits_for: [:macos, :linux]},
                 ahead_of_apps: false
               }

      # The newest macOS app carries 4.1.0, the newest Linux app 4.0.3.
      assert %{ahead_of_apps: false} = Releases.eligible(table, running("4.1.0"), [:macos])
      assert %{ahead_of_apps: true} = Releases.eligible(table, running("4.1.0"), [:macos, :linux])
      assert %{ahead_of_apps: true} = Releases.eligible(table, running("4.1.0"), [:linux])
      assert %{ahead_of_apps: false} = Releases.eligible(table, running("4.0.3"), [:linux])

      # The table served today has no app rows: never ahead.
      assert %{ahead_of_apps: false} =
               Releases.eligible(table!("no_apps.txt"), running("4.2.0"), [:macos, :linux])
    end

    test "an empty table makes nothing eligible" do
      assert Releases.eligible(%Releases{}, running("4.0.3"), []) == %{
               eligible: nil,
               held: nil,
               ahead_of_apps: false
             }

      assert Releases.eligible(%Releases{}, running("4.0.3"), [:macos]) == %{
               eligible: nil,
               held: nil,
               ahead_of_apps: false
             }
    end

    test "a computer whose system is not known holds every release above running" do
      table = table!("apps.txt")

      assert Releases.eligible(table, running("4.0.3"), [:unknown]) ==
               %{
                 eligible: "4.0.3",
                 held: %{version: "4.2.0", waits_for: [:unknown]},
                 ahead_of_apps: true
               }

      # Listed with known systems, in any order: it waits beside them.
      assert Releases.eligible(table, running("4.1.0"), [:unknown, :macos]) ==
               %{
                 eligible: "4.1.0",
                 held: %{version: "4.2.0", waits_for: [:macos, :unknown]},
                 ahead_of_apps: true
               }

      # Even a release every known app carries, as both carry 4.0.3, which
      # would be eligible without it.
      assert %{eligible: "4.0.3"} = Releases.eligible(table, running("3.9.0"), [:macos, :linux])

      assert Releases.eligible(table, running("3.9.0"), [:linux, :unknown, :macos]) ==
               %{
                 eligible: nil,
                 held: %{version: "4.2.0", waits_for: [:macos, :linux, :unknown]},
                 ahead_of_apps: true
               }

      # Running a release the table does not list: nothing is eligible.
      assert Releases.eligible(table, running("3.9.0"), [:unknown]) ==
               %{
                 eligible: nil,
                 held: %{version: "4.2.0", waits_for: [:unknown]},
                 ahead_of_apps: true
               }

      # Running the newest release: it stays, and nothing is held.
      assert %{eligible: "4.2.0", held: nil} =
               Releases.eligible(table, running("4.2.0"), [:unknown])

      # A table from before app rows says nothing about being ahead.
      assert Releases.eligible(table!("no_apps.txt"), running("4.0.3"), [:unknown]) ==
               %{
                 eligible: "4.0.3",
                 held: %{version: "4.2.0", waits_for: [:unknown]},
                 ahead_of_apps: false
               }
    end

    # M97 D16: an app reads the home a release writes when its engine's home
    # format is at or above that release's, so a release that keeps the
    # format is eligible on the apps already published.
    test "a release in a home format a published app reads is eligible without an app of its own" do
      table = table!("home_formats.txt")

      # No macOS app carries 4.2.0, and the one carrying 4.1.0 reads its home.
      assert Releases.eligible(table, running("4.1.0"), [:macos]) ==
               %{eligible: "4.2.0", held: nil, ahead_of_apps: false}

      # The Linux app carries 4.0.3, from before home formats: it reads by
      # version, so only its own release's home or an older one's.
      assert Releases.eligible(table, running("4.0.3"), [:macos, :linux]) ==
               %{
                 eligible: "4.0.3",
                 held: %{version: "4.2.0", waits_for: [:linux]},
                 ahead_of_apps: false
               }

      assert %{ahead_of_apps: true} = Releases.eligible(table, running("4.1.0"), [:linux])
    end

    test "a release that raises the home format waits for an app that reads it" do
      raised =
        fixture("home_formats.txt")
        |> String.replace("home_format 4.2.0 1", "home_format 4.2.0 2")

      assert {:ok, table} = Releases.parse(raised)

      assert Releases.eligible(table, running("4.1.0"), [:macos]) ==
               %{
                 eligible: "4.1.0",
                 held: %{version: "4.2.0", waits_for: [:macos]},
                 ahead_of_apps: false
               }

      # Running it past the gate: the macOS app cannot read the home it writes.
      assert %{eligible: nil, held: nil, ahead_of_apps: true} =
               Releases.eligible(table, running("4.2.0", 2), [:macos])
    end

    # With no home format rows every engine reads by version, so an app
    # carrying a newer engine reads an older release's home too.
    test "with no home format rows, an app carrying the release or a newer one reads it" do
      text =
        header("4.2.0") <>
          digest("4.2.0", "fermix_linux_x86_64") <>
          digest("4.1.0", "fermix_linux_x86_64") <>
          "app 4.2.0 macos 7.4.0\napp 4.1.0 linux 2.8.0\n"

      assert {:ok, table} = Releases.parse(text)

      # No macOS app carries 4.1.0 itself; the one carrying 4.2.0 reads it.
      assert Releases.eligible(table, running("4.1.0"), [:macos, :linux]) ==
               %{
                 eligible: "4.1.0",
                 held: %{version: "4.2.0", waits_for: [:linux]},
                 ahead_of_apps: false
               }
    end

    test "a running version or a system it does not know is refused loudly" do
      table = table!("apps.txt")

      assert_raise ArgumentError, ~r/running is not a MAJOR\.MINOR\.PATCH version: "4\.1"/, fn ->
        Releases.eligible(table, running("4.1"), [:macos])
      end

      assert_raise ArgumentError,
                   ~r/backup systems are :macos, :linux or :unknown, got: \[:windows\]/,
                   fn ->
                     Releases.eligible(table, running("4.1.0"), [:macos, :windows])
                   end

      assert_raise ArgumentError, ~r/got: \[nil\]/, fn ->
        Releases.eligible(table, running("4.1.0"), [nil])
      end

      assert_raise ArgumentError, ~r/got: \["macos"\]/, fn ->
        Releases.eligible(table, running("4.1.0"), ["macos"])
      end
    end
  end

  defp only_apps(table, system),
    do: %{table | apps: Enum.filter(table.apps, &(&1.system == system))}
end
