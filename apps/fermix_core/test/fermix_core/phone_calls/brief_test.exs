defmodule FermixCore.PhoneCalls.BriefTest do
  # Pure module: the clock and the configured caller number arrive in `opts`.
  # Every number is invented, in the 555-01XX range NANPA reserves for fiction,
  # and every name and place is invented too.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.Brief

  @caller "+14155550142"
  @now ~U[2026-11-17 18:00:00Z]
  @opts [caller_number: @caller, now: @now]

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "destination" => "+12125550101",
        "destination_kind" => "business",
        "number_source" => "The owner read it from the bistro's own website.",
        "contact_name" => "Calloway Bistro",
        "timezone" => "America/New_York",
        "goal" => "Ask for a table for two on Saturday 21 November 2026 at 19:30.",
        "completion_criteria" => ["The host confirms a table for two at 19:30 on 21 November."],
        "must_not_commit" => ["a deposit", "a card number"],
        "alternatives" => ["19:00 or 20:00 on the same evening"],
        "shareable_facts" => [%{"label" => "name for the booking", "value" => "Ada Quill"}],
        "tool_grants" => ["calendar_lookup"],
        "times" => [%{"label" => "requested table", "at" => "2026-11-21T19:30"}]
      },
      overrides
    )
  end

  describe "new/2 builds the mandate" do
    test "from model parameters and the server's own facts" do
      assert {:ok, %Brief{} = brief} = Brief.new(params(), @opts)

      assert brief.destination == "+12125550101"
      assert brief.destination_kind == :business
      assert brief.number_source == "The owner read it from the bistro's own website."
      assert brief.contact_name == "Calloway Bistro"
      assert brief.timezone == "America/New_York"

      assert brief.completion_criteria == [
               "The host confirms a table for two at 19:30 on 21 November."
             ]

      assert brief.must_not_commit == ["a deposit", "a card number"]
      assert brief.alternatives == ["19:00 or 20:00 on the same evening"]
      assert brief.shareable_facts == [%{label: "name for the booking", value: "Ada Quill"}]
      assert brief.tool_grants == ["calendar_lookup"]
      assert brief.times == [%{label: "requested table", at: "2026-11-21T19:30"}]
      assert brief.opening_language == "en"
      assert brief.caller_number == @caller
    end

    test "a call to the owner's own phone" do
      assert {:ok, %Brief{destination_kind: :owner}} =
               Brief.new(params(%{"destination_kind" => "owner"}), @opts)
    end

    test "optional lists default to empty and the opening language to English" do
      minimal =
        Map.drop(params(), [
          "must_not_commit",
          "alternatives",
          "shareable_facts",
          "tool_grants",
          "times"
        ])

      assert {:ok, brief} = Brief.new(minimal, @opts)
      assert brief.must_not_commit == []
      assert brief.alternatives == []
      assert brief.shareable_facts == []
      assert brief.tool_grants == []
      assert brief.times == []
      assert brief.opening_language == "en"
    end

    test "trims text and takes another opening language" do
      assert {:ok, brief} =
               Brief.new(
                 params(%{
                   "contact_name" => "  Calloway Bistro  ",
                   "opening_language" => "es-US"
                 }),
                 @opts
               )

      assert brief.contact_name == "Calloway Bistro"
      assert brief.opening_language == "es-US"
    end
  end

  describe "new/2 refuses who may not be called, each with its own reason" do
    test "a private individual" do
      assert {:error, {:refused, :private_individual, sentence}} =
               Brief.new(params(%{"destination_kind" => "private_individual"}), @opts)

      assert sentence =~ "private"
    end

    test "a destination kind the brief does not know" do
      assert {:error, {:refused, :unknown_destination_kind, sentence}} =
               Brief.new(params(%{"destination_kind" => "friend"}), @opts)

      assert is_binary(sentence) and sentence != ""
    end

    test "a number outside the US states and DC" do
      for number <- ["+14165550142", "+18765550142", "+17875550142", "+442079460142"] do
        assert {:error, {:refused, :destination_not_us, _sentence}} =
                 Brief.new(params(%{"destination" => number}), @opts),
               number
      end
    end

    test "an emergency, service, toll-free or premium number" do
      for number <- [
            "+19115550142",
            "+12129110142",
            "+18005550142",
            "+19005550142",
            "+12129760142"
          ] do
        assert {:error, {:refused, :emergency_or_special_number, _sentence}} =
                 Brief.new(params(%{"destination" => number}), @opts),
               number
      end
    end

    test "a refusal wins over field problems, since fixing them cannot help" do
      assert {:error, {:refused, :private_individual, _sentence}} =
               Brief.new(
                 params(%{"destination_kind" => "private_individual", "goal" => ""}),
                 @opts
               )
    end

    test "refusal_sentence/1 has one sentence for each refusal" do
      for reason <- Brief.refusal_reasons() do
        sentence = Brief.refusal_sentence(reason)
        assert is_binary(sentence) and String.ends_with?(sentence, ".")
      end

      assert Brief.refusal_reasons()
             |> Enum.map(&Brief.refusal_sentence/1)
             |> Enum.uniq()
             |> length() ==
               length(Brief.refusal_reasons())
    end
  end

  describe "new/2 rejects what the model never supplies" do
    test "server-owned fields are rejected loudly, never ignored" do
      for key <-
            ~w(approved caller_number sip_password sip_username provider_url callback_url instructions model voice) do
        assert {:error, {:invalid_brief, problems}} =
                 Brief.new(Map.put(params(), key, "anything"), @opts),
               key

        assert {:server_owned_field, key} in problems, key
      end
    end

    test "an unknown field is rejected and named" do
      assert {:error, {:invalid_brief, [{:unknown_field, "budget"}]}} =
               Brief.new(Map.put(params(), "budget", "50"), @opts)
    end

    test "non-string keys and oversized parameter maps" do
      assert {:error, {:invalid_brief, problems}} =
               Brief.new(Map.put(params(), :goal, "x"), @opts)

      assert {:params, :non_string_key} in problems

      huge = Map.new(1..40, fn i -> {"extra_#{i}", "x"} end)

      assert {:error, {:invalid_brief, [{:params, :too_many_fields}]}} =
               Brief.new(Map.merge(params(), huge), @opts)
    end
  end

  describe "new/2 reports every field problem, not the first" do
    test "missing required fields" do
      required =
        ~w(destination destination_kind number_source contact_name timezone goal completion_criteria)

      assert {:error, {:invalid_brief, problems}} =
               Brief.new(Map.drop(params(), required -- ["destination_kind"]), @opts)

      for field <- required -- ["destination_kind"] do
        assert {String.to_existing_atom(field), :missing} in problems, field
      end
    end

    test "a missing destination kind is a brief problem, not a refusal" do
      assert {:error, {:invalid_brief, [{:destination_kind, :missing}]}} =
               Brief.new(Map.delete(params(), "destination_kind"), @opts)
    end

    test "malformed numbers" do
      assert {:error, {:invalid_brief, [{:destination, :not_e164}]}} =
               Brief.new(params(%{"destination" => "212-555-0101"}), @opts)

      assert {:error, {:invalid_brief, [{:destination, :not_nanp_number}]}} =
               Brief.new(params(%{"destination" => "+11125550101"}), @opts)

      assert {:error, {:invalid_brief, [{:destination, :same_as_caller_number}]}} =
               Brief.new(params(%{"destination" => @caller}), @opts)
    end

    test "types, blanks, sizes and counts" do
      assert {:error, {:invalid_brief, problems}} =
               Brief.new(
                 params(%{
                   "contact_name" => 7,
                   "goal" => "   ",
                   "number_source" => String.duplicate("s", 301),
                   "completion_criteria" => [],
                   "alternatives" => List.duplicate("another time", 9),
                   "must_not_commit" => "a deposit",
                   "timezone" => "Mars/Olympus_Mons",
                   "opening_language" => "English please"
                 }),
                 @opts
               )

      assert {:contact_name, :not_a_string} in problems
      assert {:goal, :blank} in problems
      assert {:number_source, :too_long} in problems
      assert {:completion_criteria, :empty} in problems
      assert {:alternatives, :too_many} in problems
      assert {:must_not_commit, :not_a_list} in problems
      assert {:timezone, :unknown_timezone} in problems
      assert {:opening_language, :not_a_language_tag} in problems
      assert length(problems) == 8
    end

    test "control characters are refused, and a line field takes no line break" do
      assert {:error, {:invalid_brief, problems}} =
               Brief.new(
                 params(%{
                   "contact_name" => "Calloway\nBistro",
                   "goal" => "Ask\u0000 for a table"
                 }),
                 @opts
               )

      assert {:contact_name, :control_characters} in problems
      assert {:goal, :control_characters} in problems

      assert {:ok, _brief} =
               Brief.new(params(%{"goal" => "Ask for a table.\nTwo people."}), @opts)
    end

    test "list items are checked one by one" do
      assert {:error, {:invalid_brief, problems}} =
               Brief.new(
                 params(%{
                   "completion_criteria" => ["ok", ""],
                   "alternatives" => ["fine", 3],
                   "must_not_commit" => [String.duplicate("m", 301)]
                 }),
                 @opts
               )

      assert {:completion_criteria, :blank_item} in problems
      assert {:alternatives, :item_not_a_string} in problems
      assert {:must_not_commit, :item_too_long} in problems
    end

    test "shareable facts are label and value pairs" do
      for {facts, reason} <- [
            {[%{"label" => "name"}], :invalid_fact},
            {[%{"label" => "name", "value" => "Ada", "secret" => true}], :invalid_fact},
            {["Ada Quill"], :invalid_fact},
            {[%{"label" => "", "value" => "Ada"}], :invalid_fact},
            {List.duplicate(%{"label" => "a", "value" => "b"}, 13), :too_many}
          ] do
        assert {:error, {:invalid_brief, [{:shareable_facts, ^reason}]}} =
                 Brief.new(params(%{"shareable_facts" => facts}), @opts),
               inspect(facts)
      end
    end

    test "tool grants are distinct tool names" do
      for {grants, reason} <- [
            {["calendar lookup"], :invalid_tool_name},
            {["calendar_lookup", "calendar_lookup"], :duplicate},
            {Enum.map(1..9, &"tool_#{&1}"), :too_many},
            {[String.duplicate("t", 65)], :invalid_tool_name}
          ] do
        assert {:error, {:invalid_brief, [{:tool_grants, ^reason}]}} =
                 Brief.new(params(%{"tool_grants" => grants}), @opts),
               inspect(grants)
      end
    end
  end

  describe "new/2 takes absolute local times in the destination's zone" do
    test "a date or a wall-clock time, with no offset" do
      times = [
        %{"label" => "day", "at" => "2026-11-21"},
        %{"label" => "slot", "at" => "2026-11-21T19:30"}
      ]

      assert {:ok, brief} = Brief.new(params(%{"times" => times}), @opts)
      assert Enum.map(brief.times, & &1.at) == ["2026-11-21", "2026-11-21T19:30"]
    end

    test "a relative, offset, impossible or past time is refused by reason" do
      for {at, reason} <- [
            {"next Saturday", :not_a_local_time},
            {"2026-11-21T19:30:00-05:00", :not_a_local_time},
            {"2026-11-21T19:30Z", :not_a_local_time},
            {"2026-02-30", :not_a_local_time},
            {"2026-11-17T12:00", :in_the_past},
            {"2026-11-16", :in_the_past},
            {"2027-03-14T02:30", :nonexistent_local_time},
            {"2026-11-01T01:30", :in_the_past},
            {"2027-11-07T01:30", :ambiguous_local_time}
          ] do
        assert {:error, {:invalid_brief, [{:times, ^reason}]}} =
                 Brief.new(params(%{"times" => [%{"label" => "slot", "at" => at}]}), @opts),
               at
      end
    end

    test "today in the destination's zone is not the past" do
      assert {:ok, _brief} =
               Brief.new(params(%{"times" => [%{"label" => "day", "at" => "2026-11-17"}]}), @opts)
    end
  end

  describe "the server's own facts must be sound" do
    test "a missing or malformed caller number or clock fails loud" do
      assert_raise ArgumentError, fn -> Brief.new(params(), now: @now) end

      assert_raise ArgumentError, fn ->
        Brief.new(params(), caller_number: "+14165550142", now: @now)
      end

      assert_raise ArgumentError, fn -> Brief.new(params(), caller_number: @caller) end
    end
  end

  describe "on_behalf_of, the name the call is made for" do
    test "is none when absent, null or blank" do
      for given <- [:absent, nil, "", "   "] do
        brief_params =
          if given == :absent, do: params(), else: params(%{"on_behalf_of" => given})

        assert {:ok, %Brief{on_behalf_of: nil}} = Brief.new(brief_params, @opts), inspect(given)
      end
    end

    test "is trimmed and kept" do
      assert {:ok, %Brief{on_behalf_of: "Ada Quill"}} =
               Brief.new(params(%{"on_behalf_of" => "  Ada Quill "}), @opts)
    end

    test "is one bounded line of text" do
      bound = Brief.bounds().on_behalf_of_bytes
      assert bound == 120

      assert {:ok, _brief} =
               Brief.new(params(%{"on_behalf_of" => String.duplicate("a", bound)}), @opts)

      for {given, reason} <- [
            {String.duplicate("a", bound + 1), :too_long},
            {"Ada\nQuill", :control_characters},
            {"Ada\u0000Quill", :control_characters},
            {<<0xFF, 0xFE>>, :invalid_utf8},
            {42, :not_a_string},
            {["Ada Quill"], :not_a_string}
          ] do
        assert {:error, {:invalid_brief, [{:on_behalf_of, ^reason}]}} =
                 Brief.new(params(%{"on_behalf_of" => given}), @opts),
               inspect(given)
      end
    end

    test "is part of the mandate's hash and its stored map" do
      {:ok, none} = Brief.new(params(), @opts)
      {:ok, named} = Brief.new(params(%{"on_behalf_of" => "Ada Quill"}), @opts)

      assert Brief.hash(none) != Brief.hash(named)
      assert Brief.to_map(named)["on_behalf_of"] == "Ada Quill"
      assert Brief.canonical_json(named) =~ ~s("on_behalf_of":"Ada Quill")

      assert {:ok, ^named} =
               named |> Brief.to_map() |> Jason.encode!() |> Jason.decode!() |> Brief.from_map()

      assert {:ok, ^none} =
               none |> Brief.to_map() |> Jason.encode!() |> Jason.decode!() |> Brief.from_map()
    end

    test "a stored brief written without the key reads back as none" do
      {:ok, named} = Brief.new(params(%{"on_behalf_of" => "Ada Quill"}), @opts)
      stored = named |> Brief.to_map() |> Map.delete("on_behalf_of")

      assert {:ok, %Brief{on_behalf_of: nil}} = Brief.from_map(stored)
    end

    test "a stored value is checked like a supplied one" do
      {:ok, named} = Brief.new(params(%{"on_behalf_of" => "Ada Quill"}), @opts)
      stored = Map.put(Brief.to_map(named), "on_behalf_of", "Ada\nQuill")

      assert {:error, {:invalid_stored_brief, [{:on_behalf_of, :control_characters}]}} =
               Brief.from_map(stored)
    end
  end

  describe "characters that break a line, reorder text or hide inside it" do
    # Written as escapes: Elixir refuses a raw bidirectional control in source.
    @refused [
      {"NEL", "\u{0085}"},
      {"C1 first", "\u{0080}"},
      {"C1 last", "\u{009F}"},
      {"LINE SEPARATOR", "\u{2028}"},
      {"PARAGRAPH SEPARATOR", "\u{2029}"},
      {"LRE", "\u{202A}"},
      {"RLE", "\u{202B}"},
      {"PDF", "\u{202C}"},
      {"LRO", "\u{202D}"},
      {"RLO", "\u{202E}"},
      {"LRI", "\u{2066}"},
      {"RLI", "\u{2067}"},
      {"FSI", "\u{2068}"},
      {"PDI", "\u{2069}"},
      {"LRM", "\u{200E}"},
      {"RLM", "\u{200F}"},
      {"ALM", "\u{061C}"},
      {"ZERO WIDTH SPACE", "\u{200B}"},
      {"ZERO WIDTH NO-BREAK SPACE", "\u{FEFF}"}
    ]

    # Each string field, with the value carrying `char` inside it and the
    # problem that field reports.
    defp carrying(char) do
      at = fn text -> "Calloway" <> char <> text end

      [
        {%{"contact_name" => at.(" Bistro")}, {:contact_name, :control_characters}},
        {%{"number_source" => at.(" website")}, {:number_source, :control_characters}},
        {%{"goal" => at.(" table")}, {:goal, :control_characters}},
        {%{"timezone" => "America/New" <> char <> "_York"}, {:timezone, :control_characters}},
        {%{"opening_language" => "en" <> char <> "-US"},
         {:opening_language, :control_characters}},
        {%{"on_behalf_of" => at.(" Quill")}, {:on_behalf_of, :control_characters}},
        {%{"completion_criteria" => [at.(" confirms")]},
         {:completion_criteria, :item_control_characters}},
        {%{"must_not_commit" => [at.(" deposit")]}, {:must_not_commit, :item_control_characters}},
        {%{"alternatives" => [at.(" later")]}, {:alternatives, :item_control_characters}},
        {%{"shareable_facts" => [%{"label" => at.(" name"), "value" => "Ada"}]},
         {:shareable_facts, :invalid_fact}},
        {%{"shareable_facts" => [%{"label" => "name", "value" => at.(" Ada")}]},
         {:shareable_facts, :invalid_fact}},
        {%{"times" => [%{"label" => at.(" slot"), "at" => "2026-11-21T19:30"}]},
         {:times, :invalid_time_entry}}
      ]
    end

    test "are refused in every string field the model supplies" do
      for {name, char} <- @refused, {fields, problem} <- carrying(char) do
        assert Brief.new(params(fields), @opts) == {:error, {:invalid_brief, [problem]}},
               "#{name} in #{inspect(Map.keys(fields))}"
      end
    end

    test "are refused in every string field a stored brief holds" do
      {:ok, brief} = Brief.new(params(), @opts)
      stored = Brief.to_map(brief)

      for {name, char} <- @refused, {fields, problem} <- carrying(char) do
        assert Brief.from_map(Map.merge(stored, fields)) ==
                 {:error, {:invalid_stored_brief, [problem]}},
               "#{name} in #{inspect(Map.keys(fields))}"
      end
    end

    test "the joiners a script or an emoji needs, and ordinary letters, are kept" do
      for text <- [
            "Kabab\u{200C}khaneh",
            "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} table",
            "Café Niño",
            "寿司 Kaito",
            "Calloway\u{00A0}Bistro"
          ] do
        assert {:ok, brief} =
                 Brief.new(params(%{"contact_name" => text, "goal" => text}), @opts),
               text

        assert brief.contact_name == text
        assert {:ok, ^brief} = brief |> Brief.to_map() |> Brief.from_map()
      end
    end

    test "a line break at either end is trimmed away, never kept" do
      assert {:ok, %Brief{contact_name: "Calloway Bistro"}} =
               Brief.new(params(%{"contact_name" => "\u{2028}Calloway Bistro\u{2029}"}), @opts)
    end
  end

  describe "schema/0" do
    test "is the schema the stored map and the canonical encoding carry" do
      {:ok, brief} = Brief.new(params(), @opts)

      assert Brief.schema() == 1
      assert Brief.to_map(brief)["schema"] == Brief.schema()
      assert Brief.canonical_json(brief) =~ ~s("schema":#{Brief.schema()})
    end
  end

  describe "hash/1" do
    test "is the same for the same mandate, whatever order the model wrote it in" do
      {:ok, one} = Brief.new(params(), @opts)
      reordered = params() |> Enum.reverse() |> Map.new()
      {:ok, two} = Brief.new(reordered, @opts)

      assert Brief.hash(one) == Brief.hash(two)
      assert Brief.hash(one) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "changes when any term of the mandate changes" do
      {:ok, base} = Brief.new(params(), @opts)
      {:ok, other_goal} = Brief.new(params(%{"goal" => "Ask for a table for three."}), @opts)
      {:ok, other_caller} = Brief.new(params(), caller_number: "+14155550143", now: @now)

      assert Brief.hash(base) != Brief.hash(other_goal)
      assert Brief.hash(base) != Brief.hash(other_caller)
    end

    # Pins the canonical encoding, so a restart, a release or a reordered
    # struct cannot change what an admitted mandate hashes to.
    test "is stable across restarts" do
      {:ok, brief} = Brief.new(params(), @opts)

      assert Brief.hash(brief) ==
               :crypto.hash(:sha256, Brief.canonical_json(brief)) |> Base.encode16(case: :lower)

      assert Brief.canonical_json(brief) =~ ~r/\A\{"alternatives":/

      assert Brief.hash(brief) ==
               Brief.hash(brief |> Brief.to_map() |> Brief.from_map() |> elem(1))
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trip through JSON text, as the ledger stores it" do
      {:ok, brief} = Brief.new(params(%{"destination_kind" => "owner"}), @opts)

      json = brief |> Brief.to_map() |> Jason.encode!()
      assert {:ok, ^brief} = json |> Jason.decode!() |> Brief.from_map()
    end

    test "a stored brief whose times have passed still reads back" do
      {:ok, brief} = Brief.new(params(), @opts)
      assert {:ok, ^brief} = brief |> Brief.to_map() |> Brief.from_map()
    end

    test "refuses a stored map that is not a brief" do
      {:ok, brief} = Brief.new(params(), @opts)
      map = Brief.to_map(brief)

      assert {:error, {:invalid_stored_brief, _problems}} =
               Brief.from_map(Map.put(map, "approved", true))

      assert {:error, {:invalid_stored_brief, _problems}} =
               Brief.from_map(Map.put(map, "destination_kind", "private_individual"))

      assert {:error, {:invalid_stored_brief, _problems}} =
               Brief.from_map(Map.put(map, "schema", 99))

      assert {:error, {:invalid_stored_brief, _problems}} =
               Brief.from_map(Map.delete(map, "goal"))
    end
  end
end
