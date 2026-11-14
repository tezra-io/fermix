defmodule FermixCore.Computers.Capabilities.PlacesTest do
  # M89 D13 D: looking places up in Apple Maps on a Mac of the home, for its
  # server's place search. The computer's side: its args, its run against a
  # shell script standing in for the `fermix-maps` helper (no MapKit, no
  # network), its admission on a build without the helper, and the answer's
  # round trip back into the record the server's place search keeps.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Capabilities.Places
  alias FermixCore.Tools.PlaceSearch.AppleMaps
  alias FermixTestSupport.SafeRm

  @mac_app %{profile: :app_engine, os: :darwin}
  @linux %{profile: :linux_package_cli, os: :linux}
  @brew_mac %{profile: :standalone_cli, os: :darwin}

  # Raw fields as the helper prints them, for an invented place.
  @raw %{
    "name" => "Casa Inventada",
    "latitude" => 41.1402,
    "longitude" => -8.6113,
    "identifier" => "I0A1B2C3D4E5F6071",
    "url" => "https://casa-inventada.example",
    "phone" => "+351 555 0101",
    "category" => "MKPOICategoryRestaurant",
    "address" => "12 Rua Inventada\nVaronne"
  }

  setup do
    dir = SafeRm.make_tmp_dir!("places-capability")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A shell script standing in for the helper: it records the request line it
  # reads, prints the canned object and exits with `status`.
  defp fake_helper(dir, stdout, status) do
    path = Path.join(dir, "fermix-maps")
    File.write!(Path.join(dir, "stdout"), Jason.encode!(stdout))

    File.write!(path, """
    #!/bin/sh
    IFS= read -r line
    printf '%s\\n' "$line" > '#{Path.join(dir, "request")}'
    cat '#{Path.join(dir, "stdout")}'
    exit #{status}
    """)

    File.chmod!(path, 0o755)
    path
  end

  # This computer's context, the helper named and spawned directly.
  defp context(helper, more \\ %{}) do
    %{
      id: "inv-test",
      origin: :chat,
      epoch: 4,
      turn: %{session_id: "main-21", tool_call_id: "call-1"},
      home: "/nonexistent",
      switches: [],
      clock: fn -> ~U[2031-06-02 09:00:00Z] end,
      deadline_ms: 15_000,
      host: @mac_app,
      apple_maps: [helper_path: helper, os_type: {:unix, :linux}, shim_path: nil]
    }
    |> Map.merge(more)
  end

  describe "what it is" do
    test "one op that only reads, in the owner's words, its target never the query" do
      assert Places.id() == :places
      assert Places.offer() == :places
      assert Places.ops() == ["search"]
      refute Places.effect?("search")
      refute Places.long_lived?("search")
      assert Places.label() == "Apple Maps"
      assert Places.op_label("search") == "look up places"
      assert Places.target("search", %{"query" => "a private appointment"}) == "Apple Maps"
      assert Places.bounds("search") == %{result_bytes: 65_536, part_bytes: 0}
    end

    test "it is what a computer can be asked by the wire's name" do
      capabilities = Application.fetch_env!(:fermix_core, :computer_capabilities).capabilities()
      assert capabilities["places"] == Places
    end
  end

  describe "validate/2" do
    test "takes a query, one anchor, a count and units" do
      for args <- [
            %{"query" => "coffee"},
            %{"query" => "coffee", "near" => "Varonne, Portugal", "count" => 5},
            %{"query" => "coffee", "latitude" => 41.14, "longitude" => -8.61},
            %{
              "query" => "coffee",
              "latitude" => 41.14,
              "longitude" => -8.61,
              "radius_meters" => 2_000,
              "units" => "imperial"
            }
          ] do
        assert Places.validate("search", args) == :ok, inspect(args)
      end
    end

    test "refuses what Apple Maps would not take, in a sentence" do
      for args <- [
            %{},
            %{"query" => "  "},
            %{"query" => String.duplicate("a", 401)},
            %{"query" => 7},
            %{"query" => "coffee", "near" => ""},
            %{"query" => "coffee", "near" => String.duplicate("a", 201)},
            %{"query" => "coffee", "near" => "Varonne", "latitude" => 1, "longitude" => 2},
            %{"query" => "coffee", "near" => "Varonne", "radius_meters" => 10},
            %{"query" => "coffee", "latitude" => 91, "longitude" => 2},
            %{"query" => "coffee", "latitude" => 1},
            %{"query" => "coffee", "radius_meters" => 10},
            %{"query" => "coffee", "latitude" => 1, "longitude" => 2, "radius_meters" => 0},
            %{"query" => "coffee", "latitude" => 1, "longitude" => 2, "radius_meters" => 50_001},
            %{"query" => "coffee", "count" => 0},
            %{"query" => "coffee", "count" => 11},
            %{"query" => "coffee", "units" => "furlongs"},
            %{"query" => "coffee", "country" => "PT"}
          ] do
        assert {:error, sentence} = Places.validate("search", args), inspect(args)
        assert is_binary(sentence) and String.ends_with?(sentence, ".")
      end
    end

    test "the args a place search's request makes are ones it takes, and stand for that request" do
      for request <- [
            %{query: "coffee", count: 5},
            %{query: "coffee", count: 5, anchor: {:location, "Varonne, Portugal"}},
            %{query: "coffee", anchor: {:coordinates, 41.14, -8.61}, radius_meters: 2_000},
            %{query: "coffee", anchor: {:coordinates, 41.14, -8.61}, units: :imperial}
          ] do
        args = Places.args(request)
        assert Places.validate("search", args) == :ok
        assert Places.request(Jason.decode!(Jason.encode!(args))) == request
      end
    end
  end

  describe "admit/3" do
    test "runs only where this build carries the Apple Maps helper", %{dir: dir} do
      helper = fake_helper(dir, %{"places" => []}, 0)

      assert Places.admit("search", %{"query" => "coffee"}, context(helper)) == :ok

      for host <- [@linux, @brew_mac] do
        assert Places.admit("search", %{"query" => "coffee"}, context(helper, %{host: host})) ==
                 {:refused, :unavailable,
                  "Looking places up in Apple Maps needs the Fermix app on a Mac."}
      end
    end
  end

  describe "run/4" do
    test "runs this computer's Apple Maps helper and answers what it printed", %{dir: dir} do
      helper = fake_helper(dir, %{"places" => [@raw]}, 0)
      args = %{"query" => "Casa Inventada", "near" => "Varonne, Portugal", "count" => 5}

      assert {:ok, %{"places" => [@raw]} = result, nil} =
               Places.run("search", args, nil, context(helper))

      assert dir |> Path.join("request") |> File.read!() |> Jason.decode!() == %{
               "query" => "Casa Inventada",
               "anchor" => %{"kind" => "location", "location" => "Varonne, Portugal"}
             }

      # The server makes the record with the code a search here makes it with.
      {:ok, [expected], %{}} =
        AppleMaps.search(Places.request(args),
          helper_path: helper,
          os_type: {:unix, :linux},
          shim_path: nil
        )

      wire = result |> Jason.encode!() |> Jason.decode!()
      assert {:ok, [^expected]} = Places.places(wire, Places.request(args))
      assert expected.address == "12 Rua Inventada, Varonne"

      assert {:error, "parser_changed: " <> _rest} =
               Places.places(%{"places" => List.duplicate(@raw, 33)}, Places.request(args))

      assert {:error, "parser_changed: " <> _rest} = Places.places(%{}, Places.request(args))
    end

    # The Mac's deadline always outlasts its helper, so a slow Apple Maps
    # answers as Apple Maps (`network`), never as the deadline.
    test "the helper's bound sits inside the deadline the Mac was given" do
      assert Places.helper_timeout_ms(15_000) == 13_500
      assert Places.helper_timeout_ms(6_000) == 4_500
      assert Places.helper_timeout_ms(60_000) == 15_000
      assert Places.helper_timeout_ms(1_000) == 1
    end

    test "a search that fails answers failed with Apple Maps' own tag", %{dir: dir} do
      helper = fake_helper(dir, %{"error" => %{"message" => "MKErrorDomain 4"}}, 65)

      assert {:failed, "invalid_location: Apple Maps found no place by that name" <> _words} =
               Places.run(
                 "search",
                 %{"query" => "coffee", "near" => "Nowhere"},
                 nil,
                 context(helper)
               )
    end

    test "takes no file" do
      assert {:failed, "Looking places up takes no file."} =
               Places.run("search", %{"query" => "coffee"}, "bytes", context("/nonexistent"))
    end
  end
end
