defmodule FermixCore.ReleasedContractsTest do
  @moduledoc """
  An app that has not updated still works against this engine: for every
  release with a snapshot (`FermixTestSupport.ReleasedContracts`), its
  management and Realtime contracts still hold here. The phone and computer
  protocol's half is `FermixChannels.Mobile.ReleasedContractsTest`, beside its
  decoder.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Protocol, as: Management
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.Protocol, as: Realtime
  alias FermixTestSupport.ReleasedContracts

  @priv Application.app_dir(:fermix_core, "priv")

  test "at least one release is held, each its own bytes" do
    releases = ReleasedContracts.releases()
    assert releases != [], "no released contract is held, so nothing here checks anything"

    for release <- releases,
        do: assert(ReleasedContracts.provenance_errors(release) == [], release)
  end

  describe "management" do
    test "a released app's version is inside this engine's window" do
      {minimum, maximum} = Management.supported_version_range()

      for release <- ReleasedContracts.releases() do
        version = version(release, "management")

        assert version in minimum..maximum,
               "#{release}'s apps speak management #{version}; this engine serves #{minimum} to #{maximum}"
      end
    end

    test "every method a released app can call is still served at its version" do
      for release <- ReleasedContracts.releases() do
        schema = ReleasedContracts.json(ReleasedContracts.dir(release), schema("management"))
        version = schema["x-protocol-version"]

        refused =
          for {method, minimum} <- Enum.sort(schema["x-method-minimum-versions"]),
              minimum <= version,
              not served?(method, version),
              do: method

        assert refused == [], "#{release}'s apps call these at #{version}: #{inspect(refused)}"
      end
    end

    test "every request a released app was built to send still decodes" do
      for release <- ReleasedContracts.releases(),
          record <-
            ReleasedContracts.jsonl(
              ReleasedContracts.dir(release),
              "management/fixtures/requests.jsonl"
            ) do
        assert {:ok, {:v1, request}} = Management.decode_request(Jason.encode!(record["frame"])),
               "#{release}'s #{record["name"]} no longer decodes"

        assert request.method == record["method"]
      end
    end

    test "every answer still carries what a released app reads" do
      current = management_samples(@priv)

      for release <- ReleasedContracts.releases() do
        breaks =
          ReleasedContracts.shape_breaks(
            management_samples(ReleasedContracts.dir(release)),
            current
          )

        assert breaks == [], "#{release}'s apps can no longer read:\n" <> Enum.join(breaks, "\n")
      end
    end
  end

  describe "realtime" do
    test "a released app's version is inside this engine's window" do
      {minimum, maximum} = Realtime.supported_version_range()

      for release <- ReleasedContracts.releases() do
        version = version(release, "realtime")

        assert version in minimum..maximum,
               "#{release}'s apps speak Realtime #{version}; this engine serves #{minimum} to #{maximum}"
      end
    end

    test "every event a released app was built to send still decodes" do
      config = Config.normalize([])

      for release <- ReleasedContracts.releases(),
          line <-
            ReleasedContracts.lines(
              ReleasedContracts.dir(release),
              "realtime/fixtures/client_events.jsonl"
            ) do
        assert {:ok, %{type: _type}} = Realtime.decode_client_event(line, config),
               "#{release}'s #{line} no longer decodes"
      end
    end

    test "every event still carries what a released app reads" do
      current = realtime_samples(@priv)

      for release <- ReleasedContracts.releases() do
        breaks =
          ReleasedContracts.shape_breaks(
            realtime_samples(ReleasedContracts.dir(release)),
            current
          )

        assert breaks == [], "#{release}'s apps can no longer read:\n" <> Enum.join(breaks, "\n")
      end
    end
  end

  describe "the comparison" do
    test "a field the release showed that is gone is a break" do
      released = [{"overview.get", %{"health" => %{"state" => "ok", "since" => "2031-05-04"}}}]
      current = [{"overview.get", %{"health" => %{"state" => "ok"}}}]

      assert ReleasedContracts.shape_breaks(released, current) == [
               "overview.get $.health.since: gone"
             ]
    end

    test "a type the release never showed is a break, null included" do
      released = [{"job.get", %{"progress" => 3, "label" => "Installing"}}]

      current = [
        {"job.get", %{"progress" => "3", "label" => "Installing"}},
        {"job.get", %{"progress" => 4, "label" => nil}}
      ]

      assert ReleasedContracts.shape_breaks(released, current) == [
               "job.get $.label: now null, where the release showed string",
               "job.get $.progress: now string, where the release showed integer"
             ]
    end

    test "a kind no longer sent is a break" do
      assert ReleasedContracts.shape_breaks([{"turn_done", %{"t" => "turn_done"}}], []) == [
               "turn_done: no longer sent"
             ]
    end

    test "an element the release showed in a list is held as any field is" do
      released = [{"logs.query", %{"entries" => [%{"at" => "2031-05-04", "line" => "ready"}]}}]
      current = [{"logs.query", %{"entries" => [%{"line" => "ready"}]}}]

      assert ReleasedContracts.shape_breaks(released, current) == [
               "logs.query $.entries[].at: gone"
             ]
    end

    test "new fields, new kinds, a field only ever null and an integer for a number are no break" do
      released = [
        {"hello", %{"name" => "studio Mac", "note" => nil, "load" => 0.5, "tags" => []}}
      ]

      current = [
        {"hello",
         %{
           "name" => "studio Mac",
           "note" => "kept",
           "load" => 1,
           "tags" => [7],
           "region" => "loft"
         }},
        {"home.status", %{"state" => "ready"}}
      ]

      assert ReleasedContracts.shape_breaks(released, current) == []
    end
  end

  defp version(release, protocol),
    do:
      ReleasedContracts.json(ReleasedContracts.dir(release), schema(protocol))[
        "x-protocol-version"
      ]

  defp schema(protocol), do: "#{protocol}/protocol.schema.json"

  defp served?(method, version) do
    case Management.minimum_version(method) do
      {:ok, minimum} -> minimum <= version
      :error -> false
    end
  end

  defp management_samples(root) do
    results =
      for record <- ReleasedContracts.jsonl(root, "management/fixtures/success.jsonl"),
          do: {record["method"], record["response"]["result"]}

    errors =
      for record <- ReleasedContracts.jsonl(root, "management/fixtures/errors.jsonl"),
          do: {"error #{record["code"]}", record["response"]["error"]}

    results ++ errors
  end

  defp realtime_samples(root) do
    for event <- ReleasedContracts.jsonl(root, "realtime/fixtures/server_events.jsonl"),
        do: {event["type"], event}
  end
end
