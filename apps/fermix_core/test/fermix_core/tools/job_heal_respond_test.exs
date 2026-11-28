defmodule FermixCore.Tools.JobHealRespondTest do
  # M106 §5.5: the heal run's one exit. It checks a decision's shape and hands
  # it to the heal run's own process; it changes nothing itself, and outside a
  # heal run it refuses, naming itself.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Tools.JobHealRespond
  alias FermixTestSupport.TelemetryCapture

  @note "The harbour page now waits on every fetch until the limit ends it."

  defp heal_context do
    ref = make_ref()
    {%{job_heal: %{id: "jhl_0a1b", job_id: "job_tides", reply_to: self(), ref: ref}}, ref}
  end

  defp respond(args) do
    {context, ref} = heal_context()
    {:ok, result} = JobHealRespond.execute(args, context)
    {result, ref}
  end

  describe "a well-formed decision goes to the heal run, once per call" do
    for {args, expected} <- [
          {%{"decision" => "rerun"}, %{decision: :rerun, timeout_seconds: nil, change: nil}},
          {%{"decision" => "pause"}, %{decision: :pause, timeout_seconds: nil, change: nil}},
          {%{"decision" => "tell"}, %{decision: :tell, timeout_seconds: nil, change: nil}},
          {%{"decision" => "raise_limit", "timeout_seconds" => 1_200},
           %{decision: :raise_limit, timeout_seconds: 1_200, change: nil}},
          {%{"decision" => "propose", "change" => %{"schedule" => "every 2 hours"}},
           %{decision: :propose, timeout_seconds: nil, change: %{"schedule" => "every 2 hours"}}}
        ] do
      test "#{args["decision"]}" do
        {result, ref} = respond(Map.put(unquote(Macro.escape(args)), "note", @note))

        assert result.success
        assert result.output =~ "ends here"
        expected = Map.put(unquote(Macro.escape(expected)), :note, @note)
        assert_received {:job_heal_respond, ^ref, ^expected}
      end
    end
  end

  describe "a decision of the wrong shape is refused and goes nowhere" do
    for {label, args} <- [
          {"an unknown decision", %{"decision" => "remove", "note" => @note}},
          {"no note", %{"decision" => "tell"}},
          {"a blank note", %{"decision" => "tell", "note" => "   "}},
          {"a note too long", %{"decision" => "tell", "note" => String.duplicate("a", 281)}},
          {"raise_limit with no limit", %{"decision" => "raise_limit", "note" => @note}},
          {"raise_limit below one second",
           %{"decision" => "raise_limit", "timeout_seconds" => 0, "note" => @note}},
          {"propose with no change", %{"decision" => "propose", "note" => @note}},
          {"propose with an empty change",
           %{"decision" => "propose", "change" => %{}, "note" => @note}},
          {"propose touching the job's tools",
           %{
             "decision" => "propose",
             "change" => %{"allowed_tools" => ["shell"]},
             "note" => @note
           }},
          {"propose removing the job",
           %{"decision" => "propose", "change" => %{"remove" => true}, "note" => @note}},
          {"propose with a field of the wrong type",
           %{"decision" => "propose", "change" => %{"timeout_seconds" => "long"}, "note" => @note}},
          {"propose clearing the pin with false",
           %{"decision" => "propose", "change" => %{"clear_route_pin" => false}, "note" => @note}}
        ] do
      test "#{label}" do
        {result, _ref} = respond(unquote(Macro.escape(args)))

        refute result.success
        refute_received {:job_heal_respond, _ref, _decision}
      end
    end
  end

  # A heal never changes where a job delivers, as it never touches the job's
  # tools: a change naming either delivery field is refused as one naming any
  # field a heal may not change, traced under that refusal's tag with the
  # sentence naming the field, and the schema offers neither.
  test "a proposal that moves where the job delivers is refused, and none is offered" do
    TelemetryCapture.attach([[:fermix, :tool, :exec]], :emitter)

    for {change, named} <- [
          {%{"delivery_mode" => "channel"}, "delivery_mode"},
          {%{"delivery_target" => %{"platform" => "telegram", "chat_id" => "99999"}},
           "delivery_target"},
          {%{"schedule" => "every 2 hours", "delivery_mode" => "none"}, "delivery_mode"}
        ] do
      {result, _ref} = respond(%{"decision" => "propose", "change" => change, "note" => @note})

      refute result.success
      assert result.error =~ "these are not: #{named}."
      refute_received {:job_heal_respond, _ref, _decision}

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                       %{tool: "job_heal_respond", error_code: "invalid_change"} = traced}

      assert traced.error_summary =~ named
    end

    offered = Map.keys(JobHealRespond.parameters().properties.change.properties)
    refute :delivery_mode in offered
    refute :delivery_target in offered
  end

  # What the schema offers is what a stored change may name: the store reads a
  # change naming any other field as none.
  test "the change it offers names exactly the fields a stored change may name" do
    offered = Map.keys(JobHealRespond.parameters().properties.change.properties)

    assert Enum.sort(Enum.map(offered, &Atom.to_string/1)) ==
             Enum.sort(HealDecision.change_fields())
  end

  # Stage S4, round two: the note is one or two sentences, so its bound is 280
  # characters, stated in the schema, the description and the refusal.
  test "a note of 280 characters is taken and one of 281 refused, whole, saying the bound" do
    {taken, _ref} = respond(%{"decision" => "tell", "note" => String.duplicate("a", 280)})
    assert taken.success

    {refused, _ref} = respond(%{"decision" => "tell", "note" => String.duplicate("a", 281)})
    refute refused.success
    assert refused.error =~ "The note is 281 characters and must be at most 280"

    assert JobHealRespond.parameters().properties.note.description =~ "At most 280 characters"
    assert JobHealRespond.description() =~ "at most 280 characters"
  end

  test "a note goes as written, trimmed and never cut; the message flattens it" do
    {result, ref} = respond(%{"decision" => "tell", "note" => "  First line.\n\nSecond line. "})

    assert result.success
    assert_received {:job_heal_respond, ^ref, %{note: "First line.\n\nSecond line."}}
  end

  test "outside a heal run it refuses, naming itself, and sends nothing" do
    assert {:ok, result} =
             JobHealRespond.execute(%{"decision" => "tell", "note" => @note}, %{
               source_trust: :operator
             })

    refute result.success
    assert result.error =~ "job_heal_respond"
    refute JobHealRespond.advertise?(%{source_trust: :operator})
    refute_received {:job_heal_respond, _ref, _decision}
  end

  test "offered inside a heal run" do
    {context, _ref} = heal_context()
    assert JobHealRespond.advertise?(context)
  end
end
