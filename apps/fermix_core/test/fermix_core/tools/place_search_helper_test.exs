defmodule FermixCore.Tools.PlaceSearch.HelperTest do
  @moduledoc """
  The real `fermix-maps` helper (M72 §14.3), on a Mac only: `fermix_nif`'s
  Makefile builds it there, so this module compiles to nothing elsewhere.

  The fixture requests need no network: the self-check, and every request the
  helper refuses before it searches, each with its usage exit. The one live
  search is tagged `mapkit_live` and excluded by default; run it on a Mac with
  `mix test --only mapkit_live`, where it calls Apple Maps for real.
  """

  use ExUnit.Case, async: true

  if match?({:unix, :darwin}, :os.type()) do
    alias FermixCore.Release.ExecutableInventory
    alias FermixCore.Tools.PlaceSearch.AppleMaps

    @usage 64
    @live_bound_ms 30_000
    @suwanee {34.0550, -84.0657}
    @soho {40.7234, -74.0004}

    test "the build made the helper, and it self-checks with no network" do
      assert {"fermix-maps: ok\n", 0} = System.cmd(helper!(), ["--check"])
    end

    # The app's staged bundle signs and verifies what the engine's manifest
    # inventories, and the inventory takes a Mach-O only when its one
    # architecture is the target's.
    test "the helper is a single-architecture Mach-O the release inventory accepts" do
      arch = :erlang.system_info(:system_architecture) |> to_string() |> host_arch()

      assert ExecutableInventory.classify(helper!()) ==
               {:ok, %{kind: "mach_o", architectures: [arch]}}
    end

    test "an argument other than --check is a usage error" do
      assert {%{"error" => %{"message" => _words}}, @usage} = run(["search"], "")
    end

    test "every request it cannot read is refused with the usage exit, before any search" do
      for line <- [
            "not json",
            ~s([]),
            ~s({"query": "coffee"}),
            ~s({"query": "coffee", "anchor": {"kind": "query_only"}, "count": 5}),
            ~s({"query": "  ", "anchor": {"kind": "query_only"}}),
            ~s({"query": "coffee", "anchor": {"kind": "nearby"}}),
            ~s({"query": "coffee", "anchor": {"kind": "location"}}),
            ~s({"query": "coffee", "anchor": {"kind": "location", "location": ""}}),
            ~s({"query": "coffee", "anchor": {"kind": "coordinates", "latitude": 1, "longitude": 2}}),
            ~s({"query": "coffee", "anchor": {"kind": "coordinates", "latitude": 91, "longitude": 2, "radius_meters": 5}}),
            ~s({"query": "coffee", "anchor": {"kind": "coordinates", "latitude": true, "longitude": 2, "radius_meters": 5}}),
            ~s({"query": "coffee", "anchor": {"kind": "coordinates", "latitude": 1, "longitude": 2, "radius_meters": 0}}),
            ~s({"query": "coffee", "anchor": {"kind": "coordinates", "latitude": 1, "longitude": 2, "radius_meters": 50001}})
          ] do
        assert {%{"error" => %{"message" => message}}, @usage} = run([], line <> "\n"),
               "the helper did not refuse #{line}"

        assert is_binary(message) and message != ""
      end
    end

    # Calls Apple Maps for real: the named area is geocoded once and searched.
    @tag :mapkit_live
    test "a live search through the adapter yields M31 records with Apple's pages" do
      request = %{query: "mexican restaurants", anchor: {:location, "Suwanee, GA"}, count: 5}

      assert {:ok, [_ | _] = places, %{}} = AppleMaps.search(request, timeout_ms: @live_bound_ms)

      for place <- places do
        assert is_binary(place.name) and place.name != ""

        assert place.source_url ==
                 "https://maps.apple.com/place?place-id=" <> place.apple_place_id

        assert within_km?(place, @suwanee, 10), "#{place.name} is not in Suwanee"
        assert [category] = place.categories
        assert category =~ ~r/\A[a-z]+(_[a-z]+)*\z/
        refute Map.has_key?(place, :distance)
        assert place |> Map.get(:canonical_url, "https://") |> String.starts_with?("https://")
      end
    end

    # The named area bounds the search: MapKit treats a hinted region as
    # optional and, for some sizes, answers from around this Mac instead, which
    # put a search for coffee in SoHo among the cafes of wherever the Mac is.
    @tag :mapkit_live
    test "a live search stays inside the named area, wherever this Mac is" do
      request = %{query: "coffee", anchor: {:location, "SoHo, New York"}, count: 10}

      assert {:ok, [_ | _] = places, %{}} = AppleMaps.search(request, timeout_ms: @live_bound_ms)

      for place <- places do
        assert within_km?(place, @soho, 3), "#{place.name} is not in SoHo"
      end
    end

    defp within_km?(%{location: %{latitude: lat, longitude: lng}}, {center_lat, center_lng}, km) do
      radians = &(&1 * :math.pi() / 180)
      dlat = radians.(lat - center_lat)
      dlng = radians.(lng - center_lng)

      a =
        :math.pow(:math.sin(dlat / 2), 2) +
          :math.cos(radians.(center_lat)) * :math.cos(radians.(lat)) *
            :math.pow(:math.sin(dlng / 2), 2)

      2 * 6_371.0088 * :math.asin(:math.sqrt(a)) <= km
    end

    defp helper! do
      path = AppleMaps.helper_path()
      assert File.regular?(path), "fermix-maps was not built: run mix compile on a Mac"
      path
    end

    defp host_arch("aarch64" <> _rest), do: "arm64"
    defp host_arch("x86_64" <> _rest), do: "x86_64"

    # The helper is run directly here, with its stdin and exit status in hand;
    # the adapter's own spawn is covered by its fixture suite.
    defp run(args, stdin) do
      port = Port.open({:spawn_executable, helper!()}, [:binary, :exit_status, args: args])
      true = Port.command(port, stdin)
      collect(port, "")
    end

    defp collect(port, acc) do
      receive do
        {^port, {:data, data}} -> collect(port, acc <> data)
        {^port, {:exit_status, status}} -> {Jason.decode!(acc), status}
      after
        10_000 -> flunk("fermix-maps never exited; output so far: #{acc}")
      end
    end
  end
end
