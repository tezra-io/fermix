defmodule FermixCore.Tools.PlaceSearch.AppleMapsTest do
  @moduledoc """
  The Apple Maps adapter against helper-output fixtures (M72 §14.3): a shell
  script stands in for `fermix-maps`, records the request line it was handed,
  prints a canned object and exits with a chosen status. On a Mac it is spawned
  through the real disclaim shim, as the helper is.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixTestSupport.SafeRm

  # A process-group kill lands at once, but the kernel reaps on its own
  # schedule: a bound for process work, never a sleep.
  @process_bound_ms 10_000

  # Raw fields as the helper prints them for a Suwanee search (the live run of
  # 2026-10-16), plus the shapes the adapter has to drop or rewrite.
  @taqueria %{
    "name" => "Tequila Mama Taqueria",
    "latitude" => 34.0555026,
    "longitude" => -84.0647238,
    "identifier" => "I15D3EC7F56AE8D5C",
    "url" => "https://tequilamama.com",
    "phone" => "+1 (678) 456-3131",
    "category" => "MKPOICategoryRestaurant",
    "address" => "340 Town Center Ave, Suwanee, GA  30024, United States"
  }
  @http_site %{
    "name" => "Beto's Tacos",
    "latitude" => 34.043542,
    "longitude" => -84.0541653,
    "identifier" => "I47957D91CD7E2F7B",
    "url" => "http://betostacos.com",
    "category" => "MKPOICategoryRestaurant"
  }

  setup do
    dir = SafeRm.make_tmp_dir!("apple-maps-adapter")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "spawn_plan/3" do
    test "macOS spawns the helper through the disclaim shim" do
      assert AppleMaps.spawn_plan("/priv/fermix-maps", {:unix, :darwin}, "/priv/disclaim") ==
               {:ok, {"/priv/disclaim", ["/priv/fermix-maps"]}}
    end

    test "macOS without the shim refuses, and never spawns undisclaimed" do
      assert {:error, reason} = AppleMaps.spawn_plan("/priv/fermix-maps", {:unix, :darwin}, nil)
      assert reason =~ "provider_error: macOS disclaim shim is not built"
    end

    test "another host spawns the helper directly" do
      assert AppleMaps.spawn_plan("/priv/fermix-maps", {:unix, :linux}, nil) ==
               {:ok, {"/priv/fermix-maps", []}}
    end
  end

  describe "the record (places/2, pure)" do
    test "a place becomes the M31 record with Apple's page and identifier" do
      assert {:ok, [place]} = AppleMaps.places([@taqueria], named())

      assert place == %{
               name: "Tequila Mama Taqueria",
               canonical_url: "https://tequilamama.com",
               source_url: "https://maps.apple.com/place?place-id=I15D3EC7F56AE8D5C",
               apple_place_id: "I15D3EC7F56AE8D5C",
               location: %{latitude: 34.0555026, longitude: -84.0647238},
               address: "340 Town Center Ave, Suwanee, GA 30024, United States",
               contact: %{telephone: "+1 (678) 456-3131"},
               categories: ["restaurant"]
             }
    end

    test "an HTTP site is dropped, never rewritten, and the place keeps Apple's page" do
      assert {:ok, [place]} = AppleMaps.places([@http_site], named())

      refute Map.has_key?(place, :canonical_url)
      assert place.source_url == "https://maps.apple.com/place?place-id=I47957D91CD7E2F7B"
    end

    test "a place with neither an identifier nor an HTTPS site, or with no name, is dropped" do
      no_page = @http_site |> Map.delete("identifier")
      no_name = @taqueria |> Map.delete("name")
      site_only = @taqueria |> Map.delete("identifier")

      assert {:ok, [kept]} = AppleMaps.places([no_page, no_name, site_only], named())
      assert kept.canonical_url == "https://tequilamama.com"
      refute Map.has_key?(kept, :source_url)
      refute Map.has_key?(kept, :apple_place_id)
    end

    test "rating, price, hours, description, cuisines and pictures are absent" do
      assert {:ok, [place]} = AppleMaps.places([@taqueria], named())

      for key <- [:rating, :price_range, :opening_hours, :description, :cuisines, :media] do
        refute Map.has_key?(place, key), "#{key} is not MapKit's to give"
      end
    end

    test "a category is one snake-case word" do
      for {raw, word} <- [
            {"MKPOICategoryRestaurant", "restaurant"},
            {"MKPOICategoryNationalPark", "national_park"},
            {"MKPOICategoryEVCharger", "ev_charger"},
            {"MKPOICategoryATM", "atm"}
          ] do
        assert {:ok, [place]} = AppleMaps.places([Map.put(@taqueria, "category", raw)], named())
        assert place.categories == [word]
      end
    end

    test "a category that is not an MKPOICategory name is a changed parser, not a guess" do
      assert {:error, "parser_changed: category" <> _rest} =
               AppleMaps.places([Map.put(@taqueria, "category", "restaurant")], named())
    end

    test "a multi-line address reads as one line" do
      address = "〒100-0005\n東京都千代田区\n丸の内1丁目9-1"

      assert {:ok, [place]} = AppleMaps.places([Map.put(@taqueria, "address", address)], named())
      assert place.address == "〒100-0005, 東京都千代田区, 丸の内1丁目9-1"
    end

    test "distance is great-circle from explicit coordinates, in the caller's units" do
      coordinates = %{query: "tacos", anchor: {:coordinates, 34.0515, -84.0713}}

      assert {:ok, [metric]} = AppleMaps.places([@taqueria], coordinates)
      assert metric.distance == %{value: 0.75, units: "km"}

      assert {:ok, [imperial]} =
               AppleMaps.places([@taqueria], Map.put(coordinates, :units, :imperial))

      assert imperial.distance == %{value: 0.47, units: "mi"}
    end

    test "a named area or an unanchored query has no distance" do
      for request <- [named(), %{query: "tacos"}] do
        assert {:ok, [place]} = AppleMaps.places([@taqueria], request)
        refute Map.has_key?(place, :distance)
      end
    end

    test "at most ten places, in MapKit's order" do
      raw = Enum.map(1..14, &Map.put(@taqueria, "name", "Place #{&1}"))

      assert {:ok, places} = AppleMaps.places(raw, named())
      assert Enum.map(places, & &1.name) == Enum.map(1..10, &"Place #{&1}")
    end

    test "a field of an unexpected type is a changed parser" do
      for {key, value} <- [
            {"name", 7},
            {"identifier", 7},
            {"url", true},
            {"latitude", "34"},
            {"phone", 1},
            {"address", []},
            {"category", 1}
          ] do
        assert {:error, "parser_changed: " <> _detail} =
                 AppleMaps.places([Map.put(@taqueria, key, value)], named()),
               "#{key} of the wrong type was accepted"
      end

      assert {:error, "parser_changed: " <> _} =
               AppleMaps.places([Map.delete(@taqueria, "longitude")], named())

      assert {:error, "parser_changed: " <> _} = AppleMaps.places(["a place"], named())
    end
  end

  describe "the one-shot spawn" do
    test "a named area travels as one request line on stdin, never on the command line", ctx do
      helper = fake_helper(ctx.dir, %{"places" => [@taqueria]}, 0)

      assert {:ok, [place], %{}} = AppleMaps.search(named(), helper_opts(helper))
      assert place.apple_place_id == "I15D3EC7F56AE8D5C"

      assert recorded_request(ctx.dir) == %{
               "query" => "tacos",
               "anchor" => %{"kind" => "location", "location" => "Suwanee, GA"}
             }

      assert recorded_args(ctx.dir) == []
    end

    test "coordinates carry their radius, the default when none was given", ctx do
      helper = fake_helper(ctx.dir, %{"places" => []}, 0)
      request = %{query: "tacos", anchor: {:coordinates, 34.05, -84.07}}

      assert {:ok, [], %{}} = AppleMaps.search(request, helper_opts(helper))

      assert recorded_request(ctx.dir)["anchor"] == %{
               "kind" => "coordinates",
               "latitude" => 34.05,
               "longitude" => -84.07,
               "radius_meters" => 5_000
             }

      assert {:ok, [], %{}} =
               AppleMaps.search(Map.put(request, :radius_meters, 1_500), helper_opts(helper))

      assert recorded_request(ctx.dir)["anchor"]["radius_meters"] == 1_500
    end

    test "a query with no anchor goes to MapKit as written", ctx do
      helper = fake_helper(ctx.dir, %{"places" => []}, 0)

      assert {:ok, [], %{}} =
               AppleMaps.search(%{query: "Eiffel Tower Paris"}, helper_opts(helper))

      assert recorded_request(ctx.dir)["anchor"] == %{"kind" => "query_only"}
    end

    test "each failure exit is its own tag, with the framework's words", ctx do
      for {status, tag} <- [
            {64, "provider_error"},
            {65, "invalid_location"},
            {66, "rate_limited"},
            {67, "network"},
            {68, "provider_error"},
            {69, "network"}
          ] do
        words = %{"error" => %{"message" => "MKErrorDomain #{status}: <b>The</b> operation"}}
        helper = fake_helper(ctx.dir, words, status)

        assert {:error, reason, %{}} = AppleMaps.search(named(), helper_opts(helper))
        assert String.starts_with?(reason, tag <> ": "), "exit #{status} read as #{reason}"
        assert reason =~ "(MKErrorDomain #{status}: The operation)"
      end
    end

    test "a throttled search is rate_limited and names the throttle", ctx do
      helper = fake_helper(ctx.dir, %{"error" => %{"message" => "GEOErrorDomain -3"}}, 66)

      assert {:error, "rate_limited: Apple Maps is throttling searches from this Mac" <> _, %{}} =
               AppleMaps.search(named(), helper_opts(helper))
    end

    test "a disclaim shim exit and an unknown exit are provider errors that say whose", ctx do
      for status <- [70, 71, 72, 74, 75] do
        helper = fake_helper(ctx.dir, "", status)

        assert {:error, reason, %{}} = AppleMaps.search(named(), helper_opts(helper))
        assert reason =~ "provider_error: the disclaim shim could not start"
        assert reason =~ "(exit #{status})"
      end

      helper = fake_helper(ctx.dir, "", 1)

      assert {:error, "provider_error: the Apple Maps helper exited with status 1", %{}} =
               AppleMaps.search(named(), helper_opts(helper))
    end

    test "stdout that is not the places object is a changed parser", ctx do
      for stdout <- ["not json", %{"results" => []}, %{"places" => "none"}] do
        helper = fake_helper(ctx.dir, stdout, 0)

        assert {:error, "parser_changed: " <> _detail, %{}} =
                 AppleMaps.search(named(), helper_opts(helper))
      end
    end

    test "a helper that prints past the ceiling is response_too_large", ctx do
      helper = fake_helper(ctx.dir, String.duplicate("x", 1_100_000), 0)

      assert {:error, "response_too_large: " <> _detail, %{}} =
               AppleMaps.search(named(), helper_opts(helper))
    end

    test "a helper that exits before reading its request is an answer, not a crash", ctx do
      path = Path.join(ctx.dir, "fermix-maps")
      File.write!(path, "#!/bin/sh\nexit 68\n")
      File.chmod!(path, 0o755)

      assert {:error, "provider_error: " <> _detail, %{}} =
               AppleMaps.search(named(), helper_opts(path))
    end

    test "a helper that never answers is killed with its process group at the bound", ctx do
      pid_file = Path.join(ctx.dir, "helper.pid")
      path = Path.join(ctx.dir, "fermix-maps")
      File.write!(path, "#!/bin/sh\necho $$ > '#{pid_file}'\nexec sleep 3600\n")
      File.chmod!(path, 0o755)

      assert {:error, "network: the Apple Maps helper did not answer within 300 ms", %{}} =
               AppleMaps.search(named(), helper_opts(path, timeout_ms: 300))

      os_pid = pid_file |> File.read!() |> String.trim()
      deadline = System.monotonic_time(:millisecond) + @process_bound_ms
      assert gone_by?(os_pid, deadline), "the helper outlived its call"
    end

    test "a missing helper is not ready and refuses every search", ctx do
      missing = Path.join(ctx.dir, "absent/fermix-maps")

      assert {:error, reason} = AppleMaps.ready(helper_path: missing)
      assert reason =~ "provider_error: this build carries no Apple Maps helper"
      assert {:error, ^reason, %{}} = AppleMaps.search(named(), helper_path: missing)
    end

    test "a helper on disk is ready", ctx do
      assert :ok = AppleMaps.ready(helper_path: fake_helper(ctx.dir, %{"places" => []}, 0))
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp named, do: %{query: "tacos", anchor: {:location, "Suwanee, GA"}, count: 5}

  defp helper_opts(helper, opts \\ []), do: Keyword.merge([helper_path: helper], opts)

  # A shell script standing in for the helper: it records its argv and the one
  # request line it reads, prints the canned stdout and exits with `status`.
  defp fake_helper(dir, stdout, status) do
    path = Path.join(dir, "fermix-maps")
    out = Path.join(dir, "stdout")
    File.write!(out, if(is_binary(stdout), do: stdout, else: Jason.encode!(stdout)))

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{Path.join(dir, "args")}'
    IFS= read -r line
    printf '%s\\n' "$line" > '#{Path.join(dir, "request")}'
    cat '#{out}'
    exit #{status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp recorded_request(dir), do: dir |> Path.join("request") |> File.read!() |> Jason.decode!()

  defp recorded_args(dir),
    do: dir |> Path.join("args") |> File.read!() |> String.split("\n", trim: true)

  # `kill -0` answers whether the pid still names a process. A bounded look,
  # since the kernel reaps the killed group on its own schedule.
  defp gone_by?(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        # sleep: the interval between two looks at a pid the kernel has not reaped yet
        Process.sleep(25)
        gone_by?(os_pid, deadline)
    end
  end

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    status == 0
  end
end
