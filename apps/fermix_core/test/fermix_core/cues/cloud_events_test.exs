defmodule FermixCore.Cues.CloudEventsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.CloudEvents

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => "evt-1",
        "source" => "urn:example:host-alpha",
        "type" => "com.example.disk.alert",
        "subject" => "host:alpha",
        "time" => "2026-10-10T11:59:00Z",
        "datacontenttype" => "application/json",
        "data" => %{"disk" => "/dev/sda", "free_pct" => 3}
      },
      overrides
    )
  end

  defp structured(event), do: CloudEvents.decode(:structured, Jason.encode!(event))
  defp batch(events), do: CloudEvents.decode(:batch, Jason.encode!(events))

  describe "media_mode/1" do
    test "reads the two CloudEvents media types, parameters and case aside" do
      assert CloudEvents.media_mode("application/cloudevents+json") == {:ok, :structured}

      assert CloudEvents.media_mode("Application/CloudEvents+JSON; charset=utf-8") ==
               {:ok, :structured}

      assert CloudEvents.media_mode("application/cloudevents-batch+json") == {:ok, :batch}
    end

    test "refuses every other media type, and none" do
      for type <- ["application/json", "text/plain", "application/cloudevents", "", nil] do
        assert CloudEvents.media_mode(type) == :error
      end
    end
  end

  describe "a structured event" do
    test "decodes into the item fields" do
      assert {:ok, [%{id: "evt-1", result: {:ok, fields}}]} = structured(event())

      assert fields.type == "com.example.disk.alert"
      assert fields.subject == "host:alpha"
      assert fields.occurred_at == ~U[2026-10-10 11:59:00Z]
      assert fields.datacontenttype == "application/json"
      assert fields.data == %{"disk" => "/dev/sda", "free_pct" => 3}
      assert fields.revision == "1"
      assert fields.title == nil
      assert fields.item_id =~ ~r/^ce_[0-9a-f]{64}$/
    end

    test "the item id is the (source, id) pair: stable, and distinct across sources" do
      {:ok, [%{result: {:ok, first}}]} = structured(event())
      {:ok, [%{result: {:ok, again}}]} = structured(event(%{"data" => "changed"}))
      {:ok, [%{result: {:ok, other}}]} = structured(event(%{"source" => "urn:example:beta"}))

      assert first.item_id == again.item_id
      refute first.item_id == other.item_id
    end

    test "an absent time stays nil and an offset time reads in UTC" do
      {:ok, [%{result: {:ok, untimed}}]} = structured(Map.delete(event(), "time"))
      assert untimed.occurred_at == nil

      {:ok, [%{result: {:ok, offset}}]} =
        structured(event(%{"time" => "2026-10-10T13:59:00.250+02:00"}))

      assert offset.occurred_at == ~U[2026-10-10 11:59:00.250Z]
    end

    test "the revision extension is kept, and an integer revision becomes its text" do
      {:ok, [%{result: {:ok, fields}}]} = structured(event(%{"revision" => "3"}))
      assert fields.revision == "3"

      {:ok, [%{result: {:ok, numbered}}]} = structured(event(%{"revision" => 4}))
      assert numbered.revision == "4"
    end

    test "optional attributes may be absent" do
      minimal = Map.take(event(), ["specversion", "id", "source", "type"])
      assert {:ok, [%{result: {:ok, fields}}]} = structured(minimal)
      assert fields.subject == nil
      assert fields.data == nil
      assert fields.datacontenttype == nil
    end

    test "a bad event is invalid on its own line, not refused as a request" do
      cases = [
        {event(%{"specversion" => "0.3"}), ~r/specversion/},
        {Map.delete(event(), "specversion"), ~r/specversion/},
        {Map.delete(event(), "id"), ~r/\bid\b/},
        {event(%{"id" => ""}), ~r/\bid\b/},
        {Map.delete(event(), "source"), ~r/source/},
        {Map.delete(event(), "type"), ~r/type/},
        {event(%{"type" => 7}), ~r/type/},
        {event(%{"time" => "yesterday"}), ~r/time/},
        {event(%{"time" => "2026-10-10T11:59:00"}), ~r/time/},
        {event(%{"subject" => 5}), ~r/subject/},
        {event(%{"datacontenttype" => true}), ~r/datacontenttype/},
        {event(%{"revision" => ""}), ~r/revision/},
        {event(%{"revision" => -1}), ~r/revision/},
        {event(%{"data_base64" => "AAAA"}), ~r/data_base64/}
      ]

      for {bad, pattern} <- cases do
        assert {:ok, [%{result: {:error, message}}]} = structured(bad)
        assert message =~ pattern
      end
    end

    test "an id is echoed when the event has one" do
      assert {:ok, [%{id: nil, result: {:error, _}}]} = structured(Map.delete(event(), "id"))
    end
  end

  describe "a batch" do
    test "decodes each event in order, with per-event errors" do
      events = [event(%{"id" => "a"}), event(%{"specversion" => "2.0", "id" => "b"}), 7]

      assert {:ok, [first, second, third]} = batch(events)
      assert %{id: "a", result: {:ok, _}} = first
      assert %{id: "b", result: {:error, message}} = second
      assert message =~ "specversion"
      assert %{id: nil, result: {:error, "an event must be a JSON object"}} = third
    end

    test "an empty batch is an empty list" do
      assert batch([]) == {:ok, []}
    end

    test "more than 1,000 events is refused as a request" do
      events = List.duplicate(%{}, 1_001)
      assert batch(events) == {:error, :too_many_events}
    end
  end

  describe "request-level refusals" do
    test "a body that is not JSON" do
      assert CloudEvents.decode(:structured, "{not json") == {:error, :invalid_json}
      assert CloudEvents.decode(:batch, "") == {:error, :invalid_json}
    end

    test "a repeated key anywhere in the body" do
      body = ~s({"specversion":"1.0","id":"a","id":"b","source":"s","type":"t"})
      assert CloudEvents.decode(:structured, body) == {:error, :duplicate_object_key}

      nested = ~s([{"specversion":"1.0","id":"a","source":"s","type":"t","data":{"k":1,"k":2}}])
      assert CloudEvents.decode(:batch, nested) == {:error, :duplicate_object_key}
    end

    test "a structured body that is not one object, or a batch that is not an array" do
      assert CloudEvents.decode(:structured, "[]") == {:error, :not_an_event}
      assert CloudEvents.decode(:structured, "3") == {:error, :not_an_event}
      assert CloudEvents.decode(:batch, Jason.encode!(event())) == {:error, :not_a_batch}
    end
  end
end
