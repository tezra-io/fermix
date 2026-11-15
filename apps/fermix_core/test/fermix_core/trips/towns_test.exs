defmodule FermixCore.Trips.TownsTest do
  # M89: the town each trip day shows, found once for the words of the near in
  # force: which nears a call asks, the geocodes in waves within the call's
  # time left, and what the store keeps of their answers. Every name, place
  # and number here is invented.
  use ExUnit.Case, async: true

  alias FermixCore.Trips.Towns

  @varonne %{
    name: "Varonne, Ostrel, Varonia",
    latitude: 41.14,
    longitude: -8.61,
    radius_meters: 5_210
  }
  @found {:ok, @varonne, %{attempt: 1}}
  @nowhere {:error, "invalid_location: Apple Maps found no place by that name", %{attempt: 1}}

  defp day(id, near, removed_at \\ nil),
    do: %{id: id, kind: :day, near: near, removed_at: removed_at}

  defp stop(id), do: %{id: id, kind: :stop, near: nil, removed_at: nil}

  defp anchors(trip_near, day_near), do: %{placed: %{}, day_near: day_near, trip_near: trip_near}

  # A geocoder that answers each near from `answers`, telling the test each one asked.
  defp geocoder(answers) do
    test = self()

    {:ok,
     fn words ->
       send(test, {:asked, words})
       Map.fetch!(answers, words)
     end}
  end

  # A clock that never moves: the time a call has left is the time it was given.
  defp frozen, do: fn -> 0 end

  defp asked do
    receive do
      {:asked, words} -> [words | asked()]
    after
      0 -> []
    end
  end

  describe "the nears in force" do
    test "the trip's near, then each live day's own, each once" do
      trip = %{near: "Varonne"}

      rows = [
        day("d1", nil),
        stop("s1"),
        day("d2", "Brisa"),
        day("d3", "Varonne"),
        day("d4", "Brisa")
      ]

      assert Towns.in_force(trip, rows) == ["Varonne", "Brisa"]
      assert Towns.in_force(%{near: nil}, [day("d1", nil)]) == []
    end

    test "a call asks every near in force that has no row, its own first, at most 20" do
      known = %{"Varonne" => :none}

      assert Towns.asked(anchors("Varonne", %{1 => "Brisa", 2 => "Kestrin"}), known, []) ==
               {["Brisa", "Kestrin"], []}

      # The nears the call itself set come first, so one past the cap is never its own.
      many = Map.new(1..30, &{&1, "Town #{&1}"})
      {asked, past} = Towns.asked(anchors(nil, many), %{}, ["Town 30", "Town 29"])
      assert length(asked) == Towns.max_per_call() and Towns.max_per_call() == 20
      assert asked |> Enum.take(2) |> Enum.sort() == ["Town 29", "Town 30"]
      assert length(past) == 10 and "Town 1" in asked and "Town 19" in past
    end

    test "the nears a call sets: a create's and each day op's, each once" do
      call = %{
        ops: [
          %{op: :create, near: "Varonne"},
          %{op: :add},
          %{op: :day, near: "Brisa"},
          %{op: :day, near: :keep},
          %{op: :day, near: nil},
          %{op: :day, near: "Brisa"}
        ]
      }

      assert Towns.set_by(call) == ["Varonne", "Brisa"]
    end

    test "a later run can find a town left for a reason that heals, or past the cap" do
      assert Towns.later?([{"A", {:found, @varonne}}, {"B", {:unresolved, :rate_limited}}])
      assert Towns.later?([{"A", {:unresolved, :deadline}}])
      assert Towns.later?([{"A", {:unresolved, :capped}}])
      refute Towns.later?([{"A", {:unresolved, :computer_refused}}, {"B", {:none, :not_found}}])
      refute Towns.later?([{"A", {:unresolved, :unsupported}}])
    end
  end

  describe "resolve/3" do
    test "each near is geocoded once; found, none and what the store keeps of them" do
      result =
        Towns.resolve(
          ["Varonne", "Nowhere"],
          geocoder(%{"Varonne" => @found, "Nowhere" => @nowhere}),
          deadline_ms: 45_000,
          now_ms: frozen()
        )

      assert result.towns == [{"Varonne", {:found, @varonne}}, {"Nowhere", {:none, :not_found}}]
      assert result.sent == ["Varonne", "Nowhere"]
      assert result.stop_reason == nil
      assert Enum.sort(asked()) == ["Nowhere", "Varonne"]

      assert Towns.kept(result.towns) == %{"Varonne" => {:found, @varonne}, "Nowhere" => :none}
      assert Towns.counts(result) == %{towns: 2, towns_found: 1, towns_not_found: 1}
    end

    test "a placemark that is no town is none, as nothing found is" do
      no_town = {:error, "not_a_town: the geocoder found a place that is no town or city", %{}}

      result =
        Towns.resolve(["Varonia"], geocoder(%{"Varonia" => no_town}),
          deadline_ms: 1_000,
          now_ms: frozen()
        )

      assert result.towns == [{"Varonia", {:none, :not_found}}]
    end

    test "a failure that is no answer keeps the town unresolved, and nothing is kept" do
      away = {:error, "computer_away: no Mac is online", %{attempt: 0}}
      busy = {:error, "computer_busy: busy", %{attempt: 1}}
      unsupported = {:error, "unsupported: Brave's place search names no town", %{attempt: 0}}

      result =
        Towns.resolve(["A", "B", "C"], geocoder(%{"A" => busy, "B" => unsupported, "C" => away}),
          deadline_ms: 1_000,
          now_ms: frozen()
        )

      assert [{"A", {:unresolved, :computer_busy}}, {"B", {:unresolved, :unsupported}} | _] =
               result.towns

      assert result.sent == ["A"]
      assert Towns.kept(result.towns) == %{}
    end

    # A town's own stop ends the towns after it, never a stop's lookup: it is
    # its own `stop_reason`, with the place search's code.
    test "an answer that cannot heal within the call stops the towns not yet asked" do
      refused =
        {:error, "computer_refused: studio Mac: Fermix there does not know how to do that.",
         %{attempt: 1, provider_code: "unavailable"}}

      words = Enum.map(1..6, &"Town #{&1}")
      answers = Map.new(words, &{&1, refused})

      result = Towns.resolve(words, geocoder(answers), deadline_ms: 45_000, now_ms: frozen())

      assert result.stop_reason == :computer_refused
      assert result.stop_code == "unavailable"
      assert length(asked()) == 4
      assert Enum.all?(result.towns, &match?({_words, {:unresolved, :computer_refused}}, &1))
      assert length(result.sent) == 4
    end

    test "four at a time, in waves" do
      test = self()
      gauge = start_supervised!({Agent, fn -> %{running: 0, most: 0} end})

      geocode =
        {:ok,
         fn words ->
           Agent.update(gauge, &%{running: &1.running + 1, most: max(&1.most, &1.running + 1)})
           send(test, {:started, self()})

           receive do
             :go -> :ok
           end

           Agent.update(gauge, &%{&1 | running: &1.running - 1})
           {:ok, %{@varonne | name: words}, %{attempt: 1}}
         end}

      words = Enum.map(1..6, &"Town #{&1}")

      task =
        Task.async(fn -> Towns.resolve(words, geocode, deadline_ms: 45_000, now_ms: frozen()) end)

      for wave <- [4, 2] do
        started =
          for _town <- 1..wave do
            assert_receive {:started, pid}
            pid
          end

        assert Agent.get(gauge, & &1.running) == wave
        Enum.each(started, &send(&1, :go))
      end

      assert %{towns: towns} = Task.await(task, 10_000)
      assert Enum.map(towns, &elem(&1, 0)) == words
      assert Agent.get(gauge, & &1.most) == 4
    end

    test "the towns not reached by the time left send nothing and stay unresolved" do
      clock = start_supervised!({Agent, fn -> 0 end})

      geocode =
        {:ok,
         fn _words ->
           Agent.update(clock, &(&1 + 1_000))
           @found
         end}

      words = Enum.map(1..6, &"Town #{&1}")

      result =
        Towns.resolve(words, geocode, deadline_ms: 500, now_ms: fn -> Agent.get(clock, & &1) end)

      assert length(result.sent) == 4
      assert result.stop_reason == :deadline

      assert [{"Town 5", {:unresolved, :deadline}}, {"Town 6", {:unresolved, :deadline}}] =
               Enum.drop(result.towns, 4)
    end

    test "a geocode still running when the time runs out is unresolved, and counts as sent" do
      geocode =
        {:ok,
         fn _words ->
           receive do
             :never -> @found
           end
         end}

      result = Towns.resolve(["Varonne"], geocode, deadline_ms: 50, now_ms: fn -> 0 end)
      assert result.towns == [{"Varonne", {:unresolved, :deadline}}]
      assert result.sent == ["Varonne"]
    end

    test "when the stop lookups stopped the call, the towns send nothing" do
      result =
        Towns.resolve(["Varonne"], geocoder(%{}),
          deadline_ms: 45_000,
          stopped: :rate_limited,
          now_ms: frozen()
        )

      assert result.towns == [{"Varonne", {:unresolved, :rate_limited}}]
      assert result.sent == []
      assert result.stop_reason == nil
      assert asked() == []
    end

    # A home whose place search names no town says nothing of towns, whatever
    # stopped the call's lookups.
    test "a backend that names no town leaves them so, even when the lookups stopped the call" do
      unsupported = {:error, "unsupported: this place search names no town"}

      result =
        Towns.resolve(["Varonne"], unsupported,
          deadline_ms: 45_000,
          stopped: :rate_limited,
          now_ms: frozen()
        )

      assert result.towns ==
               [
                 {"Varonne",
                  {:unresolved, {:no_backend, "unsupported: this place search names no town"}}}
               ]

      refute Towns.later?(result.towns)
    end

    # The towns' one stop lives as long as the call's geocodes: one a Mac set
    # in the first wave holds the next wave back.
    test "the towns' stop is the call's own, from its first wave to its last" do
      test = self()

      geocode =
        {:ok,
         fn words, terms ->
           send(test, {:stopped_when_asked, words, terms[:stopped].()})
           if words == "Town 1", do: terms[:stop].(:computer_refused)
           {:error, "computer_busy: busy", %{attempt: 1}}
         end}

      words = Enum.map(1..5, &"Town #{&1}")
      Towns.resolve(words, geocode, deadline_ms: 45_000, now_ms: fn -> 0 end)
      assert_received {:stopped_when_asked, "Town 5", :computer_refused}
    end

    test "with no place search set up, the towns are unresolved and nothing is asked" do
      result =
        Towns.resolve(["Varonne"], {:error, "auth_failed: no key"},
          deadline_ms: 45_000,
          now_ms: frozen()
        )

      assert result.towns == [{"Varonne", {:unresolved, {:no_backend, "auth_failed: no key"}}}]

      assert Towns.resolve([], {:error, "auth_failed: no key"}, deadline_ms: 1, now_ms: frozen()).towns ==
               []
    end

    # A Mac of the home is told the time left and the towns' own stop, as a
    # stop's lookup is told the call's.
    test "a two-argument geocoder is told how it may send" do
      test = self()

      geocode =
        {:ok,
         fn words, terms ->
           send(test, {:terms, words, terms})
           @found
         end}

      Towns.resolve(["Varonne"], geocode, deadline_ms: 30_000, now_ms: fn -> 0 end)
      assert_received {:terms, "Varonne", terms}
      assert terms[:send_within_ms] == 30_000
      assert terms[:stopped].() == nil
      assert :ok = terms[:stop].(:computer_away)
    end
  end
end
