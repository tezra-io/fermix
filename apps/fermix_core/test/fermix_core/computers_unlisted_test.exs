defmodule FermixCore.ComputersUnlistedTest do
  # M97 F9: what a turn's list of the home's computers says when the link
  # cannot answer. async: false: these cases assert what is and is not logged.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Computers

  defmodule NotStartedLink do
    @moduledoc false
    def computer_rows, do: {:error, :not_started}
  end

  defmodule StoppedLink do
    @moduledoc false
    def computer_rows, do: {:error, :not_running}
  end

  @listed "the home's computers could not be listed"

  defp opts(link),
    do: [role: :primary, link: link, live: %{}, records: %{}, version: "0.19.2"]

  # At a primary's start every reader of the computers (the boot report's
  # readiness, the channels' readiness, the iMessage helper) asks before the
  # channels tree, which holds the link, is up: that is the boot, not a fault.
  test "before the link's tree has started, a turn sees none and nothing is said" do
    log =
      capture_log(fn ->
        assert Computers.list(opts(NotStartedLink)) == []
        assert Computers.get("loft Linux", opts(NotStartedLink)) == {:error, :not_found}
      end)

    refute log =~ @listed
  end

  # The Always On server's update gate holds on an error: rows the link has
  # not read yet are not known, never none.
  test "before the link's tree has started, the rows are still not known" do
    assert Computers.fetch(opts(NotStartedLink)) == {:error, :not_started}
  end

  test "a link that stopped after its tree started is said each time" do
    log =
      capture_log(fn ->
        assert Computers.list(opts(StoppedLink)) == []
        assert Computers.list(opts(StoppedLink)) == []
      end)

    assert length(String.split(log, "#{@listed}: :not_running")) == 3
    assert Computers.fetch(opts(StoppedLink)) == {:error, :not_running}
  end
end
