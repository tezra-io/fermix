defmodule FermixCore.Management.Plugins.DiscoveryTest do
  @moduledoc """
  What the last workspace discovery found, held so `plugins.list` can republish
  it (M34 native setup §5.6).
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Plugins.Discovery

  setup context do
    name = :"discovery_#{:erlang.phash2(context.test)}"
    start_supervised!({Discovery, name: name})

    %{opts: [discovery: name]}
  end

  test "answers with what the last discovery found", %{opts: opts} do
    assert Discovery.fetch("eden", opts) == []

    :ok = Discovery.record("eden", [%{id: "ws_a", label: "A"}], opts)

    assert Discovery.fetch("eden", opts) == [%{id: "ws_a", label: "A"}]
    assert Discovery.all(opts) == %{"eden" => [%{id: "ws_a", label: "A"}]}
  end

  # The next discovery is the answer, not an addition to the previous one: a
  # workspace the credential can no longer reach must leave the list.
  test "the next discovery replaces the previous list", %{opts: opts} do
    :ok = Discovery.record("eden", [%{id: "ws_a", label: "A"}], opts)
    :ok = Discovery.record("eden", [%{id: "ws_b", label: "B"}], opts)

    assert Discovery.fetch("eden", opts) == [%{id: "ws_b", label: "B"}]
  end

  test "one plugin's discovery never disturbs another's", %{opts: opts} do
    :ok = Discovery.record("eden", [%{id: "ws_a", label: "A"}], opts)
    :ok = Discovery.record("notion", [%{id: "ws_n", label: "N"}], opts)

    assert Discovery.fetch("eden", opts) == [%{id: "ws_a", label: "A"}]
    assert Discovery.fetch("notion", opts) == [%{id: "ws_n", label: "N"}]
  end

  test "a discovery longer than the wire publishes is cut to it", %{opts: opts} do
    found = Enum.map(1..(Discovery.max_workspaces() + 10), &%{id: "ws_#{&1}", label: "W#{&1}"})
    :ok = Discovery.record("eden", found, opts)

    assert length(Discovery.fetch("eden", opts)) == Discovery.max_workspaces()
  end

  # A tree-less verb has run no discovery, so it has nothing to report. The read
  # answers truthfully rather than raising at a caller that never asked for a
  # daemon.
  test "reads answer empty with no server running" do
    assert Discovery.fetch("eden", discovery: :discovery_never_started) == []
    assert Discovery.all(discovery: :discovery_never_started) == %{}
    assert Discovery.record("eden", [], discovery: :discovery_never_started) == :ok
  end

  # "No server running" and "the server is wedged or failing" are different
  # facts. Answering the empty list for the second one draws a healthy, empty
  # sheet over a broken daemon, so anything that is not an absent process is
  # raised at the caller.
  test "a failing server is raised at the caller, not read as an empty discovery" do
    assert {:failing, _call} = catch_exit(Discovery.fetch("eden", discovery: failing_server()))
    assert {:failing, _call} = catch_exit(Discovery.all(discovery: failing_server()))
  end

  # Registered, so `Process.whereis` answers, and dies on the one call it takes
  # rather than replying — the shape of a server that is present but cannot
  # serve. One stub answers one call, so each case gets its own.
  defp failing_server do
    name = :"discovery_failing_#{System.unique_integer([:positive, :monotonic])}"

    pid =
      spawn(fn ->
        receive do
          _message -> exit(:failing)
        end
      end)

    Process.register(pid, name)
    name
  end
end
