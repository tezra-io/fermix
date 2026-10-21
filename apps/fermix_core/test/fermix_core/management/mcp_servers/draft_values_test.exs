defmodule FermixCore.Management.McpServers.DraftValuesTest do
  @moduledoc """
  The holder of `draft_id` (M74 E8): values a paste carried, held in memory
  for one add, bound to this boot, expiring, used once and bounded in number,
  and never printed.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.McpServers.DraftValues
  alias FermixCore.Management.McpServers.Interchange
  alias FermixCore.Management.McpServers.PastedValues

  @pasted PastedValues.new(%{{:env, "BRAVE_API_KEY"} => "bsa-secret-value"})

  defp start_holder(opts \\ []) do
    {name, opts} =
      Keyword.pop_lazy(opts, :name, fn ->
        :"draft_values_#{System.unique_integer([:positive])}"
      end)

    start_supervised!(Supervisor.child_spec({DraftValues, [name: name] ++ opts}, id: name))
    name
  end

  test "an id names the values it holds, and is used once" do
    holder = start_holder()
    id = DraftValues.hold(holder, @pasted)

    assert id =~ ~r/\Adraft:[A-Za-z0-9_-]{16}\z/
    refute id =~ "BRAVE"
    assert DraftValues.held?(holder, id)

    assert DraftValues.take(holder, id) == {:ok, @pasted}
    refute DraftValues.held?(holder, id)
    assert DraftValues.take(holder, id) == :error
  end

  test "two drafts are two ids, each with its own values" do
    holder = start_holder()
    other = PastedValues.new(%{{:env, "BRAVE_API_KEY"} => "another-value"})
    first = DraftValues.hold(holder, @pasted)
    second = DraftValues.hold(holder, other)

    assert first != second
    assert DraftValues.take(holder, second) == {:ok, other}
    assert DraftValues.take(holder, first) == {:ok, @pasted}
  end

  test "an id expires after its time" do
    holder = start_holder(ttl_ms: 30)
    id = DraftValues.hold(holder, @pasted)

    Process.sleep(100)

    refute DraftValues.held?(holder, id)
    assert DraftValues.take(holder, id) == :error
  end

  test "holding one more than the bound drops the oldest" do
    holder = start_holder(max_held: 2)
    [oldest, middle, newest] = for _n <- 1..3, do: DraftValues.hold(holder, @pasted)

    refute DraftValues.held?(holder, oldest)
    assert DraftValues.held?(holder, middle)
    assert DraftValues.held?(holder, newest)
  end

  # The newest paste always fits whole, however many servers it holds.
  test "the daemon's bounds" do
    assert DraftValues.ttl_ms() == 600_000
    assert DraftValues.max_held() == 64
    assert DraftValues.max_held() >= Interchange.max_servers()
  end

  # The process holds them in memory only: a fresh one, as after a restart,
  # knows no id the last one issued.
  test "an id from before a restart is unknown" do
    holder = start_holder()
    id = DraftValues.hold(holder, @pasted)

    :ok = stop_supervised(holder)
    holder = start_holder(name: holder)

    refute DraftValues.held?(holder, id)
  end

  test "neither inspect nor a crash report prints a held value" do
    holder = start_holder()
    _id = DraftValues.hold(holder, @pasted)

    refute inspect(@pasted) =~ "bsa-secret-value"
    refute inspect(@pasted) =~ "BRAVE_API_KEY"

    status = holder |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)
    refute status =~ "bsa-secret-value"
    refute status =~ "BRAVE_API_KEY"
    refute status =~ "draft:"
    assert status =~ "held: 1"
  end
end
